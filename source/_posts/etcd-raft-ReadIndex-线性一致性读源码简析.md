---
title: etcd-raft ReadIndex 线性一致性读源码简析
date: 2019-01-15 21:25:02
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 线性一致性
- 顺序一致性
---

上篇文章阐述了`etcd-raft`集群配置变更源码的相关逻辑，同时，在理论层面，从正反两个方面简要y论述了一次集群配置变更只能涉及到一个节点的原因。本文的主题为`etcd-raft`使用`ReadIndex`来实现线性一致性(`linearizability`)的实现原理。这包括两个方面，首先简要阐述线性一致性的理论知识，其次是结合`etcd-raft`的源码来简单梳理其如何使用`ReadIndex`来保证读请求的线性一致性。线性一致性广泛被应用于分布式应用中，是用于衡量一个并发系统是否正确的重要标准，我们通常谈论的`CAP`中的`C`指的即为线性一致性。需要说明的是，`etcd`是基于`raft`来提供一致性保证，虽然共识算法被用于保证状态的一致性，但并不代表实现共识算法的系统就自动具备了线性一致性，这是两个概念，换言之，`etcd-raft`必须在实现`raft`的基础上额外增加一些逻辑来保证系统具备线性一致性。

<!--More-->

## 线性一致性

简单而言，线性一致性是针对单个对象的单个操作的一种保证，它对单个对象的一系列操作（读和写）提供了一种实时的保证，即它们可以按照时间进行排序。不精确地说，`linearizability`可以保证：

- 一旦写操作写入了某个值，后面的（由`wall-clock`定义）读操作应该至少能够返回之前写的最新的值，换言之，它也可以返回之后的写操作所写入的值（注意不一定是读操作之前的最新的写的值）
- 一旦读操作返回了某个值，后面的读操作应该返回前一个读操作所返回的值，或者返回之后的写操作所写入的值。（注意不一定的是读之前最新的值）

并且线性一致性是可组合的(`composable`)，如果系统中每一个对象上的操作都符合线性一致性，那么系统中的所有操作都符合线性一致性。

另外，顺序一致性(`serializability`)很容易同线性一致性混淆。但实际上二者有较大的区别。且不严谨地说，线性一致性比顺序一致性提供更强的一致性保障语义。另外，不同于线性一致性属于分布式系统（并发编程系统）的概念，而顺序一致性是数据库领域的概念，它是对事务的一种保证，或者说，顺序一致性是针对一个或多个对象的一个或多个操作的一种保证。具体而言，它保证了多个事务（每个都可能包含了一组对于不同对象的读或写操作）的执行的效果等同于对这些事务的某一个顺序执行的效果。

顺序一致性是`ACID`中的`I`，且若每个事务都保证了正确性（`ACID`中的`C`），则这些事务的顺序执行也会保证正确性，可见，顺序一致性是数据库关于事务执行正确性的一种保证。不同于线性一致性，顺序一致性不会对事务执行的顺序强加任何实时的约束，换言之，其不需要事务的所有操作按照真实时间（应用程序指定的）严格排序的，只需要存在一个满足条件的顺序执行的顺序即可。最后顺序一致性也是不可组合的(`composable`)。

将线性一致性同顺序一致性结合起来，便是严格一致性(`serializability`)，即事务执行的行为等同于某一个顺序（串行）执行的效果，且这些串行的顺序对应实时的顺序。举一个简单的例子，如果存在两个事务`T1`及`T2`，我们先执行`T1`，`T1`中包含写`x`的操作，最后提交`T1`。我们然后执行`T2`，包含了读`x`的操作，然后提交它。若一个数据库系统满足严格一致性，则其会先执行`T1`并提交，然后才执行`T2`提交`T2`，因此`T2`能够读到`T1`中写入`x`的值，但如果数据库系统只提供顺序一致性，则其可能会将`T2`排序到`T1`之前。因此，可以将线性一致性看成是严格一致性的一种特殊情况，即一次执行只针对单个对象的单个操作。

另外论文 [Linearizability: Correctness Condition for Concurrent Objects](https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf)中给出了线性一致性的定义：

