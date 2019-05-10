---
title: etcd-raft LeaseRead 线性一致性源码简析
date: 2019-01-16 15:50:39
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 线性一致性
---

上篇文章阐述的是`etcd-raft`基于`ReadIndex`实现线性一致性的相关逻辑，这包括上层应用程序对客户端读请求的控制，以及底层协议库实现`ReadIndex`线性一致性的逻辑，另外，也简单阐述了线性一致性相关理论，包括顺序一致性及严格一致性。本文的主题同样是线性一致性，但是是`etcd-raft`提供的另一种实现方式：`LeaseRead`。相比于基于`ReadIndex`的实现，它性能更好，因为它没有`heartbeat`开销，但它却不能保证绝对意义上的线性一致性读，这依赖于机器时钟，工程实现只能尽可能保证在实际运行中不出错。基于`lease`的线性一致性读的原理和实现都比较简单。

<!--More-->

上篇文章谈到过，基于`ReadIndex`实现的线性一致性的一个关键步骤即为`leader`通过广播心跳来确保自己的领导地位，显然这会带来网络开销（虽然实际中这种开销已经很小了）。因此可以考虑进一步优化。在`Raft`论文中提到了一种通过`clock + heartbeat`的`lease read`的优化方法，即每次当`leader`发送心时，先记录一个时间`start`，当`quorum`节点回复`leader`心跳消息时，它就可以将此`lease`续约到`start + election timeout`时间点，当然实际上还要考虑时钟偏移（`clock drift`），其中的原理也比较简单，因为任何时候若`follower`节点想发起新的一轮选举，必须等到`election timeout`后才能进行，这也就间接保证了在这段时间内无论什么情况（比如网络分区），`leader`都绝对拥有领导地位。再次强调，这依赖于机器的时钟飘移速率，换言之，若各机器之间的时钟差别过在，则此种基于`lease`的机制就可能出现问题。

下面结合`etcd-raft`的源码来简单梳理这个过程。我们重点关注两个逻辑：其一，在`lease`有效期内，`leader`如何处理读请求。其二，`leader`如何更新（续约）其`lease`。

## 基于 lease read 的线性一致性

基于`lease read`同基于`ReadIndex`实现的线性一致性在应用程序层的逻辑是一致的，不作多阐述。重点了解协议库是如何处理的。同样，我们定位到`leader`的`stepLeader()`函数，同样是`MsgReadIndex`分支：

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
				// ...
			case ReadOnlyLeaseBased: // 4. 采用 leaseBase 实现
				ri := r.raftLog.committed // 4.1 获取当前的 commit index
				// 4.2 如果是本地的请求，则直接将 ReadState 追加到数组中，里面包含了 leader 的 commit index 及 ctx（请求唯一标识）
				if m.From == None || m.From == r.id { // from local member
					r.readStates = append(r.readStates, ReadState{Index: r.raftLog.committed, RequestCtx: m.Entries[0].Data})
				} else {
					// 4.3 如果 follower 节点转发的，则直接向其回复 MsgReadIndexResp 消息，并带上commit index 及 Entries
					r.send(pb.Message{To: m.From, Type: pb.MsgReadIndexResp, Index: ri, Entries: m.Entries})
				}
			}
		} else {
			r.readStates = append(r.readStates, ReadState{Index: r.raftLog.committed, RequestCtx: m.Entries[0].Data})
		}

		return nil
	}
    // ...
} // /etcd/raft/raft.go
```

上面的流程很简单，不多阐述。需要注意的一点是，若是 `follower` 收到读请求，其基于`lease read`的处理逻辑同基于`ReadIndex`一致，即要先向`leader`查询`commit index`。下面重点了解`lease`的续约逻辑。

## lease 续约

在阐述`lease`具体的续约准则之前，我们先了解下在`etcd-raft`中，触发检测`lease`是否过期的相关代码，因为`leader`要确保自己的领导地位，因此它必须周期性地检查自己是否具备领导地位。它通过周期性地向自己发送`MsgCheckQuorum`类型消息来验证自己是否具备领导地位（即此次`lease`是否能成功续约）。代码如下：

```go
// leader 会周期性地给自己发送 MsgCheckQuorum 消息
func (r *raft) tickHeartbeat() {
	r.heartbeatElapsed++
	r.electionElapsed++
	// 若达到了 electionTimeout 的时间（并非 heartbeat timeout），则需要向自己发送消息
	if r.electionElapsed >= r.electionTimeout {
		r.electionElapsed = 0
		if r.checkQuorum {
			r.Step(pb.Message{From: r.id, Type: pb.MsgCheckQuorum})
		}
		// If current leader cannot transfer leadership in electionTimeout, it becomes leader again.
		if r.state == StateLeader && r.leadTransferee != None {
			r.abortLeaderTransfer()
		}
	}
	// ...
} // /etcd/raft/raft.go
```

`leader`同样在`stepLeader()`函数中处理`MsgCheckQuorum`类型的消息：

```go
func stepLeader(r *raft, m pb.Message) error {
	switch m.Type {
	// ...
	case pb.MsgCheckQuorum:
		if !r.checkQuorumActive() {  // 检查是否 quorum 节点仍然活跃
			r.logger.Warningf("%x stepped down to follower since quorum is not active", r.id)
			r.becomeFollower(r.Term, None)
		}
		return nil
    }
    // ...
} // /etcd/raft/raft.go

