---
title: nsq channel 源码简析
date: 2019-05-14 19:37:53
categories:
- 消息队列
tags:
- 消息队列
- 分布式系统
---

上一篇文章阐述了`topic`模块的源码。即以`topic`为核心分析`topic`结构组件、`topic`实例的创建、删除以及查找这四方面的源码逻辑。同时也将这些方法放到一个完整的请求调用链中串联分析，以在整体上把握程序逻辑。本文的主题是`channel`（注意不要与`go channel`混淆）。`channel`可以视为发送消息的队列，它更贴近于消费者端，一旦`topic`实例从生产者那里收到一条消息，它会将这条消息复制并发送到每一个与它关联的`channel`，然后由`channel`将此消息随机发送到一个订阅了此`channel`的客户端。`channel`实例存储消息涉及到两个消息队列：内存消息队列和持久化消息队列。另外，`channel`还维护两个和消息发送相关的优先级队列：正在发送的消息队列和被推迟发送的消息队列。同样，本文只论述`channel`本身的相关逻辑，不涉及`channel`收发消息的逻辑。

<!--More-->

本文分析`nsq channel`模块的源码，更详细`nsq`源码注释可在[这里](https://github.com/qqzeng/nsqio/tree/master/nsq)找到，注释源码版本为`v1.1.0`，仅供参考。本文所涉及到源码主要为`/nsq/nsqd/`和`/nsq/internal/`下的若干子目录。

同上一篇分析`topic`的源码类似，本文侧重于分析`channel`模块本身相关源码，而关于`channel`如何接收`topic`发送的消息、又如何对消息进行存储管理，最后又如何将消息推送给客户端，这部分会另外写一篇文章专门阐述。本文从五个方面来阐述`channel`：其一，简要介绍`channel`结构字段的组成；其二，由于`channel`同`message`密切相关，因此，也会分析`message`相关的字段，以及`chanel`维护的两个和消息发送相关的优先级队列。其三，阐述创建`channel`相关逻辑；其四，分析删除`channel`的过程；最后阐述`chanel`的查询过程。显然，本文分析`channel`的模式大体上同上一篇文章分析`topic `的模式相同，因此笔者会尽量精简介绍。

## channel 实例结构

相比`topic`结构，`channel`结构所包含的字段稍复杂些，重要的有：`topicName`代表`channel`实例所隶属的`topic`实例的名称；两个消息队列实例：`backend`表示`channel`使用的消息持久化队列接口，`memoryMsgChan`则表示内存消息队列；`clients`表示订阅此`channel`的客户端实例集合；`ephemeral`字段表示`channel`是否是临时的，临时的`channel`（`#ephemeral`开头）同样不会被持久化(`PersistMetadata`)，且当`channel` 关联的所有客户端都被移除后，此`channel`也会被删除（同临时的`topic`含义类似）。最后还有两个和消息发送相关的优先级队列：`deferredPQ`代表被延迟发送的消息集合，它是一个最小堆优先级队列，其中优先级比较字段为消息发送时间(`Item.Priority`)。`inFlightPQ`代表正在发送的消息集合，同样是最小堆优先级队列，优先级比较字段也为消息发送时间(`Message.pri`)。相关代码如下：

```go
type Channel struct {
	// 64bit atomic vars need to be first for proper alignment on 32bit platforms
	requeueCount uint64				// 需要重新排队的消息数
	messageCount uint64				// 接收到的消息的总数
	timeoutCount uint64				// 正在发送的消息的数量

	sync.RWMutex					// guards

	topicName string				// 其所对应的 topic 名称
	name      string				// channel 名称
	ctx       *context				// nsqd 实例
	backend BackendQueue			// 后端消息持久化的队列
	// 内存消息通道。 其关联的 topic 会向此 channel 发送消息，
    // 且所有订阅的 client 会开启一个 go routine 订阅此 channel
	memoryMsgChan chan *Message
	exitFlag      int32				// 退出标识（同 topic 的 exitFlag 作用类似）
	exitMutex     sync.RWMutex
	// state tracking
	clients        map[int64]Consumer// 与此 channel关联的client集合，即订阅的Consumer 集合
	paused         int32 // 若paused属性被设置，则那些订阅了此channel的客户端不会被推送消息
	ephemeral      bool				// 标记此 channel 是否是临时的
	deleteCallback func(*Channel)	// 删除回调函数（同 topic 的 deleteCallback 作用类似）
	deleter        sync.Once
	// Stats tracking
	e2eProcessingLatencyStream *quantile.Quantile
	// 延迟投递消息集合，消息体会放入 deferredPQ，并且由后台的queueScanLoop协程来扫描消息
	// 将过期的消息照常使用 c.put(msg) 发送出去。
	deferredMessages map[MessageID]*pqueue.Item
	deferredPQ       pqueue.PriorityQueue		// 被延迟投递消息集合对应的 PriorityQueue
	deferredMutex    sync.Mutex					// guards deferredMessages
	// 正在发送中的消息记录集合，直到收到客户端的 FIN 才删除，否则一旦超过 timeout，则重传消息。
	// （因此client需要对消息做去重处理 de-duplicate）
	inFlightMessages map[MessageID]*Message
	inFlightPQ       inFlightPqueue				// 正在发送中的消息记录集合 对应的 inFlightPqueue
	inFlightMutex    sync.Mutex					// guards inFlightMessages
} // /nsq/nsqd/channel.go
```

## Message 实例结构

`Message`代表生产者生产或消费者消费的一条消息。它是`nsq`消息队列系统中最基本的元素。`Message`结构包含的重要字段有：`Attempts`表示消息已经重复发送的次数（一旦消息投递次数过多，客户端可针对性地做处理）；`deliveryTS`表示`channel`向`client`发送消息时刻的时间戳；`clientID`表示消息被投递的目的客户端标识；`pri`表示消息优先级（即为消息被处理的`deadline`）；`deferred`为消息被延迟的时间（若消息确实被延迟了）。另外，网络传输的消息包格式构成为：`Timestamp`(`8byte`) + `Attempts`(`2byte`) + `MessageID`(`16byte`) + `MessageBody`(`N-byte`)。具体可参考相关源码，`Message`相关代码如下：

```go
// 代表逻辑消息实体结构
type Message struct {
	ID        MessageID				// 消息 ID
	Body      []byte				// 消息体
	Timestamp int64					// 当前时间戳
	Attempts  uint16				// 消息重复投递次数
	// for in-flight handling
	deliveryTS time.Time			// 投递消息的时间戳
	clientID   int64				// 接收此消息的 client ID
	pri        int64				// 消息的优先级（即消息被处理的 deadline 时间戳）
	index      int					// 当前消息在 priority queue 中的索引
	deferred   time.Duration		// 若消息被延迟，则为延迟时间
} // /nsq/nsqd/message.go
```

另外简要贴出两个消息发送优先级队列`inFlightPQ`和`deferredPQ`核心组成代码：

```go
type inFlightPqueue []*Message
// 使用一个 heap 堆来存储所有的 message，
// 根据 Message.pri（即消息处理时间的 deadline 时间戳） 来组织成一个小顶堆
// 非线程安全，需要 caller 来保证线程安全
func newInFlightPqueue(capacity int) inFlightPqueue {
	return make(inFlightPqueue, 0, capacity)
} // /nsq/nsqd/in_flight_pqueue.go

// 若堆顶元素的 pri 大于此时的 timestamp，则返回　nil, 及二者的差值
// 此种情况表示还未到处理超时时间，即 nsqd 还不需要将它重新加入发送队列。
// 否则返回堆顶元素, 0，表示堆顶元素已经被客户端处理超时了，需要重新加入发送队列
func (pq *inFlightPqueue) PeekAndShift(max int64) (*Message, int64) {
	if len(*pq) == 0 {
		return nil, 0
	}
	x := (*pq)[0]
	if x.pri > max {
		return nil, x.pri - max
	}
	pq.Pop()
	return x, 0
} // /nsq/nsqd/in_flight_pqueue.go

// 最小堆优先级队列，其操作接口同 in_flight_queue （nsqd/in_flight_queue.go）类似
// 不同的是它借用了标准库 container/heap/heap.go
type PriorityQueue []*Item
type Item struct {
	Value    interface{}
	Priority int64
	Index    int
}
func New(capacity int) PriorityQueue {
	return make(PriorityQueue, 0, capacity)
} // /nsq/internal/pqueue/pqueue.go

func (pq *PriorityQueue) PeekAndShift(max int64) (*Item, int64) {
	if pq.Len() == 0 {
		return nil, 0
	}
	item := (*pq)[0]
	if item.Priority > max {
		return nil, item.Priority - max
	}
	heap.Remove(pq, 0) // Remove 方法中重新调整了堆的结构
	return item, 0
}
```

## 创建 topic 实例

`channel`的构造方法同`topic`的构造方法所涉及的逻辑非常相似，只不过`channel`还初始化了前面阐述的两个用于存储发送消息的优先级队列`inFlightPQ`和`deferredPQ`。因此就不再阐述，读者若需参考，可以看[这里](https://qqzeng.top/2019/05/14/nsq-topic-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/#%E5%88%9B%E5%BB%BA-topic-%E5%AE%9E%E4%BE%8B)。注意，它同样会通过`nsqd.Notify`通知`nsqlookupd`有新的`channel`创建，因此需要重新调用`PersistMetadata`以持久化元数据。（方法调用链为：`NewChannel->nsqd.Notify->nsqd.lookupLoop->nsqd.PersistMetadata`）相关代码如下：

```go
// channel 构造函数
func NewChannel(topicName string, channelName string, ctx *context,
	deleteCallback func(*Channel)) *Channel {
	// 1. 初始化 channel 部分参数
	c := &Channel{
		topicName:      topicName,
		name:           channelName,
		memoryMsgChan:  make(chan *Message, ctx.nsqd.getOpts().MemQueueSize),
		clients:        make(map[int64]Consumer),
		deleteCallback: deleteCallback,
		ctx:            ctx,
	}
	if len(ctx.nsqd.getOpts().E2EProcessingLatencyPercentiles) > 0 {
		c.e2eProcessingLatencyStream = quantile.New(
			ctx.nsqd.getOpts().E2EProcessingLatencyWindowTime,
			ctx.nsqd.getOpts().E2EProcessingLatencyPercentiles,
		)
	}
	// 2. 初始化 channel 维护的两个消息队列
	c.initPQ()
	// 3. 同　topic　类似，那些 ephemeral 类型的 channel 不会关联到一个 BackendQueue，
    // 而只是被赋予了一个 dummy BackendQueue
	if strings.HasSuffix(channelName, "#ephemeral") {
		c.ephemeral = true
		c.backend = newDummyBackendQueue()
	} else {
		dqLogf := func(level diskqueue.LogLevel, f string, args ...interface{}) {
			opts := ctx.nsqd.getOpts()
			lg.Logf(opts.Logger, opts.LogLevel, lg.LogLevel(level), f, args...)
		}
		// backend names, for uniqueness, automatically include the topic...
		// 4. 实例化一个后端持久化存储，同样是通过 go-diskqueue  来创建的，
        // 其初始化参数同 topic 中实例化 backendQueue 参数类似
		backendName := getBackendName(topicName, channelName)
		c.backend = diskqueue.New(
			backendName,
			ctx.nsqd.getOpts().DataPath,
			ctx.nsqd.getOpts().MaxBytesPerFile,
			int32(minValidMsgLength),
			int32(ctx.nsqd.getOpts().MaxMsgSize)+minValidMsgLength,
			ctx.nsqd.getOpts().SyncEvery,
			ctx.nsqd.getOpts().SyncTimeout,
			dqLogf,
		)
	}
	// 5. 通知 lookupd 添加注册信息
	c.ctx.nsqd.Notify(c)
	return c
} // /nsq/nsqd/channel.go
```

类似地，前文提过`channel`不会被预先创建，一般是因为某个消费者在订阅`channel`时才被创建的。同样，我们追踪方法调用，发现只有`topic.getOrCreateChannel`方法调用了`NewChannel`构造方法，而它又只会被`topic.GetChannel`方法调用。因此，程序中只存在三条调用链：其一，`nsqd.Start->nsqd.LoadMetadata->topic.GetChannel->topic.getOrCreateChannel->NewChannel`；其二，`httpServer.doCreateChannel->topic.GetChannel`；以及`protocolV2.SUB->topic.GetChannel`。

## 删除或关闭 channel 实例

删除(`Delete`)或者关闭(`Close`)`channel`实例的方法逻辑同`topic`也非常类似。相似部分不多阐述，读者若需要参考，可以看[这里](https://qqzeng.top/2019/05/14/nsq-topic-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/#%E5%88%A0%E9%99%A4%E6%88%96%E5%85%B3%E9%97%AD-topic-%E5%AE%9E%E4%BE%8B)。这里重点阐述两个不同点：其一，无论是关闭还是删除`channel`都会显式地将订阅了此`channel`的客户端强制关闭（当然是关闭客户端在服务端的实体）；其二，关闭和删除`channel`都会显式刷新`channel`，即将`channel`所维护的三个消息队列：内存消息队列`memoryMsgChan`、正在发送的优先级消息队列`inFlightPQ`以及被推迟发送的优先级消息队列`deferredPQ`，将它们的消息显式写入到持久化存储消息队列。

```go
// 删除此 channel，清空所有消息，然后关闭
func (c *Channel) Delete() error {
	return c.exit(true)
}

// 只是将三个消息队列中的消息刷盘，然后关闭
func (c *Channel) Close() error {
	return c.exit(false)
} // /nsq/nsqd/channel.go

func (c *Channel) exit(deleted bool) error {
	c.exitMutex.Lock()
	defer c.exitMutex.Unlock()
	// 1. 保证还未被设置 exitFlag，即还在运行中，同时设置 exitFlag
	if !atomic.CompareAndSwapInt32(&c.exitFlag, 0, 1) {
		return errors.New("exiting")
	}
	// 2. 若需要删除数据，则通知 nsqlookupd，有 channel 被删除
	if deleted {
		c.ctx.nsqd.logf(LOG_INFO, "CHANNEL(%s): deleting", c.name)
		c.ctx.nsqd.Notify(c)
	} else {
		c.ctx.nsqd.logf(LOG_INFO, "CHANNEL(%s): closing", c.name)
	}
	c.RLock()
	// 3. 强制关闭所有订阅了此 channel 的客户端
	for _, client := range c.clients {
		client.Close()
	}
	c.RUnlock()
	// 4. 清空此 channel 所维护的内存消息队列和持久化存储消息队列中的消息
	if deleted {
		// empty the queue (deletes the backend files, too)
		c.Empty()
		// 5. 删除持久化存储消息队列中的消息
		return c.backend.Delete()
	}
	// 6. 强制将内存消息队列、以及两个发送消息优先级队列中的消息写到持久化存储中
	c.flush()
	// 7. 关闭持久化存储消息队列
	return c.backend.Close()
} // /nsq/nsqd/channel.go

// 清空 channel 的消息
func (c *Channel) Empty() error {
	c.Lock()
	defer c.Unlock()
	// 1. 重新初始化（清空） in-flight queue 及 deferred queue
	c.initPQ()
	// 2. 清空由 channel 为客户端维护的一些信息，比如 当前正在发送的消息的数量 InFlightCount
	// 同时更新了 ReadyStateChan
	for _, client := range c.clients {
		client.Empty()
	}
	// 3. 将 memoryMsgChan 中的消息清空
	for {
		select {
		case <-c.memoryMsgChan:
		default:
			goto finish
		}
	}
	// 4. 最后将后端持久化存储中的消息清空
finish:
	return c.backend.Empty()
} // /nsq/nsqd/channel.go

// 将未消费的消息都写到持久化存储中，
// 主要包括三个消息集合：memoryMsgChan、inFlightMessages和deferredMessages
func (c *Channel) flush() error {
	var msgBuf bytes.Buffer
	// ...
	// 1. 将内存消息队列中的积压的消息刷盘
	for {
		select {
		case msg := <-c.memoryMsgChan:
			err := writeMessageToBackend(&msgBuf, msg, c.backend)
			// ...
		default:
			goto finish
		}
	}
	// 2. 将还未发送出去的消息 inFlightMessages 也写到持久化存储
finish:
	c.inFlightMutex.Lock()
	for _, msg := range c.inFlightMessages {
		err := writeMessageToBackend(&msgBuf, msg, c.backend)
		// ...
	}
	c.inFlightMutex.Unlock()
	// 3. 将被推迟发送的消息集合中的 deferredMessages 消息也到持久化存储
	c.deferredMutex.Lock()
	for _, item := range c.deferredMessages {
		msg := item.Value.(*Message)
		err := writeMessageToBackend(&msgBuf, msg, c.backend)
		// ...
	}
	c.deferredMutex.Unlock()
	return nil
} // /nsq/nsqd/channel.go
```

## 查询 channel 实例

同样是即依据名称查询（获取）`channel`实例，它被定义为`topic`实例的方法。查询逻辑的关键是，若此`channl`不在`topic`的`channel`集合中，则需要创建一个新的`channel`实例。并为其注册`channel`实例的删除回调函数。接下来，还要更新`topic.memoryMsgChan`和`topoc.backendChan`结构（因为`channel`集合更新了）。相关代码如下：

```go
// 根据 channel 名称返回 channel 实例，且有可能是新建的。线程安全方法。
func (t *Topic) GetChannel(channelName string) *Channel {
	t.Lock()
	channel, isNew := t.getOrCreateChannel(channelName)
	t.Unlock()
	if isNew {
		// update messagePump state
		select {
		// 若此 channel 为新创建的，则 push 消息到 channelUpdateChan中，
            // 使 memoryMsgChan 及 backend 刷新状态
		case t.channelUpdateChan <- 1:
		case <-t.exitChan:
		}
	}
	return channel
} // /nsq/nsqd/topic.go

// 根据 channel 名称获取指定的 channel，若不存在，则创建一个新的 channel 实例。非线程安全
func (t *Topic) getOrCreateChannel(channelName string) (*Channel, bool) {
	channel, ok := t.channelMap[channelName]
	if !ok {
		// 注册 channel 被删除时的回调函数
		deleteCallback := func(c *Channel) {
			t.DeleteExistingChannel(c.name)
		}
		channel = NewChannel(t.name, channelName, t.ctx, deleteCallback)
		t.channelMap[channelName] = channel
		t.ctx.nsqd.logf(LOG_INFO, "TOPIC(%s): new channel(%s)", t.name, channel.name)
		return channel, true
	}
	return channel, false
} // /nsq/nsqd/topic.go
```

简单小结，本文内容同上一篇文章分析`topic`源码非常相似，因此阐述得比较简单，只是贴了注释的源码，并重点阐述二者不同。文章围绕`channel`展开，首先简要介绍`channel`结构字段的组成；然后，分析`message`相关的字段，以及`chanel`维护的两个和消息发送相关的优先级队列：`inFlightPQ`，存放正在发送的消息的优先级队列，以及`deferredPQ`，存放被推迟发送的消息的优先级队列。接下来，分析了`channel`实例化的逻辑以及`channel`删除逻辑；最后阐述`channel`的查询过程，查询过程需要注意的是通知`topic`的消息处理主循环`messagePump`更新两个消息队列实例。





参考文献

[1]. https://github.com/nsqio/nsq
[2]. https://nsq.io/overview/quick_start.html