---
title: etcd-raft 集群配置变更源码简析
date: 2019-01-15 11:05:23
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 分布式协调服务
---

上一篇文章阐述了`etcd-raft snopshot`相关逻辑，并从整体上把握`etcd-raft snapshot`的设计规范。本文的主题是集群配置变更的理论及实际的相关流程，即`etcd-raft`如何处理集群配置变更，且在配置变更前后必须保证集群任何时刻只存在一个`leader`。在`raft`论文中提出每次只能处理一个节点的变更请求，若一次性处理多个节点变更请求（如添加多个节点），可能会造成某一时刻集群中存在两个`leader`，但这是`raft`协议规范所不允许的。而`etcd-raft`的实现同样只允许每次处理一个配置变更请求。大概地，`etcd-raft`首先将配置变更请求同普通请求日志进行类似处理，即复制到`quorum`节点，然后提交配置变更请求。一旦`quorum`节点完配置变更日志的追加操作后，便触发`leader`节点所维护的集群拓扑信息变更（此时原集群拓扑所包含的节点才知道新的集群拓扑结构），而其它节点在收到`leader`的消息后，也会更新其维护的集群拓扑。

<!--More-->

## 集群配置信息变更

在结合代码阐述集群配置信息变更的流程之前，先简单了解论文中所阐述的集群配置变更理论。为什么一次集群配置信息变更（此处以增加新节点示例）只能增加一个节点？这包含两个部分：其一解释若一次增加两个节点会使得集群在某一时刻存在两个`leader`的情况。其二，阐述若一次只允许增加一个节点，则不会出现某一时刻存在两个两个`leader`的情况。

