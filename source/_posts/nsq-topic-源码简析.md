---
title: nsq topic 源码简析
date: 2019-05-14 13:48:03
categories:
- 消息队列
tags:
- 消息队列
- 分布式系统
---

上一篇文章阐述了`nsqd`模块的源码。准确而言是`nsqd`服务启动过程的部分源码。内容非常多，总共分为五个部分来分析，其中略讲的内容包括利用`svc`启动进程的流程、`nsqd`实例创建及初始化过程。重点阐述的内容包括`nsqd`异步开启`nsqlookupd`查询过程，以及`nsqd`与`nsqlookupd`通信的主循环逻辑。另外，还有`nsqd`建立的`tcp`连接处理器的相关内容，这点比较复杂，涉及两个过程：`IOLoop`主循环读取连接的请求内容，以及`messagePump`处理消息发送的核心逻辑。最后略讲`http`连接处理器的创建过程。本文的主题是`topic`，相对简单。`topic`可以看作是生产者投递消息的一个逻辑键，一个`nsqd`实例可以维护多个`topic`实例，每当生产者将消息投递到某个的`nsqd`上特定的`topic`时，它随即将消息拷贝后发送到与其关联的`channel`实例集合。与`channel`实例类似，`topic`实例存储消息也涉及到两个消息队列：内存消息队列和持久化消息队列，因此对于消息的存储维护，`topic`实例和`channel`实例分开管理。同样，为了方便读者理解，本文只论述到`topic`本身的相关逻辑，换言之，不涉及到`topic`收发消息的逻辑。

<!--More-->