> Linearizability is a correctness condition for concurrent objects that provides the illusion that each operation applied by concurrent processes takes effect instantaneously at some point between its invocation and its response, implying that the meaning of a concurrent object’s operations can be given by pre- and post-conditions

因此，为了提供线性一致性，一个系统应该保证存在这样一个时间点，在这个时间点之后，系统需要被提交到一个新的状态，并且绝不能返回到之前旧的状态。而且，这样的转变是瞬时的，具备原子性。最后，概括而言，线性一致性必须提供三个方面的保证：a) 瞬间完成（保证原子性），b) 发生在invocation `和`response`两个事件之间，c) 能够反映出"最新的"值（特别注意这个最新的意义）。

关于此处对顺序一致性的顺序简单（可能不是完全精度）的阐述来源于 [线性一致性和 Raft](https://pingcap.com/blog-cn/linearizability-and-raft/)、[On Ways To Agree, Part 2: Path to Atomic Broadcast](https://medium.com/p/6e579965c4ce/edit) 、 [Linearizability versus Serializability](http://www.bailis.org/blog/linearizability-versus-serializability/) 以及[Strong consistency models](https://aphyr.com/posts/313-strong-consistency-models)。当然你也可以参照 [论文](https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf)。其中文献[1]举例了一个非常通俗易理解的实例来帮助解读对线性一致性理解的普遍的误区。特别地，文献[2]的`comment`讨论了关于"实时性"以及"可组合"更精确的含义。

## etcd-raft ReadIndex 线性一致性简析

在`etcd-raft`实现中，所有的写请求都会由`leader`执行并将请求日志同步到`follower`节点，且若`follower`节点收到客户端的写请求，则一般是把写请求转发给`leader`。那么对于读请求又如何处理呢？虽然`etcd-raft`能够对日志提供一致性保证，但若不加以协调，两个原因导致在`etcd-raft`中从不同节点读数据可能会出现不一致：

- `leader`节点与`follower`节点存在状态差，因为日志是从`leader`节点同步至`follower`节点，但不能保证任何时刻 ，二者的日志完全相同，即`follower`完全有可能落后于`leader`。另外`follower`之间同样如此，即也不能保证所有的`follower`节点的日志完全一致。因此必须对读操作进行协调。
- 如果限制只能从`leader`节点读取（至少`leader`状态机中最有可能包含最新的数据），这样仍然存在一个问题：若网络发生分区，则包含`quorum`节点的分区可能选举出一个新`leader`代替了旧`leader`，而旧`leader`却仍然以为自己是作法的`leader`，并依然处理客户端的读请求，则此时其可能会返回过期的数据，即与从包含`quorum`节点的分区读到的数据很有可能不同。

由此可见，必须对读请求作出限制，首先总结`etcd-raft`针对`leader`完成`ReadIndex`线性一致性读所作的协调处理的大致过程：

- `leader`需要同集群中`quorum`节点通信，以确保自己仍然是合法的`leader`。这一点容易理解，在上面的举例当中，若`leader`处于网络分区中的非`quorum`中，则其很可能会被取代，因此必须让`leader`确保自己仍然是`leader`。

- 等待状态机至少已经应用`ReadIndex`记录的日志。注意此处的**至少**两个字，简单而言，若状态机应用到`RedaIndex/commit index`之后的状态也能够使请求满足线性一致性，这同上文对线性一致性的解释中所强调的是一致的。需要这一条保证的原因是，虽然应用状态机的状态能达成一致，但不能保证多个节点会同时将同一个日志应用到状态机，换言之，各个节点的状态机所处的状态不能**实时一致**。因此，必须根据`commit index`对请求进行排序，以保证每个请求都至少能反映出状态机在执行完前一请求后的状态，因此，可以认为`commit`决定了读（也包括写）请求发生的顺序。日志是全局有序的，那么自然而然读请求也被严格排序了。因此这能保证线性一致性。

下文结合源码我们来了解`etcd-raft`是如何协调处理的。

首先简单了解相关数据结构，相关注释已概述了各结构的含义，主要涉及的代码目录为：`/etcd/raft/`。

```go
// ReadState 负责记录每个客户端的读请求的状态
// ReadState 最终会被打包放在 Ready 结构中以返回给应用，具体由应用负责处理客户端的读请求
// 即根据 commit index 确定何时才能从状态机中读对应的数据返回给客户端
type ReadState struct {
	Index      uint64 // 读请求对应的当前节点的 commit index
    RequestCtx []byte // 请求唯一标识，etcd 使用的是 8 位的请求 ID (/etcd/pkg/idutil/id.go)
} // /etcd/raft/read_only.go
// readIndexStatus 用来记录 follower 对 leader 的心跳消息的响应
type readIndexStatus struct {
	req   pb.Message // 原始 ReadIndex 请求，是应用在处理客户端读请求时向底层协议加发送的请求。
	index uint64 // leader 当前的 commit index，在收到此读请求时
	acks  map[uint64]struct{} // 记录了 follower 对 leader 的心跳的响应消息，
    // map 的键为 follower 节点的 ID，值是一个空的 struct，没有意义
} // /etcd/raft/read_only.go
// readyOnly 负责全局的 ReadIndex 请求
type readOnly struct {
	option           ReadOnlyOption // 表示为 ReadOnlySafe 或者 ReadOnlyLeaseBased
    // （两种不同的实现线性一致性的方式，官方推荐前者，也是默认的处理方式）
	pendingReadIndex map[string]*readIndexStatus // 为一个保存所有待处理的 ReadIndex 请求的 map，
    // 其中的 key 表示请求的唯一标识（转换成了字符串），而 value 为 readIndexStatus 结构实例
    readIndexQueue   []string // 请求标识 (RequestCtx) 的数组，同样转换成了 string 进行保存
} // /etcd/raft/read_only.go
```

了解这些数据结构，能够基本感知到它们会被使用在什么地方，或者说它们各自的作用是什么。下面来梳理下`etcd-raft`所实现的`ReadIndex`线性一致性的关键流程。

## 关键流程

我们仍然从客户端接收请求入手，但由于`raftexample`中并没有示例读请求的线性一致性的处理流程，因此，只能选择`etcd-server`来示例（要比 `raftexample`更复杂，但我们只关注与`ReadIndex`线性一致性相关逻辑，其它的不作多阐述）。整个过程包括两个大的部分：应用程序处理读请求（对读请求进行协调）以及底层协议库处理`ReadIndex`请求。

### 应用程序处理读请求

此部分相关逻辑涉及到的代码目录为`/etcd/etcdserver/`。在`etcd-server`在启动创建是会执行`Start()`函数，以进行一些在接收并处理请求之前的初始化工作，`Start()`函数会开启若干个`go routine`来处理初始化任务，其代码如下所示，其中关键的代码为`s.goAttach(s.linearizableReadLoop)`，顾名思义，其会开启一个协程来循环处理线性一致性读请求。

```go
// 循环处理线性一致性读请求
func (s *EtcdServer) linearizableReadLoop() {
	var rs raft.ReadState
	for {
		// 1. 构建 requestCtx 即请求 ID，且为全局唯一，具体查看 /etcd/pkg/idutil/id.go
		ctxToSend := make([]byte, 8)
		id1 := s.reqIDGen.Next()
		binary.BigEndian.PutUint64(ctxToSend, id1)
		// 2. 判断是否发生了 leader change 事件，若是，则重新执行
		leaderChangedNotifier := s.leaderChangedNotify()
		select {
		case <-leaderChangedNotifier:
			continue
		// 3. 等待 readwaitc 管道中 pop 出通知，
		// 显然，即为等待客户端发起读请求，具体是在函数 linearizableReadNotify 中 push 通知的
		case <-s.readwaitc:
		case <-s.stopping:
			return
		}
		// 4. 创建一个 notifier，替换原有的。它类似于一个 condition 并发语义
		nextnr := newNotifier()
		s.readMu.Lock()
		nr := s.readNotifier
		s.readNotifier = nextnr
		s.readMu.Unlock()
		lg := s.getLogger()
		// 这里构建一个可取消的机制
		cctx, cancel := context.WithTimeout(context.Background(), s.Cfg.ReqTimeout())
		// 5. 一旦收到一个客户端的读请求，则向底层协议库发送 ReadIndex 请求
		// 底层协议库会构建一个类库 MsgReadIndex 的消息，并将 ctxToSend 作为 Message 的 Entry.Data
		if err := s.r.ReadIndex(cctx, ctxToSend); err != nil {
			// ...
		}
		cancel()
		var (
			timeout bool
			done    bool
		)
		// 6. 设置了超时处理
		for !timeout && !done {
			select {
			// 7. 若从 readStateC 收到了 ReadState 通知，则说明底层协议库已经处理完成。
			// 事实上，上层应用程序（在此处是/etcd/etcdserver/raft.go）当收到底层协议库的 Ready 通知时，
			// 并且 Ready 结构中包含的 ReadState 不为空，则会向 readStateC 管道中压入 ReadState 实例，
			// 此处就能 pop 出 ReadState 实例。总而言之，ReadIndex 请求执行至此处表示底层协议库已经处理完毕
			// 只需要等待状态机至少已经应用 ReadIndex 的日志记录即可
			case rs = <-s.r.readStateC:
				done = bytes.Equal(rs.RequestCtx, ctxToSend)
				// ...
			case <-leaderChangedNotifier:
				// ...
			case <-time.After(s.Cfg.ReqTimeout()):
				// ...
			case <-s.stopping:
				return
			}
		}
		if !done {
			continue
		}
		// 8. 获取 appliedIndex，判断其是否小于 ReadIndex，若是，则要继续等待，说明状态机此时仍未应用 ReadIndex 处日志
		if ai := s.getAppliedIndex(); ai < rs.Index {
			select {
			// 9. 等待被调用 s.applyWait.Trigger(index)，那些在index之前的索引上调用的 Wait，都会收到通知而返回。
			// 具体而言，在 server.go 中的 start() -> applyAll() 触发了通知
			// 且 触发调用 applyAll() 是由 etcdsever/raft.go 中 start() 函数往 applyc 中 push 了通知
			case <-s.applyWait.Wait(rs.Index):
			case <-s.stopping:
				return
			}
		}
		// unblock all l-reads requested at indices before rs.Index
		// 8. 否则，说明状态机已经至少应用到了 ReadIndex 日志，表明此时可以读取状态机中的内容，返回给客户端
		nr.notify(nil)
	}
} // /etcd/etcdserver/v3_server.go