func (r *raft) checkQuorumActive() bool {
	var act int
	// 循环检查 leader 维护的 progress 对象数组，来判断对应的节点是否活跃
	r.forEachProgress(func(id uint64, pr *Progress) {
		if id == r.id { // self is always active
			act++
			return
		}
		if pr.RecentActive && !pr.IsLearner {
			act++
		}
		// 并且在每次检查完毕后，都要重置它，以确保下一次检查不会受到此次结果的影响
		pr.RecentActive = false
	})
	// 若存在 quorum 节点活跃，则返回 true
	return act >= r.quorum()
} // etc/raft/raft.go
```

关于`lease`续约不同的系统可能有不能的实现，但其目的只有一个：确认`follower`依然遵从`leader`的领导地位。这可以从几个方面体现出来，其一，如果每次`leader`发送的心跳消息(`MsgHeartbeat`)，节点都响应了，则证明此节点依然受到`leader`的领导。其二，若每次`leader`发送的日志同步消息(`MsgApp`)，节点都响应了，则同样能够证明`leader`的领导地位。最后，其实在节点刚刚加入集群时，也标记其接受`leader`的领导。这就是`RecentActive`所被标记为`true`的地方。因此，每当触发了`election timeout`事件，`leader`都需要重新检查自己是否仍然具备领导地位，实质上就是检查每个节点的`RecentActive`是否被设置，如果具备，则表明成功续约了`lease`，因此可以不经额外的处理，就能够直接返回自身的`commit index`作为`ReadIndex`的响应。整个流程比较简单，其中原理也较容易理解。

简单小结，本文先是简单阐述了关于`lease read`实现线性一致性（比基于`ReadIndex`的实现更有效率）的基本原理，然后结合`etcd-raft`的实现来进一步细化理解整个过程，这包括两方面：其一是基于`lease read`线性一致性的处理逻辑（在`lease`有效期内）。其二是`lease`的续约过程，即何时触发续约事件，以及续约的条件是什么。值得一提的是，不同的系统的对续约条件的实现可能不同，而且为了尽可能保证基于`lease`实现的线性一致性的正确性，会加入一些优化动作。





参考文献

[1]. https://github.com/etcd-io/etcd/tree/master/raft
[2]. [etcd-raft的线性一致读方法二：LeaseRead](https://zhuanlan.zhihu.com/p/31118381)