本文分析`nsq topic`模块的相关逻辑，更详细`nsq`源码注释可在[这里](https://github.com/qqzeng/nsqio/tree/master/nsq)找到，注释源码版本为`v1.1.0`，仅供参考。本文所涉及到源码主要为`/nsq/nsqd/`和`/nsq/internal/`下的若干子目录。

本文侧重于分析`topic`模块本身相关源码，而关于`topic`如何从生产者收到消息、如何对消息进行存储处理，最后又如何将消息转发给`channel`实例，这部分会另外写一篇文章专门阐述，这也是`nsq`系统非常核心的处理流程。本文从四个方面来阐述`topic`：其一，简要介绍`topic`结构相关字段；其二，阐述创建`topic`相关逻辑；其三，分析删除`topic`的过程；最后阐述`topic`的查询过程。

## topic 实例结构

`topic`结构所包含的字段比较简单，其中重要的包括：`channelMap`表示`topic`实例所关联的`channel`实例集合；`backend`表示`topic`所使用的消息持久化队列接口；`memoryMsgChan`则表示内存消息队列；还有一个`channelUpdateChan`通道表示当消息被更新时（添加或删除），通知`topic`的消息处理主循环中执行相应的逻辑，即更新两个消息队列。`ephemeral`字段表示`topic`是否是临时的，所谓临时的`topic`（`#ephemeral`开头）不会被持久化(`PersistMetadata`)，且当`topic` 包含的所有`channel`都被删除后，此`topic`也会被删除。

```go
type Topic struct {
	// 64bit atomic vars need to be first for proper alignment on 32bit platforms
	messageCount uint64			// 此 topic 所包含的消息的总数（内存+磁盘）
	messageBytes uint64			// 此 topic 所包含的消息的总大小（内存+磁盘）
	sync.RWMutex				// guards channelMap
	name              string					// topic 名称
	channelMap        map[string]*Channel		// topic 所包含的 channel 集合
	backend           BackendQueue				// 代表持久化存储的通道
	memoryMsgChan     chan *Message				// 代表消息在内存中的通道
	startChan         chan int					// 消息处理循环开关
	exitChan          chan int					// topic 消息处理循环退出开关
	channelUpdateChan chan int					// 消息更新的开关
	waitGroup         util.WaitGroupWrapper		// waitGroup 的一个 wrapper
	// 其会在删除一个topic时被设置，且若被设置，则 putMessage(s)操作会返回错误，拒绝写入消息
	exitFlag          int32
	idFactory         *guidFactory				// 用于生成客户端实例的ID
	// 临时的 topic（#ephemeral开头），此种类型的 topic 不会进行持久化，
	// 当此 topic 所包含的所有的 channel 都被删除后，被标记为ephemeral的topic也会被删除
	ephemeral      bool
	// topic 被删除前的回调函数，且对 ephemeral 类型的 topic有效，并且它只在 DeleteExistingChannel 方法中被调用
	deleteCallback func(*Topic)
	deleter        sync.Once
	// 标记此 topic 是否有被 paused，若被 paused，则其不会将消息写入到其关联的 channel 的消息队列
	paused    int32
	pauseChan chan int
	ctx *context					// nsqd 实例的 wrapper
} // /nsq/nsqd/topic.go
```

## 创建 topic 实例

先简单了解`topic`的构造方法，其大概涉及到这么几个步骤：先初始化实例结构，然后若此`topic`为`ephemeral`的，则设置标记，并且为此`topic`关联一个`DummyBackendQueue`作为其持久化存储，事实上，`DummyBackendQueue`表示不执行任何有效动作，显然这是考虑到临时的`topic`不用被持久化。对于正常的`topic`，则为其创建一个[`diskqueue`](https://github.com/nsqio/go-diskqueue)实例作为后端存储消息队列，通过`nsqd`配置参数进行初始化（`diskqueue`在后面单独开一篇文章解析）。最后异步开启`topic`的消息处理主循环`messagePump`，并通知`nsqlookupd`有新的`topic`实例产生。它会在`nsqd.Notify`方法中被接收，然后将此`topic`实例压入到`nsqd.notifyChan`管道，相应地，此`topic`实例在`nsqd.lookupLoop`方法中被取出，然后构建并发送`REGISTER`命令请求给`nsqd`所维护的所有`nsqlookupd`实例。最后，通过调用`PersistMetadata`方法将此`topic`元信息持久化。（方法调用链为：`NewTopic->nsqd.Notify->nsqd.lookupLoop->nsqd.PersistMetadata`）相关代码如下：

```go
// topic 的构造函数
func NewTopic(topicName string, ctx *context, deleteCallback func(*Topic)) *Topic {
	// 1. 构造 topic 实例
	t := &Topic{
		name:              topicName,
		channelMap:        make(map[string]*Channel),
		memoryMsgChan:     make(chan *Message, ctx.nsqd.getOpts().MemQueueSize),
		startChan:         make(chan int, 1),
		exitChan:          make(chan int),
		channelUpdateChan: make(chan int),
		ctx:               ctx,
		paused:            0,
		pauseChan:         make(chan int),
		deleteCallback:    deleteCallback,
		idFactory:         NewGUIDFactory(ctx.nsqd.getOpts().ID),
	}
	// 2. 标记那些带有 ephemeral 的 topic，并为它们构建一个 Dummy BackendQueue，
	// 因为这些 topic 所包含的的消息不会被持久化，因此不需要持久化队列 BackendQueue。
	if strings.HasSuffix(topicName, "#ephemeral") {
		t.ephemeral = true
		t.backend = newDummyBackendQueue()
	} else {
		dqLogf := func(level diskqueue.LogLevel, f string, args ...interface{}) {
			opts := ctx.nsqd.getOpts()
			lg.Logf(opts.Logger, opts.LogLevel, lg.LogLevel(level), f, args...)
		}
		// 3. 通过 diskqueue (https://github.com/nsqio/go-diskqueue) 构建持久化队列实例
		t.backend = diskqueue.New(
			topicName,						// topic 名称
			ctx.nsqd.getOpts().DataPath,	// 数据存储路径
			ctx.nsqd.getOpts().MaxBytesPerFile,		// 存储文件的最大字节数
			int32(minValidMsgLength),				// 最小的有效消息的长度
			int32(ctx.nsqd.getOpts().MaxMsgSize)+minValidMsgLength, // 最大的有效消息的长度
			// 单次同步刷新消息的数量，即当消息数量达到 SyncEvery 的数量时，
			// 需要执行刷新动作（否则会留在操作系统缓冲区）
			ctx.nsqd.getOpts().SyncEvery,
			ctx.nsqd.getOpts().SyncTimeout,	// 两次同步刷新的时间间隔，即两次同步操作的最大间隔
			dqLogf,							// 日志
		)
	}
	// 4. 执行 messagePump 方法，即 开启消息监听 go routine
	t.waitGroup.Wrap(t.messagePump)
	// 5. 通知 nsqlookupd 有新的 topic 产生
	t.ctx.nsqd.Notify(t)
	return t
} // /nsq/nsqd/topic.go

// 通知 nsqd 将 metadata 信息持久化到磁盘，若 nsqd 当前未处于启动过程
func (n *NSQD) Notify(v interface{}) {
    // 考虑到若在 nsqd 刚启动处于加载元数据，则此时数据并不完整，因此不会在此时执行持久化操作
	persist := atomic.LoadInt32(&n.isLoading) == 0
	n.waitGroup.Wrap(func() {
		select {
		case <-n.exitChan:
		case n.notifyChan <- v:
			if !persist {
				return
			}
			n.Lock()
			// 重新持久化 topic 及 channel 的元信息
			err := n.PersistMetadata()
			// ...
			n.Unlock()
		}
	})
}
```

最后，简单分析下，程序中哪些地方会调用此构造方法。前文提到`topic`不会被提前创建，一定是因为某个生产者在注册`topic`时临时被创建的。其实通过追踪方法调用，发现只有`nsqd.GetTopic`方法调用了`NewTopic`构造方法。因此，程序中存在以下几条调用链：其一，`nsqd.Start->nsqd.PersistMetadata->nsqd.GetTopic->NewTopic`；其二，`httpServer.getTopicFromQuery->nsqd.GetTopic->NewTopic`；以及`protocolV2.PUB/SUB->nsqd.GetTopic`这三条调用路径。相信读者已经非常清楚了。

## 删除或关闭 topic 实例

`topic`删除的方法(`topic.Delete`)与其被关闭的方法(`topic.Close`)相似，都调用了`topic.exit`方法，区别有三点：一是前者还显式调用了`nsqd.Notify`以通知`nsqlookupd`有`topic`实例被删除，同时重新持久化元数据。二是前者还需要递归删除`topic`关联的`channel`集合，且显式调用了`channel.Delete`方法（此方法同`topic.Delete`方法相似）。最后一点区别为前者还显式清空了`memoryMsgChan`和`backend`两个消息队列中的消息。因此，若只是关闭或退出`topic`，则纯粹退出`messagePump`消息处理循环，并将`memoryMsgChan`中的消息刷盘，最后关闭持久化存储消息队列。（方法调用链为：`topic.Delete->topic.exit->nsqd.Notify->nsqd.PersistMetadata->chanel.Delete->topic.Empty->topic.backend.Empty->topic.backend.Delete `，以及`topic.Close->topic.exit->topic.flush->topic.backend.Close `）相关代码如下：

```go
// Delete 方法和 Close 方法都调用的是 exit 方法。
// 区别在于 Delete 还需要显式得通知 lookupd，让它删除此 topic 的注册信息
// 而　Close　方法是在　topic　关闭时调用，因此需要持久化所有未被处理/消费的消息，然后再关闭所有的 channel，退出
func (t *Topic) Delete() error {
	return t.exit(true)
}

func (t *Topic) Close() error {
	return t.exit(false)
} // /nsq/nsqd/topic.go

// 使当前 topic 对象　exit，同时若指定删除其所关联的 channels 及 closes，则清空它们
func (t *Topic) exit(deleted bool) error {
	// 1. 保证目前还处于运行的状态
	if !atomic.CompareAndSwapInt32(&t.exitFlag, 0, 1) {
		return errors.New("exiting")
	}
	// 2. 当被　Delete　调用时，则需要先通知 lookupd 删除其对应的注册信息
	if deleted {
		t.ctx.nsqd.logf(LOG_INFO, "TOPIC(%s): deleting", t.name)
		t.ctx.nsqd.Notify(t) // 通知 nsqlookupd 有 topic 更新，并重新持久化元数据
	} else {
		t.ctx.nsqd.logf(LOG_INFO, "TOPIC(%s): closing", t.name)
	}
	// 3. 关闭 exitChan，保证所有的循环全部会退出，比如消息处理循环 messagePump 会退出
	close(t.exitChan)
	// 4. 同步等待消息处理循环 messagePump 方法的退出，
    // 才继续执行下面的操作（只有消息处理循环退出后，才能删除对应的 channel集合）
	t.waitGroup.Wait()
	// 4. 若是被 Delete 方法调用，则需要清空 topic 所包含的 channel（同 topic 的操作类似）
	if deleted {
		t.Lock()
		for _, channel := range t.channelMap {
			delete(t.channelMap, channel.name)
			channel.Delete()
		}
		t.Unlock()
		t.Empty() // 清空 memoryMsgChan 和 backend 中的消息
		return t.backend.Delete()
	}
	// 5. 否则若是被 Close 方法调用，则只需要关闭所有的 channel，
    // 不会将所有的 channel 从 topic 的 channelMap 中删除
	for _, channel := range t.channelMap {
		err := channel.Close()
		// ...
	}
	// 6. 将内存中的消息，即 t.memoryMsgChan 中的消息刷新到持久化存储
	t.flush()
	return t.backend.Close()
} // /nsq/nsqd/topic.go

// 清空内存消息队列和持久化存储消息队列中的消息
func (t *Topic) Empty() error {
	for {
		select {
		case <-t.memoryMsgChan:
		default:
			goto finish
		}
	}
finish:
	return t.backend.Empty()
} // /nsq/nsqd/topic.go

// 刷新内存消息队列即 t.memoryMsgChan 中的消息到持久化存储 backend
func (t *Topic) flush() error {
	var msgBuf bytes.Buffer
    // ...
	for {
		select {
		case msg := <-t.memoryMsgChan:
			err := writeMessageToBackend(&msgBuf, msg, t.backend)
			// ...
		default:
			goto finish
		}
	}
finish:
	return nil
} // /nsq/nsqd/topic.go
```

最后同样简单分析程序中哪些地方会调用`Delete`方法。其一，`httpServer.doDeleteTopic->nsqd.DeleteExistingTopic->topic.Delete`；其二，`nsqd.GetTopic->nsqd.DeleteExistingTopic->topic.Delete`。而对于`topic.Close`方法，则比较直接：`nsqd.Exit->topic.Close`。

## 查询 topic 实例

即依据名称查询（获取）`topic`实例，包含了两个方法，都被定义为`nsqd`实例的方法。我们重点阐述`nsqd.GetTopic`方法。查询逻辑的关键是，若此`topic`不存在`nsqd`的`topic`集合中，则需要创建一个新的实例。同时，为其注册`topic`实例的删除回调函数。接下来，若此`nsqd`并非处于启动过程（还记得`nsqd.LoadMetadata`会调用`nsqd.GetTopic`方法吗），则还要进一步填充此`topic`所关联的`channel`，即`nsqd`实例向`nsqlookupd`实例查询指定`topic`所关联的`channel`集合，然后更新`topic.channelMap`，同时也要更新`topic.memoryMsgChan`和`topoc.backendChan`结构（因为`channel`集合更新了）。最后，启动此`topic`，即开启`topic`处理消息的主循环`topic.messagePump`。相关代码如下：

```go
// GetTopic 是一个线程安全的方法，其根据 topic 名称返回指向一个 topic 对象的指针，
// 此 topic 对象有可能是新创建的
func (n *NSQD) GetTopic(topicName string) *Topic {
	// 1. 通常，此 topic 已经被创建，因此（使用读锁）先从 nsqd 的 topicMap 中查询指定指定的 topic
	n.RLock()
	t, ok := n.topicMap[topicName]
	n.RUnlock()
	if ok {
		return t
	}
	n.Lock()
	// 2. 因为上面查询指定的 topic 是否存在时，使用的是读锁，
	// 因此有线程可能同时进入到这里，执行了创建同一个 topic 的操作，因此这里还需要判断一次。
	t, ok = n.topicMap[topicName]
	if ok {
		n.Unlock()
		return t
	}
	// 3. 创建删除指定 topic 的回调函数，即在删除指定的 topic 之前，需要做的一些清理工作，
	// 比如关闭 与此 topic 所关联的channel，同时判断删除此 topic 所包含的所有 channel
	deleteCallback := func(t *Topic) {
		n.DeleteExistingTopic(t.name)
	}
	// 4. 通过 nsqd、topicName 和删除回调函数创建一个新的　topic，并将此 topic　添加到 nsqd 的 topicMap中
	// 创建 topic 过程中会初始化 diskqueue, 同时开启消息协程
	t = NewTopic(topicName, &context{n}, deleteCallback)
	n.topicMap[topicName] = t
	n.Unlock()
	n.logf(LOG_INFO, "TOPIC(%s): created", t.name)
	// 此时内存中的两个消息队列 memoryMsgChan 和 backend 还未开始正常工作
	if atomic.LoadInt32(&n.isLoading) == 1 {
		return t
	}
	// 对于新建的 topic还要查询channel集合的原因，只能是 nsqd 实例重启，丢失了topic和channel信息
    // TODO
	lookupdHTTPAddrs := n.lookupdHTTPAddrs()
	if len(lookupdHTTPAddrs) > 0 {
		// 5.1 从指定的 nsqlookupd 及 topic 所获取的 channel 的集合
		// nsqlookupd 存储所有之前此 topic 创建的 channel 信息，因此需要加载消息
		channelNames, err := n.ci.GetLookupdTopicChannels(t.name, lookupdHTTPAddrs)
		// ...
		// 5.2 对那些非 ephemeral 的 channel，
        // 创建对应的实例（因为没有使用返回值，因此纯粹是更新了内在中的memoryMsgChan和backend结构）
		for _, channelName := range channelNames {
			// 对于临时的 channel，则不需要创建，使用的时候再创建
			if strings.HasSuffix(channelName, "#ephemeral") {
				continue // do not create ephemeral channel with no consumer client
			} // 5.3 根据 channel name 获取 channel 实例，且有可能是新建的
			// 若是新建了一个 channel，则通知 topic 的后台消息协程去处理 channel 的更新事件
			// 之所以在查询到指定 channel 的情况下，新建 channel，是为了保证消息尽可能不被丢失，
			// 比如在 nsq 重启时，需要在重启的时刻创建那些 channel，避免生产者生产的消息
			// 不能被放到 channel 中，因为在这种情况下，
            // 只能等待消费者来指定的 channel 中获取消息才会创建。
			t.GetChannel(channelName)
		}
	} else if len(n.getOpts().NSQLookupdTCPAddresses) > 0 {
		// ...
	}
	// 6. 启动了消息处理的循环，往 startChan 通道中 push 了一条消息，
	// 此时会内存消息队列 memoryMsgChan，以及持久化的消息队列 backendChan 就开始工作。
	// 即能处理内存中消息更新的的事件了。
	t.Start()
	return t
} // /nsq/nsqd/nsqd.go

func (t *Topic) Start() {
	select {
	case t.startChan <- 1:
	default:
	}
} // /nsq/nsqd/topic.go
```

关于`ClusterInfo.GetLookupdTopicChannels`方法没有展开分析了，比较简单，纯粹就构建查询请求，并获得响应内容，最后对`channel`集合执行合并操作。另外，程序中关于`nsqd.GetTopic`的逻辑，在前面已阐述过。

简单小结，本文内容相比上一篇文章较少，逻辑性也相对较弱，因此较容易理解消化。文章围绕`topic`展开，从四个方面对`topic`进行介绍，其中`topic`实例所包含的字段比较简单。而`topic`实例化方法也很直接，关键在于从一条主线来把握方法，即结合系统调用逻辑，理解涉及到的整个调用方法链。删除或关闭`topic`的核心是对两个消息队列的操作。最后查询`topic`实例的方法`GetTopic`方法比较关键。





参考文献

[1]. https://github.com/nsqio/nsq
[2]. https://nsq.io/overview/quick_start.html