// 用于触发 linearizableReadLoop() 函数执行一遍循环中的等待处理 ReadIndex 请求的逻辑
func (s *EtcdServer) linearizableReadNotify(ctx context.Context) error {
	// 1. 获取 notifier
	s.readMu.RLock()
	nc := s.readNotifier
	s.readMu.RUnlock()
	// signal linearizable loop for current notify if it hasn't been already
	// 2. 向 readwaitc 管道中 push 一个空结构，以通知有 ReadIndex 请求到达
	select {
	case s.readwaitc <- struct{}{}:
	default:
	}
	// wait for read state notification
	// 3. 等待 notifier 的通知，即等待 linearizableReadLoop() 调用 notifier.notify() 函数
	// 一旦触发 notifier 管道中 pop 的信号，则表明已经 ReadIndex 请求的准备工作已全部完毕
	// 这包含两个部分：其一是底层协议库的工作，leader 确认自己仍旧是 leader
	// 其二，等待节点的状态机至少已经应用到 ReadIndex 处的日志
	// 此时，就可以正式从状态机中读取对应的请求的内容
	select {
	case <-nc.c:
		return nc.err
	case <-ctx.Done():
		return ctx.Err()
	case <-s.done:
		return ErrStopped
	}
} // /etcd/etcdserver/v3_server.go
```

总结而言，上述两个函数 `linearizableReadNotify()`及`linearizableReadLoop()`相当于锁的功能（此锁中包含多个条件等待操作），底层协议库未走完`ReadIndex`请求之前，或者应用层还未将`ReadIndex`应用到状态机之前，这把锁保证应用不会从状态机中读取请求数据，因此也不会返回对客户端读请求的响应。另外，顺便提一名，`linearizableReadNotify()`是当应用收到客户端的读请求时调用的，即在函数`Range()`中被调用，关键部分代码如下：

```go
func (s *EtcdServer) Range(ctx context.Context, r *pb.RangeRequest) (*pb.RangeResponse, error) {
	var resp *pb.RangeResponse
	// ...
	if !r.Serializable {
		err = s.linearizableReadNotify(ctx)
		if err != nil {
			return nil, err
		}
	}
	// ...
	return resp, err
} // // /etcd/etcdserver/v3_server.go
```

关于`ReadIndex`请求在应用程序层（服务端层）被处理的过程已经解析完毕。下文阐述底层协议库的处理。

### 底层协议库处理 ReadIndex 请求

底层协议库提供处理`ReadIndex`请求的一个接口：`ReadIndex()`，上层应用程序也正是调用此函数来使用协议库的协调功能。其中完整的调用栈为`ReadIndex() -> step() -> stepWithWaitOption`，然后通过将消息压入`recvc`管道，使得在`run()`函数从管道中收到消息，然后调用`raft.Step()`函数，经过一系列的检查之后，进入了`stepLeader()`函数，对应`leader`节点的处理流程，重要的代码如下所示：

```go
// 接收上层应用程序的 ReadIndex 请求
func (n *node) ReadIndex(ctx context.Context, rctx []byte) error {
	// 创建一个 MsgReadIndex 的消息，其中 message 中的 entry 的 data 为请求的标识
	return n.step(ctx, pb.Message{Type: pb.MsgReadIndex, Entries: []pb.Entry{{Data: rctx}}})
} // /etcd/raft/node.go
```

进入到`stepLeader()`函数后，随即根据消息类型进行`MsgReadIndex`分支。代码如下：

```go
func stepLeader(r *raft, m pb.Message) error {
	switch m.Type {
        // ...
		case pb.MsgReadIndex:
		if r.quorum() > 1 {
            // 1. 如果 leader 在当前任期内没有提交过日志，则直接返回，不处理此 ReadIndex 请求
			// 否则会造成 过期读 甚至不正确的读
			if r.raftLog.zeroTermOnErrCompacted(r.raftLog.term(r.raftLog.committed)) != r.Term {
				// Reject read only request when this leader has not committed any log entry at its term.
				return nil
			}
			// 2. 判断线性一致性读的实现方式
			switch r.readOnly.option {
			case ReadOnlySafe: // 3. 采用 ReadIndex 实现
				// 3.1 使用 leader 节点当前的 commit index 及 ReadIndex 消息 m 构造一个 readIndexStatus，并追加到 pendingReadIndex 中
				r.readOnly.addRequest(r.raftLog.committed, m)
				// 3.2 将此请求的ID(rctx)作为参数，并向集群中的节点广播心跳消息
				r.bcastHeartbeatWithCtx(m.Entries[0].Data)
			case ReadOnlyLeaseBased: // 4. 采用 leaseBase 实现
				// ...
			}
		} else {
			r.readStates = append(r.readStates, ReadState{Index: r.raftLog.committed, RequestCtx: m.Entries[0].Data})
		}
		return nil
	}
	// ...
} // /etcd/raft/raf.go

