---
title: nsq 消息发送订阅源码简析
date: 2019-05-15 13:38:28
categories:
- 消息队列
tags:
- 消息队列
- 分布式系统
---

上一篇文章阐述了`channel`模块的源码。以`channel`为核心分析`channel`结构组件、`channel`实例的创建、删除以及查找这四方面的源码逻辑，另外也简要分析了`Message`结构的字段，以及两个与消息发送相关的优先级队列`in-flight queue`和`deferred queue`。同时也将对应方法与其它方法进行串联分析，以在整体上把握程序逻辑。本文的主题是`nsq`消息队列系统中消息的发送和订阅相关源码的逻辑。本文的核心是阐述，当生产者将消息投递到某个`nsqd`实例上对应的`topic`时，消息是如何在`nsqd`内部各组件（包括`nsqd`、`topic`和`chanel`）之间流动的，并且分析`nsq`是如何处理延时消息的投递。另外，结合网络传输模块的源码，分析两个典型的过程：生产者发布消息的逻辑，以及消费者是订阅并获取消息的逻辑。此篇文章内容较前两篇复杂，它是`nsq`实时消息队列的核心部分，对理解`nsq`的关键工作原理至关重要。

<!--More-->

本文阐述的内容更详细的源码注释可在[这里](https://github.com/qqzeng/nsqio/tree/master/nsq)找到，注释源码版本为`v1.1.0`，仅供参考。本文所涉及到源码文件主要为`/nsq/nsqd/`和`/nsq/internal/`下的若干子目录。具体而言，围绕`nsqd.go`、`topic.go`、`channel.go`展开，同时也会涉及到`protocol_v2.go`和`http.go`。

本文侧重于分析消息在`nsq`系统内部各组件之间是如何流动的，典型地，如消息是何时通过何种方式从`topic`实例流向`channel`实例的，另外，如何实现消息的延时投递逻辑，消息投递超时处理逻辑等。另外，也分析生产者是发布消息的到指定的`topic`的逻辑，以及消费者是订阅`channel`的逻辑，并且如何从订阅的`channel`收到消息。最后阐述客户端（生产者和消费者）使用的几个典型的命令请求。

## topic 消息处理逻辑

我们依据正常的消息发布的流程来阐述，以`topic`作为切入点，分析`topic`如何将从生产者收到的消息传递给与其关联的`channel`实例。当生产者发布一条消息到指定的`topic`时，请求在`protocolV2(protocol_v2.go)`实例接收，然后交由`protocolV2.PUB`方法处理，其接着调用`topic.PutMessage`方法向`topic`实例添加一条消息，由此消息就正式进入了`nsq`系统内部了。`PutMessage`方法通过调用`put`方法将接收的消息写入到消息队列，若内存消息队列(`memoryMsgChan`)未满，则 push 到内存消息队列，否则 push 到持久化存储消息队列(`backend`)。然后在`topic`的消息处理主循环中，从`memoryMsgChan`或`backendChan`管道中接收到新的消息，其随即遍历自己维护的所有`channel`实例，将此消息副本发送给每一个`channel`实例，即调用`chanel.PutMessage`将消息压入到`channel`维护的消息队列中（同样包括`memoryMsgChan`和`backend`两个），或者若此消息需要被延迟，则调用`channel.PutMessageDeferred`方法将消息压入到消息延时的优先级队列(`deferred queue`)。

好，`topic`处理消息的核心逻辑已经阐述完毕。我们贴出这个过程中消息流动所涉及到的方法调用链：`protocolV2.PUB->topic.PutMessage->topic.put->topic.messagPump->`，从这里开始分叉，对于正常的消息：`channel.PutMessage->channel.put`，最后写入`channel.memoryMsgChan`或`channel.backend`；对于被延时的消息：`channel.PutMessageDeferred->channel.StartDeferredTimeout->chanel.addToDeferredPQ->deferredPQ.push`。

核心流程如上所述，补充几点，`topic.messagePump`方法在`topic`启动（有可能是从配置文件中加载启动`LoadMetadata`或新创建时启动`GetTopic`）时开始工作，换言之，开始处理生产者给它发送的消息。另外，`messagePump`循环中也可能收到`topic`所维护的`channel`集合更新的消息（添加或移除），此时需要重新初始化两个消息队列管道(`memoryMsgChan & backendChan`)。最后，当收到`paused`的消息时，会重置这两个消息队列管道，因为一旦`topic.Paused`属性被设置，则表示此`topic`不应该再处理消息。相关代码如下：

```go
// [ topic.go 文件中，由 topic 实例的消息处理逻辑 ]
// 此方法由 httpServer.PUB 或 protocolV2.PUB 方法中调用，即生产者通过 http/tcp 投递消息到 topic
func (t *Topic) PutMessage(m *Message) error {
	t.RLock()
	defer t.RUnlock()
	// 1. 消息写入操作只在 exitFlag 为0时才进行
	if atomic.LoadInt32(&t.exitFlag) == 1 {
		return errors.New("exiting")
	}
	// 2. 写入消息内存队列 memoryMsgChan 或者 持久化存储 backend
	err := t.put(m)
	if err != nil {
		return err
	}
	// 3. 更新当前 topic 所对应的消息数量以及消息总大小
	atomic.AddUint64(&t.messageCount, 1)
	atomic.AddUint64(&t.messageBytes, uint64(len(m.Body)))
	return nil
} // /nsq/nsqd/topic.go

// 将指定消息进行持久化
// 通常情况下，在 memoryMsChan 未达到其设置的最大的消息的数量时
// （即内存中的消息队列中保存的消息的数量未达到上限时，由 MemQueueSize 指定）
// 会先将消息 push 到内在消息队列 memoryChan 中，否则会被 push 到后端持久化队列 backend 中。
// 这是通过 go buffered channel 语法来实现。
func (t *Topic) put(m *Message) error {
	select {
	case t.memoryMsgChan <- m:
	default: // 内存消息队列已满时，会将消息存放到持久化存储
		// 从缓冲池中获取缓冲
		b := bufferPoolGet()
		// 将消息写入持久化消息队列
		err := writeMessageToBackend(b, m, t.backend)
		bufferPoolPut(b) // 回收从缓冲池中获取的缓冲
		t.ctx.nsqd.SetHealth(err)
		if err != nil {
			t.ctx.nsqd.logf(LOG_ERROR,
				"TOPIC(%s) ERROR: failed to write message to backend - %s",
				t.name, err)
			return err
		}
	}
	return nil
}  // /nsq/nsqd/topic.go

// messagePump 监听 message 的更新的一些状态，以及时将消息持久化，
// 同时写入到此 topic 对应的channel
func (t *Topic) messagePump() {
	var msg *Message
	var buf []byte
	var err error
	var chans []*Channel
	var memoryMsgChan chan *Message
	var backendChan chan []byte

	// 1. 等待开启 topic 消息处理循环，即等待调用 topic.Start，
    // 在 nsqd.GetTopic 和 nsqd.LoadMetadata 方法中调用
	for {
		select {
		case <-t.channelUpdateChan:
			continue
		case <-t.pauseChan:
			continue
		case <-t.exitChan:
			goto exit
		// 在 nsqd.Main 中最后一个阶段会开启消息处理循环 topic.Start
            // （处理由客户端（producers）向 topci 投递的消息）
		// 在此之前的那些信号全部忽略
		case <-t.startChan:
		}
		break
	}
	t.RLock()
	// 2. 根据 topic.channelMap 初始化两个通道 memoryMsgChan，backendChan
	// 并且保证 topic.channelMap 存在 channel，且 topic 未被 paused
	for _, c := range t.channelMap {
		chans = append(chans, c)
	}
	t.RUnlock()
	if len(chans) > 0 && !t.IsPaused() {
		memoryMsgChan = t.memoryMsgChan
		backendChan = t.backend.ReadChan()
	}
	// 3. topic 处理消息的主循环
	for {
		select {
		// 3.1 从内存消息队列 memoryMsgChan 或 持久化存储 backend 中收到消息
		// 则将消息解码，然后会将消息 push 到此 topic 关联的所有 channel
		case msg = <-memoryMsgChan:
		case buf = <-backendChan:
			msg, err = decodeMessage(buf)
			if err != nil {
				t.ctx.nsqd.logf(LOG_ERROR, "failed to decode message - %s", err)
				continue
			}
		// 3.2 当从 channelUpdateChan 读取到消息时，
            // 表明有 channel 更新，比如创建了新的 channel，
		// 因此需要重新初始化 memoryMsgChan及 backendChan
		case <-t.channelUpdateChan:
			chans = chans[:0]
			t.RLock()
			for _, c := range t.channelMap {
				chans = append(chans, c)
			}
			t.RUnlock()
			if len(chans) == 0 || t.IsPaused() {
				memoryMsgChan = nil
				backendChan = nil
			} else {
				memoryMsgChan = t.memoryMsgChan
				backendChan = t.backend.ReadChan()
			}
			continue
		// 3.3 当收到 pause 消息时，则将 memoryMsgChan及backendChan置为 nil，注意不能 close，
		// 二者的区别是 nil的chan不能接收消息了，但不会报错。
            // 而若从一个已经 close 的 chan 中尝试取消息，则会 panic。
		case <-t.pauseChan:
			// 当 topic 被 paused 时，其不会将消息投递到 channel 的消息队列
			if len(chans) == 0 || t.IsPaused() {
				memoryMsgChan = nil
				backendChan = nil
			} else {
				memoryMsgChan = t.memoryMsgChan
				backendChan = t.backend.ReadChan()
			}
			continue
		// 3.4 当调用 topic.exit 时会收到信号，以终止 topic 的消息处理循环
		case <-t.exitChan:
			goto exit
		}
		// 4. 当从 memoryMsgChan 或 backendChan 中 pull 到一个 msg 后，会执行这里：
		// 遍历 channelMap 中的每一个 channel，将此 msg 拷贝到 channel 中的后备队列。
		// 注意，因为每个 channel 需要一个独立 msg，因此需要在拷贝时需要创建 msg 的副本
		// 同时，针对 msg 是否需要被延时投递来选择将 msg 放到
        // 延时队列 deferredMessages中还是 in-flight queue 中
		for i, channel := range chans {
			chanMsg := msg
			if i > 0 { // 若此 topic 只有一个 channel，则不需要显式地拷贝了
				chanMsg = NewMessage(msg.ID, msg.Body)
				chanMsg.Timestamp = msg.Timestamp
				chanMsg.deferred = msg.deferred
			}
			// 将 msg push 到 channel 所维护的延时消息队列 deferred queue
			// 等待消息的延时时间走完后，会把消息进一步放入到 in-flight queue 中
			if chanMsg.deferred != 0 {
				channel.PutMessageDeferred(chanMsg, chanMsg.deferred)
				continue
			}
			// 将 msg push 到普通消息队列 in-flight queue
			err := channel.PutMessage(chanMsg)
			// ...
		}
	}
exit:
	t.ctx.nsqd.logf(LOG_INFO, "TOPIC(%s): closing ... messagePump", t.name)
} // /nsq/nsqd/topic.go
```

```go
// [ channel.go 文件中，topic 发送消息到 in-flight queue 相关逻辑 ]
// 此方法会由 topic.messagePump 方法中调用。
// 即当 topic 收到生产者投递的消息时，将此消息放到与其关联的 channels 的延迟队列 deferred queue
// 或者 普通的消息队列中(包括 内存消息队列 memoryMsgChan 或 后端持久化 backend)（即此方法）
// channel 调用 put 方法将消息放到消息队列中，同时更新消息计数
func (c *Channel) PutMessage(m *Message) error {
	c.RLock()
	defer c.RUnlock()
	if c.Exiting() {
		return errors.New("exiting")
	}
	err := c.put(m)
	if err != nil {
		return err
	}
	atomic.AddUint64(&c.messageCount, 1)
	return nil
} // /nsq/nsqd/channel.go
// 同 topic.put 方法类似，其在 put message 时，
// 依据实际情况将消息 push 到内在队列 memoryMsgChan 或者后端持久化 backend
func (c *Channel) put(m *Message) error {
	select {
	case c.memoryMsgChan <- m:
	default:
		b := bufferPoolGet()
		err := writeMessageToBackend(b, m, c.backend)
		bufferPoolPut(b)
		c.ctx.nsqd.SetHealth(err)
		// ...
	}
	return nil
} // /nsq/nsqd/channel.go
```

```go
// [ channel.go 文件中，topic 发送消息到 deferred queue 相关逻辑 ]
// 将 message 添加到 deferred queue 中
func (c *Channel) PutMessageDeferred(msg *Message, timeout time.Duration) {
	atomic.AddUint64(&c.messageCount, 1)
	c.StartDeferredTimeout(msg, timeout)
} // /nsq/nsqd/channel.go

// 将 message 加入到 deferred queue 中，等待被 queueScanWorker 处理
func (c *Channel) StartDeferredTimeout(msg *Message, timeout time.Duration) error {
	// 1. 计算超时超时戳，作为 Priority
	absTs := time.Now().Add(timeout).UnixNano()
	// 2. 构造 item
	item := &pqueue.Item{Value: msg, Priority: absTs}
	// 3. item 添加到 deferred 字典
	err := c.pushDeferredMessage(item)
	if err != nil {
		return err
	}
	// 4. 将 item 放入到 deferred message 优先级队列
	c.addToDeferredPQ(item)
	return nil
} // /nsq/nsqd/channel.go

func (c *Channel) addToDeferredPQ(item *pqueue.Item) {
	c.deferredMutex.Lock()
	heap.Push(&c.deferredPQ, item)
	c.deferredMutex.Unlock()
} // /nsq/nsqd/channel.go
```

至此，关于`topic`如何处理消息，如何将消息传递给`channel`已经讲述完毕，接下来，分析对于那些超时的消息应该如何处理，`deferred queue`中存储的延时投递的消息如何发送给客户端。这涉及到`nsqd.go`文件中`nsqd`实例的消息处理主循环，它循环扫描所有的`channel`关联的两个消息队列中的消息，并做针对性处理。

## nsqd 消息处理循环

在`nsqd`源码分析的文章中，没有涉及到`nsqd`消息处理循环相关的逻辑，考虑到在介绍之前必须要先了解`topic`及`channel`的相关功能。因此，把`nsqd`关于消息处理的部分单独开篇文章介绍。在`nsqd.Main`启动方法中，异步开启三个处理循环：`nsqd.queueScanLoop`、`nsqd.lookupLoop`和`nsqd.statsLoop`，分别作为消息处理循环，同`nsqlookupd`通信交互循环，以及数据统计循环。在`nsqd.queueScanLoop`方法中：

它首先根据配置文件参数初始化了一些重要属性：`workTicker`根据`QueueScanInterval`初始化，表示每隔`QueueScanInterval`的时间（默认`100ms`），`nsqd`随机挑选`QueueScanSelectionCount`数量的`channel`执行`dirty channel`的计数统计；另外`refreshTicker`根据`QueueScanRefreshInterval`初始化，每过`QueueScanRefreshInterval`时间（默认`5s`）就调整`queueScanWorker pool`的大小。之后，

`queueScanLoop`的任务是处理发送中的消息队列(`in-flight queue`)，以及被延迟发送的消息队列(`deferred queue`)两个优先级消息队列中的消息。具体而言，它循环执行两个定时任务：

- 其一，由`workTicker`计时器触发，每过`QueueScanInterval`（默认为`100ms`）的时间，就从本地的消息缓存队列中（`nsqd`维护的所有`topic`所关联的`channel`集合），随机选择`QueueScanSelectionCount`（默认`20`）个`channel`。检查这些`channel`集合中被标记为`dirty`属性的`channel`的数量，所谓的`dirty channel`即表示此`channel`实例中存在消息需要处理，这包含两个方面的处理逻辑：
  - 对于`in-flight queue`而言，检查消息是否已经处理超时（消费者处理超时），若存在超时的消息，则将消息从`in-flight queue`中移除，并重新将它压入到此`channel`的消息队列中(`memoryMsgChan`或`backend`)，等待后面重新被发送（即之后还会被重新压入到`in-flight queue`中），此为消息发送超时的处理逻辑。
  - 对于`deferred queue`而言，检查消息的延迟时间是否已经走完，换言之，检查被延迟的消息现在是否应该发送给消费者了。若某个被延时的消息的延时时间已经达到，则将它从`deferred queue`中移除，并重新压入到此`channel`的消息队列中(`memoryMsgChan`或`backend`)，等待后面正式被发送（即之后还会被重新压入到`in-flight queue`中），此为消息延迟发送超时的处理逻辑。

  若处理的结果显示，`dirty channel`的数量超过`QueueScanDirtyPercent`（默认`25%`）的比例，则再次随机选择`QueueScanSelectionCount`（默认`20`）个`channel`，并让`queueScanWorker`对它们进行处理。

- 另一个定时任何由`refreshTicker`计时器触发，每过`QueueScanRefreshInterval`（默认`5s`）的时间，就调整`queueScanWorker pool`的大小。具体的调整措施为：
  - 若现有的`queueScanWorker`的数量低于理想值（`nsqd`包含的`channel`集合的总数的`1/4`，程序硬编码），则显式地增加`queueScanWorker`的数量，即异步执行`queueScanWorker`方法。
  - 否则，若现有的`queueScanWorker`数量高于理想值，则通过`exitCh`显式地结束执行`queueScanWorker`方法。

  所谓的`queueScanWorker`实际上只是一个循环消息处理的方法，一旦它从`workCh`管道接收到消息，则会开始处理`in-fligth queue`和`deferred queue`中的消息，最后将处理结果，即队列中是否存在`dirty channel`通过`responseCh`通知给`queeuScanLoop`主循环。

上述逻辑即为`nsqd`对两个消息队列(`in-flight queue`和`deferred queue`)的核心处理逻辑。相关代码如下：

```go
// queueScanLoop 方法在一个单独的 go routine 中运行。
// 用于处理正在发送的 in-flight 消息以及被延迟处理的 deferred 消息
// 它管理了一个 queueScanWork pool，其默认数量为5。queueScanWorker 可以并发地处理 channel。
// 它借鉴了Redis随机化超时的策略，即它每 QueueScanInterval 时间（默认100ms）就从本地的缓存队列中
// 随机选择 QueueScanSelectionCount 个（默认20个） channels。
// 其中 缓存队列每间隔  QueueScanRefreshInterval 还会被刷新。
func (n *NSQD) queueScanLoop() {
	// 1. 获取随机选择的 channel 的数量，以及队列扫描的时间间隔，及队列刷新时间间隔
	workCh := make(chan *Channel, n.getOpts().QueueScanSelectionCount)
	responseCh := make(chan bool, n.getOpts().QueueScanSelectionCount)
	closeCh := make(chan int)

	workTicker := time.NewTicker(n.getOpts().QueueScanInterval)
	refreshTicker := time.NewTicker(n.getOpts().QueueScanRefreshInterval)
	// 2. 获取 nsqd 所包含的 channel 集合，一个 topic 包含多个 channel，
    // 而一个 nsqd 实例可包含多个 topic 实例
	channels := n.channels()
	n.resizePool(len(channels), workCh, responseCh, closeCh)
	// 3. 这个循环中的逻辑就是依据配置参数，
    // 反复处理 nsqd 所维护的 topic 集合所关联的 channel 中的消息
	// 即循环处理将 channel 从 topic 接收到的消息，发送给订阅了对应的 channel 的客户端
	for {
		select {
		// 3.1 每过 QueueScanInterval 时间（默认100ms），
            // 则开始随机挑选 QueueScanSelectionCount 个 channel。转到 loop: 开始执行
		case <-workTicker.C:
			if len(channels) == 0 { // 此 nsqd 没有包含任何 channel　实例当然就不用处理了
				continue
			}
		// 3.2 每过 QueueScanRefreshInterval 时间（默认5s），
            // 则调整 pool 的大小，即调整开启的 queueScanWorker 的数量为 pool 的大小
		case <-refreshTicker.C:
			channels = n.channels()
			n.resizePool(len(channels), workCh, responseCh, closeCh)
			continue
		// 3.3 nsqd 已退出
		case <-n.exitChan:
			goto exit
		}
		num := n.getOpts().QueueScanSelectionCount
		if num > len(channels) {
			num = len(channels)
		}
		// 3.4 利用 util.UniqRands，随机选取 num（QueueScanSelectionCount 默认20个）channel
		// 将它们 push 到 workCh 管道，queueScanWorker 中会收到此消息，
        // 然后立即处理 in-flight queue 和 deferred queue 中的消息。
		// 注意，因为这里是随机抽取 channel 因此，有可能被选中的 channel 中并没有消息
	loop:
		for _, i := range util.UniqRands(num, len(channels)) {
			workCh <- channels[i]
		}
		// 3.5 统计 dirty 的 channel 的数量， responseCh 管道在上面的 nsqd.resizePool 方法中
        // 传递给了 len(channels) * 0.25 个 queueScanWorker。
		// 它们会在循环中反复查看两个消息优先级队列中是否有消息等待被处理： 
        // 即查看 inFlightPQ 和 deferredPQ。
		numDirty := 0
		for i := 0; i < num; i++ {
			if <-responseCh {
				numDirty++
			}
		}
		// 3.6 若其 dirtyNum 的比例超过配置的 QueueScanDirtyPercent（默认为25%）
		if float64(numDirty)/float64(num) > n.getOpts().QueueScanDirtyPercent {
			goto loop
		}
	}

exit:
	n.logf(LOG_INFO, "QUEUESCAN: closing")
	close(closeCh)
	workTicker.Stop()
	refreshTicker.Stop()
} // /nsq/nsqd/nsqd.go
```

```go
// 调整 queueScanWorker 的数量
func (n *NSQD) resizePool(num int, workCh chan *Channel, responseCh chan bool, closeCh chan int) {
	// 1. 根据 channel 的数量来设置合适的 pool size，默认为 1/4 的 channel 数量
	idealPoolSize := int(float64(num) * 0.25)
	if idealPoolSize < 1 {
		idealPoolSize = 1
	} else if idealPoolSize > n.getOpts().QueueScanWorkerPoolMax {
		idealPoolSize = n.getOpts().QueueScanWorkerPoolMax
	}
	// 2. 开启一个循环，直到理想的 pool size 同实际的 pool size 相同才退出。
	// 否则，若理想值更大，则需扩展已有的 queueScanWorker 的数量，
		// 即在一个单独的 goroutine 中调用一次 nsqd.queueScanWorker 方法（开启了一个循环）。
	// 反之， 需要减少已有的 queueScanWorker 的数量，
    // 即往 closeCh 中 push 一条消息，强制 queueScanWorker goroutine 退出
	for {
		if idealPoolSize == n.poolSize {
			break
		} else if idealPoolSize < n.poolSize {
			// contract
			closeCh <- 1
			n.poolSize--
		} else {
			// expand
			n.waitGroup.Wrap(func() {
				n.queueScanWorker(workCh, responseCh, closeCh)
			})
			n.poolSize++
		}
	}
}  // /nsq/nsqd/nsqd.go

// 在 queueScanLoop 中处理 channel 的具体就是由 queueScanWorker 来负责。
// 调用方法 queueScanWorker 即表示新增一个  queueScanWorker goroutine 来处理 channel。
// 一旦开始工作 (从 workCh 中收到了信号， 即 dirty 的 channel 的数量达到阈值)，
// 则循环处理 in-flight queue 和 deferred queue 中的消息，
// 并将处理结果（即是否是 dirty channel）通过 reponseCh 反馈给 queueScanWorker。
func (n *NSQD) queueScanWorker(workCh chan *Channel, responseCh chan bool, closeCh chan int) {
	for {
		select {
		// 开始处理两个消息队列中的消息
		case c := <-workCh:
			now := time.Now().UnixNano()
			dirty := false
			// 若返回true，则表明　in-flight 优先队列中有存在处理超时的消息，
			// 因此将消息再次写入到　内存队列 memoryMsgChan　或 后端持久化　backend
			// 等待消息被重新投递给消费者（重新被加入到 in-flight queue）
			if c.processInFlightQueue(now) {
				dirty = true
			}
			// 若返回 true，则表明　deferred 优先队列中存在延时时间已到的消息，
            // 因此需要将此消息从 deferred queue 中移除，
			// 并将消息重新写入到　内存队列 memoryMsgChan　或后端持久化　backend
            // 等待消息被正式投递给消费者 （正式被加入到 in-flight queue）
			if c.processDeferredQueue(now) {
				dirty = true
			}
			// 报告 queueScanLoop 主循环，发现一个 dirty channel
			responseCh <- dirty
		// 退出处理循环，缩减 queueScanWorker 数量时，被调用
		case <-closeCh:
			return
		}
	}
} // /nsq/nsqd/nsqd.go
```

为了更好的理解消息的流动，小结一下，生产者投递消息到指定`topic`后，消息进入了`topic`维护的消息队列(`memoryMsgChan`和`backend`)，而在启动`nsqd`时，会异步开启一个消息处理循环即`queueScanLoop`，它包含两个计时任务，其中一个是，定时调整已经正在运行的`queueScanWorker`数量，其中`queueScanWorker`的任务为查看两个优先级队列中是否存在需要被处理的消息，若存在，则标记对应的`channel`为`dirty channel`。另一个计时任务是，定时抽取一定数量的`channel`，查看其中为`dirty channel`的比例（由`queueScanWorker`完成），若达到一定比例，则继续执行抽取`channel`的动作，如此反复。

好，到目前为止，`nsq`内部的消息处理逻辑已经阐述完毕。这对于理解整个`nsq`实时消息队列的关键原理至关重要。下面阐述几个典型的命令请求的核心实现逻辑。

## 生产者消息发布消息

考虑到`nsq`为生产者提供了`http/tcp`两种方式来发布消息。因此，笔者以`tcp`的命令请求处理器为示例来阐述其核心处理逻辑（`http`的方式也类似）。当生产者通过`go-nsq`库以`tcp`的方式发送消息发布请求命令给指定`topic`时，请求首先从`protocolV2.IOLoop`中被读取，然后其调用`protocolV2.Exec`方法根据命令请求的类型调用相应的处理方法，此为`PUB`命令，因此调用`protocolV2.PUB`方法处理。处理过程比较简单，首先解析请求，取出`topic`名称，然后执行权限检查，检查通过后，便依据`topic`名称获取此`topic`实例，然后，构建一条消息，并调用`topic.PutMessage`方法发布消息，最后，调用`cleint.PublishedMessage`方法更新一些信息，并返回`ok`。整个流程比较简单，因为关键的处理逻辑在前文介绍过了，读者需要把它们串联起来。代码如下：

```go
// 客户端在指定的 topic 上发布消息
func (p *protocolV2) PUB(client *clientV2, params [][]byte) ([]byte, error) {
	var err error
	if len(params) < 2 {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID"
                             , "PUB insufficient number of parameters")
	}
	// 1. 读取 topic 名称
	topicName := string(params[1])
	if !protocol.IsValidTopicName(topicName) {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_TOPIC",
			fmt.Sprintf("PUB topic name %q is not valid", topicName))
	}
	// 2. 读取消息体长度 bodyLen，并在长度上进行校验
	bodyLen, err := readLen(client.Reader, client.lenSlice)
	if err != nil {
		return nil, protocol.NewFatalClientErr(err, 
                            "E_BAD_MESSAGE", "PUB failed to read message body size")
	}
	if bodyLen <= 0 {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_MESSAGE",
			fmt.Sprintf("PUB invalid message body size %d", bodyLen))
	}
	if int64(bodyLen) > p.ctx.nsqd.getOpts().MaxMsgSize {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_MESSAGE",
			fmt.Sprintf("PUB message too big %d > %d", bodyLen, p.ctx.nsqd.getOpts().MaxMsgSize))
	}
	// 3. 读取指定字节长度的消息内容到 messageBody
	messageBody := make([]byte, bodyLen)
	_, err = io.ReadFull(client.Reader, messageBody)
	// ...
	// 4. 检查客户端是否具备 PUB 此 topic 命令的权限
	if err := p.CheckAuth(client, "PUB", topicName, ""); err != nil {
		return nil, err
	}
	// 5. 获取 topic 实例
	topic := p.ctx.nsqd.GetTopic(topicName)
	// 6. 构造一条 message，并将此 message 投递到此 topic 的消息队列中
	msg := NewMessage(topic.GenerateID(), messageBody)
	err = topic.PutMessage(msg)
	// ...
	// 7. 开始发布此消息，即将对应的 client 修改为此 topic 保存的消息的计数。
	client.PublishedMessage(topicName, 1)
	// 回复 Ok
	return okBytes, nil
} // /nsq/nsqd/protocol_v2.go
```

生产者除了可以发送`PUB`命令外，类似地，还有命令请求`MPUB`来一次性发布多条消息，`DPUB`用于发布延时投递的消息等等，逻辑都比较简单，不多阐述。下面介绍消费者处理消息的相关流程。

## 消费者处理消息

消费者处理消息的流程包括，消费者发送`SUB`命令请求以订阅`channel`，消费者发送`RDY`命令请求以通知服务端自的消息处理能力，消费者发送`FIN`消息表示消息已经处理完成，最后还有个消费者发送`REQ`消息请求服务端重新将消息入队。下面依次分析这些命令请求的核心实现。

### 消费者订阅消息

当消费者通过`tcp`发送订阅消息的请求时，请求同样是首先从`protocolV2.IOLoop`方法中被接收，然后交由`Exec`方法处理。最后进入到`SUB`方法的流程，它首先执行必要的请求校验工作，其中容易被忽略的一点是，只有当`client`处于`stateInit`状态才能订阅某个`topic`的`channel`，换言之，当一个`client`订阅了某个`channel`后，它的状态会被更新为`stateSubscribed`，因此不能再订阅其它`channel`了。总而言之，**一个 `client`同一时间只能订阅一个`channel`**。之后，获取并校验订阅的`topic`名称、`channel`名称，然后，客户端是否有订阅的权限，权限检查通过后，通过`topic`和`channel`名称获取对应的实例，并将此`client`实例添加到其订阅的`channel`的客户端集合中。最后，也是最关键的步骤是，它将订阅的`channel`实例传递给了`client`，同时将`channel`发送到了`client.SubEventChan`管道中，因此在`protocolV2.messagePump`方法中就能够根据，此客户端可以利用`channel.memoryMsgChan`和`channel.backend`来获取`channel`实例从`topic`实例接收到的消息，具体过程可以参考[这里](https://qqzeng.top/2019/05/13/nsq-nsqd-%E6%9C%8D%E5%8A%A1%E5%90%AF%E5%8A%A8%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/#%E6%B6%88%E6%81%AF%E5%8F%91%E9%80%81%E5%A4%84%E7%90%86)。

```go
// 客户端在指定的 topic 上订阅消息
func (p *protocolV2) SUB(client *clientV2, params [][]byte) ([]byte, error) {
	// 1. 做一些校验工作，只有当 client 处于 stateInit 状态才能订阅某个 topic 的 channel
	// 换言之，当一个 client 订阅了某个 channel 之后，
    // 它的状态会被更新为 stateSubscribed，因此不能再订阅 channel 了。
	// 总而言之，一个 client 只能订阅一个 channel
	if atomic.LoadInt32(&client.State) != stateInit {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "cannot SUB in current state")
	}
	if client.HeartbeatInterval <= 0 {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "cannot SUB with heartbeats disabled")
	}
	if len(params) < 3 {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "SUB insufficient number of parameters")
	}
	// 2. 获取订阅的 topic 名称、channel 名称，并对它们进行校验
	topicName := string(params[1])
	if !protocol.IsValidTopicName(topicName) {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_TOPIC",
			fmt.Sprintf("SUB topic name %q is not valid", topicName))
	}
	channelName := string(params[2])
	if !protocol.IsValidChannelName(channelName) {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_CHANNEL",
			fmt.Sprintf("SUB channel name %q is not valid", channelName))
	}
	// 3. 同时检查此客户端是否有订阅的权限
	if err := p.CheckAuth(client, "SUB", topicName, channelName); err != nil {
		return nil, err
	}
	// 此循环是为了避免 client 订阅到正在退出的 ephemeral 属性的 channel 或 topic
	var channel *Channel
	for {
		// 4. 获取 topic 及 channel 实例
		topic := p.ctx.nsqd.GetTopic(topicName)
		channel = topic.GetChannel(channelName)
		// 5. 调用 channel的 AddClient 方法添加指定客户端
		if err := channel.AddClient(client.ID, client); err != nil {
			return nil, protocol.NewFatalClientErr(nil, "E_TOO_MANY_CHANNEL_CONSUMERS",
				fmt.Sprintf("channel consumers for %s:%s exceeds limit of %d",
					topicName, channelName, p.ctx.nsqd.getOpts().MaxChannelConsumers))
		}
		// 6. 若此 channel 或 topic 为ephemeral，并且channel或topic正在退出，则移除此client
		if (channel.ephemeral && channel.Exiting()) || (topic.ephemeral && topic.Exiting()) {
			channel.RemoveClient(client.ID)
			time.Sleep(1 * time.Millisecond)
			continue
		}
		break
	}
	// 6. 修改客户端的状态为 stateSubscribed
	atomic.StoreInt32(&client.State, stateSubscribed)
	// 7. 这一步比较关键，将订阅的 channel 实例传递给了 client，
    // 同时将 channel 发送到了 client.SubEventChan 通道中。
	// 后面的 SubEventChan 就会使得当前的 client 在一个 goroutine 中订阅这个 channel 的消息
	client.Channel = channel
	// update message pump
	// 8. 通知后台订阅协程来订阅消息,包括内存管道和磁盘
	client.SubEventChan <- channel
	// 9. 返回 ok
	return okBytes, nil
} // /nsq/nsqd/protocol_v2.go
```

### 消费者发送 RDY 命令

在消费者未发送`RDY`命令给服务端之前，服务端不会推送消息给客户端，因为此时服务端认为消费者还未准备好接收消息（由方法`client.IsReadyForMessages`实现）。另外，此`RDY`命令的含义，简而言之，当`RDY 100`即表示客户端具备一次性接收并处理100个消息的能力，因此服务端此时更可推送100条消息给消费者（如果有的话），每推送一条消息，就要修改`client.ReadyCount`的值。而`RDY`命令请求的处理非常简单，即通过`client.SetReadyCount`方法直接设置`client.ReadyCount`的值。注意在这之前的两个状态检查动作。

```go
// 消费者发送 RDY 命令请求表示服务端可以开始推送指定数目的消息了
func (p *protocolV2) RDY(client *clientV2, params [][]byte) ([]byte, error) {
	state := atomic.LoadInt32(&client.State)
	if state == stateClosing {
		// just ignore ready changes on a closing channel
		p.ctx.nsqd.logf(LOG_INFO,
			"PROTOCOL(V2): [%s] ignoring RDY after CLS in state ClientStateV2Closing",
			client)
		return nil, nil
	}
	if state != stateSubscribed {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", 
                                               "cannot RDY in current state")
	}
	count := int64(1)
	if len(params) > 1 {
		b10, err := protocol.ByteToBase10(params[1])
		if err != nil {
			return nil, protocol.NewFatalClientErr(err, "E_INVALID",
				fmt.Sprintf("RDY could not parse count %s", params[1]))
		}
		count = int64(b10)
	}
	if count < 0 || count > p.ctx.nsqd.getOpts().MaxRdyCount {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID",
			fmt.Sprintf("RDY count %d out of range 0-%d", count,
                        p.ctx.nsqd.getOpts().MaxRdyCount))
	}
	client.SetReadyCount(count)
	return nil, nil
} // /nsq/nsqd/protocol_v2.go
```

### 消费者发送 FIN 命令

当消费者将`channel`发送的消息消费完毕后，会显式向`nsq`发送`FIN`命令（类似于`ACK`）。当服务端收到此命令后，就可将消息从消息队列中删除。`FIN`方法首先调用`client.Channel.FinishMessage`方法将消息从`channel`的两个集合`in-flight queue`队列及`inFlightMessages` 字典中移除。然后调用`client.FinishedMessage`更新`client`的维护的消息消费的统计信息。相关代码如下：

```go
// 消费者 client 收到消息后，会向 nsqd　响应　FIN+msgID　通知服务器成功投递消息，可以清空消息了'
func (p *protocolV2) FIN(client *clientV2, params [][]byte) ([]byte, error) {
	// 1. 正式处理　FIN　请求前，对 client 及 请求参数属性信息进行校验
	state := atomic.LoadInt32(&client.State)
	if state != stateSubscribed && state != stateClosing {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "cannot FIN in current state")
	}
	if len(params) < 2 {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "FIN insufficient number of params")
	}
	// 2. 获取 msgID
	id, err := getMessageID(params[1])
	// ...
	// 3. client 调用 channel.FinishMessage 方法，
    // 即将消息从 channel 的 in-flight queue 及 inFlightMessages 字典中移除
	err = client.Channel.FinishMessage(client.ID, *id)
	// ...
	// 4. 更新 client 维护的消息消费的统计信息
	client.FinishedMessage()
	return nil, nil
} // /nsq/nsqd/protocol_v2.go
```

### 消费者发送 REQ 命令

消费者可以通过向服务端发送`REQ`命令以将消息重新入队，即让服务端一定时间后（也可能是立刻）将消息重新发送给`channel`关联的客户端。此方法的核心是`client.Channel.RequeueMessage`，它会先将消息从`in-flight queue`优先级队列中移除，然后根据客户端是否需要延时`timeout`发送，分别将消息压入`channel`的消息队列(`memoryMsgChan`或`backend`)，或者构建一个延时消息，并将其压入到`deferred queue`。代码如下：

```go
// nsqd 为此 client 将 message 重新入队，并指定是否需要延时发送
func (p *protocolV2) REQ(client *clientV2, params [][]byte) ([]byte, error) {
	// 1. 先检验 client 的状态以及参数信息
	state := atomic.LoadInt32(&client.State)
	if state != stateSubscribed && state != stateClosing {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "cannot REQ in current state")
	}
	if len(params) < 3 {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "REQ insufficient number of params")
	}
	id, err := getMessageID(params[1])
	if err != nil {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", err.Error())
	}
	// 2. 从请求中取出重入队的消息被延迟的时间，
    // 并转化单位，同时限制其不能超过最大的延迟时间 maxReqTimeout
	timeoutMs, err := protocol.ByteToBase10(params[2])
	// ...
	timeoutDuration := time.Duration(timeoutMs) * time.Millisecond
	maxReqTimeout := p.ctx.nsqd.getOpts().MaxReqTimeout
	clampedTimeout := timeoutDuration
	if timeoutDuration < 0 {
		clampedTimeout = 0
	} else if timeoutDuration > maxReqTimeout {
		clampedTimeout = maxReqTimeout
	}
	// ...
	// 3. 调用 channel.RequeueMessage 将消息重新入队。首先会将其从 in-flight queue 中删除，
	// 然后依据其 timeout 而定，若其为0,则直接将其添加到消息队列中，
	// 否则，若其 timeout 不为0,则构建一个 deferred message，
    // 并设置好延迟时间为 timeout，并将其添加到 deferred queue 中
	err = client.Channel.RequeueMessage(client.ID, *id, timeoutDuration)
	// ...
	// 4. 更新 client 保存的关于消息的统计计数
	client.RequeuedMessage()
	return nil, nil
} // /nsq/nsqd/protocol_v2.go

// 将消息重新入队。这与 timeout 参数密切相关。
// 当 timeout == 0 时，直接将此消息重入队。
// 否则，异步等待此消息超时，然后 再将此消息重入队，即是相当于消息被延迟了
func (c *Channel) RequeueMessage(clientID int64, id MessageID, timeout time.Duration) error {
	// 1. 先将消息从 inFlightMessages 移除
	msg, err := c.popInFlightMessage(clientID, id)
	if err != nil {
		return err
	}
	// 2. 同时将消息从 in-flight queue 中移除，并更新 chanel 维护的消息重入队数量 requeueCount
	c.removeFromInFlightPQ(msg)
	atomic.AddUint64(&c.requeueCount, 1)
	// 3. 若 timeout 为0,则将消息重新入队。即调用 channel.put 方法，
    // 将消息添加到 memoryMsgChan 或 backend
	if timeout == 0 {
		c.exitMutex.RLock()
		if c.Exiting() {
			c.exitMutex.RUnlock()
			return errors.New("exiting")
		}
		err := c.put(msg)
		c.exitMutex.RUnlock()
		return err
	}
	// 否则，创建一个延迟消息，并设置延迟时间
	return c.StartDeferredTimeout(msg, timeout)
} // /nsq/nsqd/channel.go
```

至此，关于客户端的消息处理相关的命令请求已经阐述完毕，其实还有一些，比如`TOUCH`命令请求，即重置消息的超时时间。但这些处理过程都比较简单，只是对前面两小节的逻辑进行封装调用。

简单小结，本文的重点在两个方面：`topic`消息处理逻辑，即消息是如何从`topic`实例流向`channel`实例的，实际上就是将从`topic.memoryMsgChan`或`topic.backend`收到的消息的副本依次压入到其关联的`channel`的`in-flight queue`（对于正常的消息）或者`deferred queue`（对于延时消息）。另一个方面，`nsqd`消息处理处理逻辑，`nsqd`负责`in-flight queue`中的消息超时的处理工作，以及`deferred queue`中的消息延时时间已到的处理工作。另外，也阐述了一些有关客户端的命令请求的核心处理逻辑，包括生产者发布消息的流程，消费者订阅消息，以及发送`RDY/FIN/REQ`命令请求的实现逻辑。

至此，整个`nsq`实时消息队列的源码基本已经分析完毕，总共包括[6篇文章](https://qqzeng.top/categories/%E6%B6%88%E6%81%AF%E9%98%9F%E5%88%97/)。这里简单总结：
1. [nsq 简介和特性理解](https://qqzeng.top/2019/05/11/nsq-%E7%AE%80%E4%BB%8B%E5%92%8C%E7%89%B9%E6%80%A7%E7%90%86%E8%A7%A3/)简要介绍`nsq`的各个组件及系统的核心工作流程，并重点阐述几个值得关注的特性；
2. [nsq nsqlookupd 源码简析](https://qqzeng.top/2019/05/12/nsq-nsqlookupd-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)是以`nsqlookupd`命令为切入点，详细阐述`nsqlookupd`启动过程，其重点在于分析`nsqlookupd`的`tcp`请求处理器的相关逻辑，并梳理了`topic`查询和创建这两个典型的流程；
3. [nsq nsqd 服务启动源码简析](https://qqzeng.top/2019/05/13/nsq-nsqd-%E6%9C%8D%E5%8A%A1%E5%90%AF%E5%8A%A8%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)同样是以`nsqd`命令为切入点，行文逻辑同上一篇类似，即阐述`nsqd`服务启动的一系列流程，并详述`nsqd`与`nsqlookupd`交互的主循环逻辑，以及`nsqd`为客户端建立的`tcp`请求处理器；
4. [nsq topic 源码简析](https://qqzeng.top/2019/05/14/nsq-topic-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)内容相对简单，以`topic`为核心，阐述`topic`实例结构组成以及`topic`实例的创建、删除、关闭和查询流程；
5. [nsq channel 源码简析](https://qqzeng.top/2019/05/14/nsq-channel-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)文章的行文同上一篇文章类似，以`channel`为核心，阐述`channel`实例结构组成以及`channel`实例的创建、删除、关闭和查询流程，并附带分析了`Message`实例结构；
6. [nsq 消息发送订阅源码简析](https://qqzeng.top/2019/05/15/nsq-%E6%B6%88%E6%81%AF%E5%8F%91%E9%80%81%E8%AE%A2%E9%98%85%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)，是这一系列文章中最重要的一篇，它对于理解`nsq`分布式实时消息消息队列的关键工作原理至关重要。它重点阐述`topic`实例如何将消息发送给它所关联的`channel`集合，以及`nsqd`实例如何处理消息处理超时和被延迟的消息处理。另外，简要分析了客户端执行的几条命令请求，如生产者发布消息流程和消费者订阅消息流程。

完整的源码注释可以参考[这里](https://github.com/qqzeng/nsqio/tree/master/nsq)。考虑到个人能力有限，因此无论文章内容或源码注释存在错误，欢迎留言指正！







参考文献

[1]. https://github.com/nsqio/nsq
[2]. https://nsq.io/overview/quick_start.html