![raft集群配置信息变更](https://github.com/qqzeng/6.824/blob/master/src/raft/ConfChange.png?raw=true)

如图（论文原图）所示，集群配置变更前集群中节点数量为 3（包括`s1、s2`及`s3`），且假设最最初的`leader`为`s3`。假设集群配置变更时允许 2 个节点同时加入到集群中，那么原来的 3 个节点在知道新的集群拓扑结构前（即集群配置变更的请求日志被提交之前），它们认为集群中只包含 3 个节点。而当新加入的节点（`s4及s5`）提出加入请求时，`leader`节点开始对节点加入请求日志进行同步复制，假设在`s1`及`s2`提交日志之前，`s3、s4`于它们之前收到日志并成功回复，那么`leader`此时收到了	`quorum`个回复（`s1、s4`及`s5`），因此可以提交节点请求加入的日志，换言之，此时节点`s1、s4`及`s5`认为集群中存在 5 个节点，而`s2`和`s3`仍然认为集群中只包含 3 个节点（因为它们还未提交配置变更请求）。此时假设某种网络原因，`s1`与`s3`（`leader`节点）失联，则`s1`重新发起选举，并成功收到`s2`的回复（`s2`可以给`s1`投票的），因此`s1`成功选举为`leader`（因为它它认为自己收到了`quorum=3/2+1`=2节点的投票）。而`s3`此时也同样发起选举，它可以获得`s3、s4`及`s5`的选票，因此它也能成功当选为`leader`（它认为自己收到了`quorum=5/2+1=3`节点的投票）。此时，集群中存在两个`leader`，是不安全且不允许的（显然，两个`leader`会导致对于同一索引处的日志不同，违反一致性）。

那为什么每次只入一个节点就能保证安全性呢（即任何时刻都只能有一个`leader`存在）？同样，假设我们最初的集群中包含三个节点（`s1、s2`及`s3`），且最初的`leader`为`s1`，但此时只有一个节点加入（假设为`s4`）。那么我们从三个方面来讨论为什么能保证任意时刻只存在一个`leader`：

- 配置变更请求日志提交前。即此时原集群的节点（`s1、s2`及`s3`）都只知道原始集群拓扑结构信息，不知道新加入的节点信息（其`quorum=3/2+1=2`）。但新加入的节点认为集群中存在 4 个节点（因此其`quorum=4/2+1=3`）。因此，在`s1、s2`或`s3`当中任意一个或多个发起选举时，它们最多只能产生 1 个`leader`（与原始集群的选举一致，因为它们的集群拓扑视角均未变化）。而`s4`发起选举时，它不能得到`s1、s2`或`s3`任何一张选票（因为很明显它的日志比它们的要旧）。
- 配置变更请求日志提交中。即此时配置变更请求的日志已经被`leader`提交了，但并不是所有的节点都提交了。比如，`s1`及`s2`成功提交了日志，则此时若`s4`发起选举，它不能获取`quorum=3/1+1=3`张选票，因为它的日志要比`s1`和`s2`的要更旧，即只能获取`s3`的选票（不能成功当选 ），`若s3`发起选举的结果也类似（注意，其此刻不知道`s4`的存在，因此其`quorum=2`）。总而言之，已提交了日志的节点能够获取`quorum`张选票，而未提交日志的节点因为日志不够新因此不能获得`quorum`张选票。

- 配置变更请求日志提交后。这种情况比较简单，当配置变更请求已经提交了，集群中任意一个节点当选的条件必须是获得`quorum`张选票，且任意两个`quorum`存在交集，但一个节点只能投出一张选票（在一个`term`内），因此不可能存在两个节点同时当选为`leader`。

至此，关于论文中的理论已经阐述完毕。而`etcd-raft`也只允许一次只能存在一个配置变更的请求。下面来简单了解`etcd-raft`是如何处理配置变更请求。

## 关键流程

我们同样从`raftexample`着手，当客户端发起配置变更请求（这里以加入一个新节点作为示例）时，`etcd-raft`是如何处理的。上文提过，这主要包含两个过程：其一，配置变更请求日志的同步过程（同普通的日志请求复制流程类似）。其二，在日志提交之后，节点正式更新集群拓扑信息，直至此时，原集群中的节点才知道新节点的存在。主要涉及的代码的目录为：`/etcd/contribe/raftexample`及`/etcd/raft`。

在阐述配置变更相关流程逻辑前，我们简要帖出核心数据结构，比较简单：

```go
type ConfChange struct {
    // ID 为节点变更的消息id
	ID               uint64         `protobuf:"varint,1,opt,name=ID" json:"ID"`
    // 配置信息变更的类型，目前包含四种
	Type             ConfChangeType `protobuf:"varint,2,opt,name=Type,enum=raftpb.ConfChangeType" json:"Type"`
    // 配置信息变更所涉及到的节点的 ID
	NodeID           uint64         `protobuf:"varint,3,opt,name=NodeID" json:"NodeID"`
	Context          []byte         `protobuf:"bytes,4,opt,name=Context" json:"Context,omitempty"`
} // /etc/raft/raftpb/raft.pb.go

type ConfChangeType int32
const (
	ConfChangeAddNode        ConfChangeType = 0
	ConfChangeRemoveNode     ConfChangeType = 1
	ConfChangeUpdateNode     ConfChangeType = 2
	ConfChangeAddLearnerNode ConfChangeType = 3
) // /etc/raft/raftpb/raft.pb.go
```

我们知道，关于`raftexample`示例，它可以通过两种方式加入集群，其一是集群节点信息初始化，即在集群启动时便知道存在哪些节点，这不属于我们本文讨论的范围。其二是集群正常运行过程中，一个节点要加入集群，它可以通过向客户端发出一个 HTTP POST 请求以加入集群：

```shell
curl -L http://127.0.0.1:12380/4 -XPOST -d http://127.0.0.1:42379 
raftexample --id 4 --cluster http://127.0.0.1:12379,http://127.0.0.1:22379,http://127.0.0.1:32379,http://127.0.0.1:42379 --port 42380 --join
```

在应用的 HTTP 处理器模块接收到请求后，会构建一个配置变更对象，通过`confChangeC`管道将其传递给`raftNode`模块，由`raftNode`进一步调用`node`实例的`ProposeConfChange()`函数。相关代码如下：

```go
func (h *httpKVAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	key := r.RequestURI
	switch {
	case r.Method == "PUT":
        // ...
	case r.Method == "GET":
		// ...
	case r.Method == "POST":
		url, err := ioutil.ReadAll(r.Body)
		// ...
		// 解析参数
		nodeId, err := strconv.ParseUint(key[1:], 0, 64)
		if err != nil {
			log.Printf("Failed to convert ID for conf change (%v)\n", err)
			http.Error(w, "Failed on POST", http.StatusBadRequest)
			return
		}
		// 构建 ConfChang 对象
		cc := raftpb.ConfChange{
			Type:    raftpb.ConfChangeAddNode,
			NodeID:  nodeId,
			Context: url,
		}
		// 将对象放入管道，通知 raftNode
		h.confChangeC <- cc
		w.WriteHeader(http.StatusNoContent)
	case r.Method == "DELETE":
		nodeId, err := strconv.ParseUint(key[1:], 0, 64)
		// ...
		cc := raftpb.ConfChange{
			Type:   raftpb.ConfChangeRemoveNode,
			NodeID: nodeId,
		}
		h.confChangeC <- cc
		// As above, optimistic that raft will apply the conf change
		w.WriteHeader(http.StatusNoContent)
	 // ...
	}
} // /etcd/contribe/raftexample/httpapi.go
```

```go
func (rc *raftNode) serveChannels() {
	go func() {
		confChangeCount := uint64(0)
		for rc.proposeC != nil && rc.confChangeC != nil {
			select {
			case prop, ok := <-rc.proposeC:
				// ...
			// 收到客户端的配置变更请求
			case cc, ok := <-rc.confChangeC:
				if !ok {
					rc.confChangeC = nil
				} else {
					confChangeCount++
					cc.ID = confChangeCount
					// 调用底层协议核心来处理配置变更请求（实际上即追加配置变更日志）
					rc.node.ProposeConfChange(context.TODO(), cc)
				}
			}
		}
		// client closed channel; shutdown raft if not already
		close(rc.stopc)
	}()
} // /etcd/contribe/raftexample/raft.go
```

在底层协议收到此调用请求后，会构建一个`MsgProp`类型的日志消息（这同普通的日志请求的类型是一致的），但消息中的`Entry`类型为`EntryConfChange`。通过一系列的函数调用，会将此请求消息放入`proc`管道，而在`node`的`run()`函数中会将消息从管理中取出，然后调用底层协议的核心处理实例`raft`的`Step()`函数，进而在最后调用其`stepLeader()`函数。部分代码如下（完整的函数调用栈为：`ProposeConfChange() -> Step() -> step() -> stepWithWaitOption() ->  r.Step() -> r.stepLeader()`）：

```go
func (n *node) ProposeConfChange(ctx context.Context, cc pb.ConfChange) error {
	data, err := cc.Marshal()
	if err != nil {
		return err
	}
	return n.Step(ctx, pb.Message{Type: pb.MsgProp, Entries: []pb.Entry{{Type: pb.EntryConfChange, Data: data}}})
} // /etcd/raft/node.go
```

```go
func stepLeader(r *raft, m pb.Message) error {
	switch m.Type {
	case pb.MsgBeat:
		r.bcastHeartbeat()
		return nil
	case pb.MsgCheckQuorum:
		// ...
	case pb.MsgProp: // 配置变更请求消息也走这里，因此其处理流程同普通的日志请求是类似的
		if len(m.Entries) == 0 {
			r.logger.Panicf("%x stepped empty MsgProp", r.id)
		}
		if _, ok := r.prs[r.id]; !ok {
			return ErrProposalDropped
		}
		if r.leadTransferee != None {
			r.logger.Debugf("%x [term %d] transfer leadership to %x is in progress; dropping proposal", r.id, r.Term, r.leadTransferee)
			return ErrProposalDropped
		}

		for i, e := range m.Entries {
			if e.Type == pb.EntryConfChange { // 若为配置变更请求消息，先判断其 pendingConfIndex（它限制了一次只能进行一个节点的变更）
			// 并且保证其不能超过 appliedIndex，因为只有一个变更请求被 pending，因此其肯定还未提交，因此正常情况下必须小于 appliedIndex
				if r.pendingConfIndex > r.raftLog.applied {
					r.logger.Infof("propose conf %s ignored since pending unapplied configuration [index %d, applied %d]",
						e.String(), r.pendingConfIndex, r.raftLog.applied)
					m.Entries[i] = pb.Entry{Type: pb.EntryNormal}
				} else {
					// 否则，若符合条件，则更新 pendingConfIndex 为对应的索引
					r.pendingConfIndex = r.raftLog.lastIndex() + uint64(i) + 1
				}
			}
		}
		// 追加配置变更消息到节点的 unstable
		if !r.appendEntry(m.Entries...) {
			return ErrProposalDropped
		}
		// 广播配置变更消息到 follower 节点
		r.bcastAppend()
		return nil
		}
	}
} // /etcd/raft/raft.go
```

关于`bcastAppend()`之后的逻辑，这里不再重复阐述，其同正常的日志消息的逻辑是一致的。因此，当上层应用调用网络传输组件将配置变更消息转发到集群其它节点时，其它节点同样会完成配置变更日志追加操作（同普通的日志请求消息追加的流程一致），而且`leader`节点处理响应同样与同步普通日志的响应的逻辑一致，这里也不再重复阐述。

最后，我们来了解当配置变更请求已经被同步到`quorum`节点后，准备提交的相关逻辑。这包括两个部分：其一是上层应用程序准备应用配置变更请求日志到状态机，然后会触发底层协议正式更新集群拓扑结构信息。

步骤一的相关代码如下（完整调用栈为：`serverChannels() -> publishEntries()`）：

```go
// whether all entries could be published.
func (rc *raftNode) publishEntries(ents []raftpb.Entry) bool {
	for i := range ents {
		switch ents[i].Type {
         // 准备应用普通的日志
		case raftpb.EntryNormal:
			// ...
		// 若为配置变更请求日志
		case raftpb.EntryConfChange:
			var cc raftpb.ConfChange
			// 1. 反序列化
			cc.Unmarshal(ents[i].Data)
			// 2. 调用 node 的 ApplyConfChange 正式更新对应节点所维护的集群拓扑结构信息
			// 即更新 progress 结构信息，这可能包括 learners 信息
			// 并且会返回集群的配置信息，即各节点的具体角色
			rc.confState = *rc.node.ApplyConfChange(cc)
			switch cc.Type {
			// 3. 调用网络传输组件变更对应的代表节点网络传输实例的信息
			case raftpb.ConfChangeAddNode:
				if len(cc.Context) > 0 {
					rc.transport.AddPeer(types.ID(cc.NodeID), []string{string(cc.Context)})
				}
			case raftpb.ConfChangeRemoveNode:
				if cc.NodeID == uint64(rc.id) {
					log.Println("I've been removed from the cluster! Shutting down.")
					return false
				}
				rc.transport.RemovePeer(types.ID(cc.NodeID))
			}
		}
		// 4. 更新当前已应用的日志索引
		rc.appliedIndex = ents[i].Index
		// special nil commit to signal replay has finished
		if ents[i].Index == rc.lastIndex {
			select {
			case rc.commitC <- nil:
			case <-rc.stopc:
				return false
			}
		}
	}
	return true
} // /etcd/contrib/raftexample/raft.go
```

而底层协议会执行具体的更新集群拓扑（包括更换已有节点的角色）的操作。相关代码如下：

```go
func (n *node) ApplyConfChange(cc pb.ConfChange) *pb.ConfState {
	var cs pb.ConfState
	select {
	// 将配置变更请求实例放入 confc 管道，n.run() 函数会循环从 confc 管道中取
	case n.confc <- cc:
	case <-n.done:
	}
	select {
	// 从 confstatec 管道中取出集群配置信息实例，返回给上层应用 raftNode
	case cs = <-n.confstatec:
	case <-n.done:
	}
	return &cs
} // /etcd/raft/node.go
```

```go
func (r *raft) addNode(id uint64) {
	r.addNodeOrLearnerNode(id, false)
} // etcd/raft/raft.go

func (r *raft) addLearner(id uint64) {
	r.addNodeOrLearnerNode(id, true)
} // etcd/raft/raft.go

func (r *raft) addNodeOrLearnerNode(id uint64, isLearner bool) {
	// 1. 获取此新加入节点的 progress 实例
	pr := r.getProgress(id)
	// 2. 若为空，则表示为新加入的节点，设置其 progress 对象信息
	if pr == nil {
		r.setProgress(id, 0, r.raftLog.lastIndex()+1, isLearner)
	} else { // 3. 否则节点已存在，可能是更新节点的具体的角色
		if isLearner && !pr.IsLearner {
			// can only change Learner to Voter
			r.logger.Infof("%x ignored addLearner: do not support changing %x from raft peer to learner.", r.id, id)
			return
		}
		if isLearner == pr.IsLearner {
			return
		}
		// change Learner to Voter, use origin Learner progress
		// 3.1 考虑从 Learner 切换到 Voter 的角色（Voter 角色的节点保存在 prs 数组）
		delete(r.learnerPrs, id)
		pr.IsLearner = false
		r.prs[id] = pr
	}
	// 4. 如果当前节点即为新加入的节点，则设置是否是 Learner
	if r.id == id {
		r.isLearner = isLearner
	}
	// When a node is first added, we should mark it as recently active.
	// Otherwise, CheckQuorum may cause us to step down if it is invoked
	// before the added node has a chance to communicate with us.
	// 5. 当节点第一次被加入时，需要标记节点最近为 活跃，否则在节点正式与 leader 通信前，可能会导致 leader 节点下台
	pr = r.getProgress(id)
	pr.RecentActive = true
} // etcd/raft/raft.go
```

```go
// 从集群中移除指定节点
func (r *raft) removeNode(id uint64) {
	// 1. 从当前节点维护的其它节点的 progress 对象数组中移除欲删除节点的信息
	r.delProgress(id)
	// do not try to commit or abort transferring if there is no nodes in the cluster.
	if len(r.prs) == 0 && len(r.learnerPrs) == 0 {
		return
	}
	// 2. 节点删除操作，更新了 quorum 的大小，因此需要检查是否有 pending 的日志项已经达到提交的条件了
	if r.maybeCommit() {
		// 2.1 若确实提交了日志项，则将此消息进行广播
		r.bcastAppend()
	}
	// 3. 如果当前被移除的节点是即将当选为 Leader 的节点则中断此 Leader 交接过程
	if r.state == StateLeader && r.leadTransferee == id {
		r.abortLeaderTransfer()
	}
} // /etcd/raft/raft.go
```

至此，集群配置信息的变更的相关流程源码已经简单分析完毕。

简单小结，本文主要从两个方面阐述集群配置变更：首先结合论文从理论角度阐述为什么一次集群配置变更只能涉及到单个节点，从正反两个方面进行简单讨论证明。其次，结合`etcd-raft`中集群配置信息变更的代码具体叙述其中的流程，流程的第一阶段大部分已略过，这同普通日志的提交、追加、同步及响应过程类似，流程的第二阶段为节点执行集群拓扑配置信息的更新过程，直至此时，原集群中的节点，才能感知到新加入节点的存在，因此会更新其`quorum`。





参考文献

[1]. Ongaro D, Ousterhout J K. In search of an understandable consensus algorithm[C]//USENIX Annual Technical Conference. 2014: 305-319.
[2]. https://github.com/etcd-io/etcd