// 并负责更新 pendingReadIndex(当前正在被处理的 ReadIndex 请求)，以及 readIndexQueue
func (ro *readOnly) addRequest(index uint64, m pb.Message) {
	ctx := string(m.Entries[0].Data)
	if _, ok := ro.pendingReadIndex[ctx]; ok {
		return
	}
	ro.pendingReadIndex[ctx] = &readIndexStatus{index: index, req: m, acks: make(map[uint64]struct{})}
	ro.readIndexQueue = append(ro.readIndexQueue, ctx)
} // /etcd/raft/read_only.go

// 向集群中所有的节点发送心跳消息
func (r *raft) bcastHeartbeatWithCtx(ctx []byte) {
	r.forEachProgress(func(id uint64, _ *Progress) {
		if id == r.id {
			return
		}
		r.sendHeartbeat(id, ctx)
	})
} // /etcd/raft/raf.go
// 向指定节点发送心跳消息，并带上 ctx
func (r *raft) sendHeartbeat(to uint64, ctx []byte) {
	commit := min(r.getProgress(to).Match, r.raftLog.committed)
	m := pb.Message{
		To:      to,
		Type:    pb.MsgHeartbeat,
		Commit:  commit,
		Context: ctx,
	}
	r.send(m)
} // /etcd/raft/raf.go
```

当消息经网络传输到达`follower`节点后，`follower`收到此心跳消息时，其相关的处理如下所示：

```go
func stepFollower(r *raft, m pb.Message) error {
	switch m.Type {
		// ...
		case pb.MsgHeartbeat:
            r.electionElapsed = 0
            r.lead = m.From
            r.handleHeartbeat(m)
         // ...
	}
	return nil
} // /etcd/raft/raf.go
// 处理心跳消息的逻辑也很简单，应用 commit index，然后发送心跳消息响应，并带上消息中的 ctx
func (r *raft) handleHeartbeat(m pb.Message) {
	r.raftLog.commitTo(m.Commit)
	r.send(pb.Message{To: m.From, Type: pb.MsgHeartbeatResp, Context: m.Context})
}
```

同样，当`leader`收到心跳消息响应的处理逻辑如下所示：

```go
func stepLeader(r *raft, m pb.Message) error {
	// ...
	switch m.Type {
        // ...
		case pb.MsgHeartbeatResp:
		// 1. 更新 leader 为消息中的节点的 progress 对象实例
		pr.RecentActive = true
		pr.resume()
		// free one slot for the full inflights window to allow progress.
		if pr.State == ProgressStateReplicate && pr.ins.full() {
			pr.ins.freeFirstOne()
		}
		// 2. 若发现节点日志落后，则进行日志同步
		if pr.Match < r.raftLog.lastIndex() {
			r.sendAppend(m.From)
		}
		// 3. 只有 ReadOnlySafe 类型的消息需要针对性处理，且其 ctx 不能为空
		if r.readOnly.option != ReadOnlySafe || len(m.Context) == 0 {
			return nil
		}
		// 4. 更新 pendingReadIndex 中的 ack 字典（因为收到了 follower 的响应），并查看此时心跳响应是否达到 quorum
		ackCount := r.readOnly.recvAck(m)
		// 5. 若没达到 quorum 的心跳响应，则直接返回，说明此时流程还未走完
		if ackCount < r.quorum() {
			return nil
		}
		// 6. 在 pendingReadIndex 中返回 m 以前的所有的 readIndexStatus，一个 slice
		// 因为此请求依次顺序处理的，若此请求满足了底层协议库的条件，那么此请求之前的消息也会满足。
		rss := r.readOnly.advance(m)
		// 7. 循环 readIndexStatus，并将其追加到
		for _, rs := range rss {
			req := rs.req
			// 7.1 若是节点本地的 ReadIndex 请求，则直接将其追加到 ReadState 结构中，最后会打包到 Ready 结构，由 node 返回给上层应用程序
			if req.From == None || req.From == r.id { // from local member
				r.readStates = append(r.readStates, ReadState{Index: rs.index, RequestCtx: req.Entries[0].Data})
			} else {
				// 7.2 否则此消息则是来源于 follower，则向 follower 发送 MsgReadIndexResp 类型的消息
				r.send(pb.Message{To: req.From, Type: pb.MsgReadIndexResp, Index: rs.index, Entries: req.Entries})
			}
		}
	}
	return nil
} // /etcd/raft/raf.go

// 通知 readonly 结构，leader 节点收到了 follower 节点的心跳消息响应（此心跳消息是针对 ReadIndex 请求而发送的）
func (ro *readOnly) recvAck(m pb.Message) int {
	rs, ok := ro.pendingReadIndex[string(m.Context)]
	if !ok {
		return 0
	}
	rs.acks[m.From] = struct{}{}
	// 返回此时 leader 已经收到的响应消息的数量
	return len(rs.acks) + 1
} // /etcd/raft/read_only.go
```

至此，关于`leader`节点处理`ReadIndex`请求的流程已经阐述完毕，总的流程比较简单，即`leader`通过一轮心跳消息来确认自己仍然是`leader`。另外，若客户端将读请求发送给了`follower`节点，`etcd-raft`的实现是：应用层会调用协议的核心库的`ReadIndex`()方法，然后让`follower`节点先将`ReadIndex`消息发送给`leader`，接下来`leader`同样走一圈上面的流程，在确认自己依旧为`leader`后，将确认的`ReadIndex`通过`MsgReadIndexResp`消息发送给`follower`节点，最后同样，`follower`节点将构造`ReadState`并记录`commit index`，最后由上层应用收到`Ready`结构后，从中取出`ReadState`。因此，综合来看，若`ReadIndex`请求发送给了`follower`，则`follower`先要去问`leader`查询`commit index`，然后同样构造`ReadState`返回给上层应用，这和`leader`的处理是一样的。关于`follower`收到`MsgReadIndex`消息的核心代码如下：

```go
func stepFollower(r *raft, m pb.Message) {
    switch m.Type {
    ......
    case pb.MsgReadIndex:
        if r.lead == None {
            return
        }
        m.To = r.lead 
        r.send(m) // 先将消息转发给 leader
    case pb.MsgReadIndexResp: // 最后收到 leader 的 MsgReadIndexResp 消息回复后，
        // 追加到其 ReadStates 结构中，以通过 Ready 返回给上层应用程序
        r.readStates = append(r.readStates, ReadState{Index: m.Index, RequestCtx: m.Entries[0].Data})
    ......
} // /etcd/raft/raf.go
```

至此，关于`etcd-raft`如何处理`ReadIndex`线性一致性读的相关逻辑已经分析完毕。

最后，简单提一点，当节点刚被选举成为`leader`时，如果其未在新的`term`中提交过日志，那么其所在的任期内的`commit index`是无法得知的，因此，在`etcd-raft`具体实现中，会在`leader`刚选举成功后，马上提交追加提交一个`no-op`的日志（代码如下所示），在这之前所有客户端（应用程序）发送的读请求都会被阻塞（写请求肯定不会，其实若是有写请求了，也就不用提交空日志了）。通过此种方式可以确定新的`term`的`commit index`。

```go
func (r *raft) becomeLeader() {
	r.step = stepLeader
	r.reset(r.Term)
	r.tick = r.tickHeartbeat
	r.lead = r.id
	r.state = StateLeader
	r.prs[r.id].becomeReplicate()
	r.pendingConfIndex = r.raftLog.lastIndex()
	// 提交了一条 no-op 日志
	emptyEnt := pb.Entry{Data: nil}
	if !r.appendEntry(emptyEnt) {
		r.logger.Panic("empty entry was dropped")
	}
	r.reduceUncommittedSize([]pb.Entry{emptyEnt})
	r.logger.Infof("%x became leader at term %d", r.id, r.Term)
} // /etcd/raft/raft.go
```

简单小结，本文先是从理论角度阐述了什么是线性一致性，并且它具备什么特征。相比于顺序一致性，它们的不同点在哪里，最后线性一致性结合顺序一致性，即为严格一致性。关于这部分理论内容，读者若有兴趣，可以参考参考文献的[1]-[5]，讲得更完备和精确。后一部分内容就结合`etcd` 的代码阐述了其具体如何保证`ReadIndex`线性一致性，大概的流程为：先执行应用程序层对读请求的控制，它类似于一把锁的功能，在底层协议库未完成线性一致性相关的逻辑处理之前，会阻塞应用的读请求的处理，直至底层协议库走一圈后返回，才能继续处理，然后继续判断此时`ReadIndex`处的日志是否有被应用（若状态机已应用到`ReadIndex`之后的日志也完全可以），直至`ReadIndex`日志被提交才能返回，即才能释放锁，允许应用程序读取状态机。





参考文献

[1]. [线性一致性和 Raft](https://pingcap.com/blog-cn/linearizability-and-raft/)
[2]. [On Ways To Agree, Part 2: Path to Atomic Broadcast](https://medium.com/p/6e579965c4ce/edit)
[3]. [Linearizability versus Serializability](http://www.bailis.org/blog/linearizability-versus-serializability/)
[4]. [Strong consistency models](https://aphyr.com/posts/313-strong-consistency-models)
[5]. [Linearizability: Correctness Condition for Concurrent Objects](https://cs.brown.edu/~mph/HerlihyW90/p463-herlihy.pdf)
[6]. https://github.com/etcd-io/etcd