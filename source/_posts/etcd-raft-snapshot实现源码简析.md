---
title: etcd-raft snapshot实现源码简析
date: 2019-01-14 14:49:40
categories:
- 分布式系统
- 分布式系统协调服务
tags:
- 分布式系统
- snapshot管理
---

上一篇文章阐述了`etcd-raft`存储模块相关逻辑源码，准确而言是与日志存储相关，主要是围绕`raftLog`、`unstable`以及`Storage/MemoryStorage`展开，涉及流程较多，且结合流程逻辑阐述得比较详细。本文主题是`snapshot`，快照也属于存储的范畴，因此本文内容与上一篇文章存在重叠。不同的是，本文是围绕`snapshot`展开相关逻辑的分析。具体而言，首先简要介绍`snapshot`数据结构及重要接口实现，然后重点分析`snapshot`的全局逻辑（大部分源码已在上篇文章中分析），这主要包括如下四个子问题：其一，`leader`节点何时执行`snapshot`同步复制，其二，（应用程序）何时触发`snapshot`操作及，其三，（应用程序）如何应用`snapshot`数据，最后，`follower`节点何时以及如何应用`snapshot`数据事实上，第一、四两点是从底层协议的角度阐述与`snapshot`的相关操作，而第二、三点是从应用程序的角度来阐述`snapshot`相关操作（这其实涵盖了所有节点的操作）。但总的原则不变，目的是从整体上把握`snapshot`的逻辑，希望读者不要混淆。

<!--More-->

需要注意，`etcd-raft`中关于存储的组件`unstable`、`Storage`以及`WAL`都包含快照，其中前二者的日志项包括快照存储在内存中，`WAL`将日志项以及快照数据存储在磁盘上。所谓快照实际上表示的是某一时刻系统的状态数据，那么在此时刻之前所保留的日志可以清除，因此它明显具有压缩日志项、节约磁盘空间的作用（在`unstable`及`Storage`中仍旧存储在内存）。但`WAL`与前二者不同，实际上它存储的`snapshot`数据是指存储它的元数据信息（原因是进行日志重放时，只要从快照元数据记录的日志索引开始即可，在【[etcd-raft WAL日志管理源码简析](https://qqzeng.top/2019/01/11/etcd-raft-WAL%E6%97%A5%E5%BF%97%E7%AE%A1%E7%90%86%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)】章节详述），并且每次构建快照数据，它不会覆盖已有的快照数据，而`unstable`及`Storage`在更新快照时则会进行替换。另外，`etcd-raft`还提供一个`Snapshotter`组件来构建`Snapshot`数据，它也属于快照数据，而且是增量更新并保存并持久化到磁盘的快照数据目录下的。下面介绍的`Snapshot`数据结构指的便是此`Snapshot`类型数据。因为它们相互关联，但作用不同。因此希望读者不要将这几种类型的`snapshot`混淆，仔细理解每一处的含义。

## 数据结构

`Snapshot`的数据结构及其相关接口的实现较为简单，大致了解下即可，其中数据结构相关代码的主要目录为`/etcd/etcdserver/api/snap/`。

### Snapshot

`Snapshot`的数据结构如下所示：

```go
type Snapshot struct {
	Data             []byte           `protobuf:"bytes,1,opt,name=data" json:"data,omitempty"`
	Metadata         SnapshotMetadata `protobuf:"bytes,2,opt,name=metadata" json:"metadata"`
} // raft.pb.go

type SnapshotMetadata struct {
	ConfState        ConfState `protobuf:"bytes,1,opt,name=conf_state,json=confState" json:"conf_state"`
    // 系统构建快照时，最后一条日志项的索引值
	Index            uint64    `protobuf:"varint,2,opt,name=index" json:"index"`
	Term             uint64    `protobuf:"varint,3,opt,name=term" json:"term"`
} // raft.pb.go

type ConfState struct { 
    // 表示集群中的节点的信息， Nodes 表示 leader及follower的id数组，
    // 而 Learners 表示集群中 learner 的 id 数组
	Nodes            []uint64 `protobuf:"varint,1,rep,name=nodes" json:"nodes,omitempty"`
	Learners         []uint64 `protobuf:"varint,2,rep,name=learners" json:"learners,omitempty"`
} // raft.pb.go
```

`Snapshot`的数据结构比较简单。我们下面简单了解其几个关键接口实现，首先是创建快照（文件）：

```go
// 构建快照文件，应用程序使用此接口来创建持久化的快照文件
func (s *Snapshotter) SaveSnap(snapshot raftpb.Snapshot) error {
	if raft.IsEmptySnap(snapshot) {
		return nil
	}
	return s.save(&snapshot)
} // snapshotter.go

func (s *Snapshotter) save(snapshot *raftpb.Snapshot) error {
	start := time.Now()
	// 1. snapshot 文件命令规则：Term-Index.snap
	fname := fmt.Sprintf("%016x-%016x%s", snapshot.Metadata.Term, snapshot.Metadata.Index, snapSuffix)
	// 2. 序列化快照结构体数据
	b := pbutil.MustMarshal(snapshot)
	// 3. 生成 crc 检验数据
	crc := crc32.Update(0, crcTable, b)
	// 4. 生成快照 pb 结构数据
	snap := snappb.Snapshot{Crc: crc, Data: b}
	// 5. 序列化
	d, err := snap.Marshal()
	if err != nil {
		return err
	}
	snapMarshallingSec.Observe(time.Since(start).Seconds())
	// 6. 构建快照文件路径
	spath := filepath.Join(s.dir, fname)
	fsyncStart := time.Now()
	// 7. 快照文件存盘
	err = pioutil.WriteAndSyncFile(spath, d, 0666)
	// ...
	return nil
} // snapshotter.go
```

再简单也解加载快照文件的过程：

```go
// 加载快照文件，应用程序使用此接口来加载已存盘的快照文件
func (s *Snapshotter) Load() (*raftpb.Snapshot, error) {
	// 1. 获取快照文件目录下的所有快照谁的，并排序
	names, err := s.snapNames()
	// ...
	// 2. 遍历快照文件集合，并加载每一个快照文件到内存，形成*raftpb.Snapshot实例
	// load 的过程也比较简单，为创建的逆过程，包括反序列化及校验 crc
	var snap *raftpb.Snapshot
	for _, name := range names {
		if snap, err = loadSnap(s.lg, s.dir, name); err == nil {
			break
		}
	}
	// ...
	return snap, nil
} // snapshotter.go
```

快照数据结构比较简单，而且其相关接口的实现也比较简单，不多阐述。

## 关键流程

上文提到，`snapshot`是系统某时刻状态的数据，在`etcd-raft`中会在多个地方存储`snapshot`数据，这包括`unstable`、`Storage/MemoryStorage`、`WAL`以及`snap`日志文件。正是因为涉及到多个存储的结构，因此整个关于`snapshot`的逻辑也稍显啰嗦。此部分代码的主要目录为：`/etcd/raft/`、`/etcd/contrib/raftexample/`。

### snapshot 相关逻辑总结

大概地，关于`unstable`日志存储，它与底层协议库直接交互，当`leader`节点发现`follower`节点进度过慢时（这也包括节点新加入的情形），会尝试发送`MsgSnap`，以加快节点状态同步（关于`leader`如何知道`follower`节点的日志过旧的原因是`leader`为每个`follower`维护了其目前的日志进度视图，这通过`progress.go`实现）。更准确来说，`leader`节点在发现本节点的日志过长时（`MemoryStorage`的实现规则是将长度大于 10000  ），会将更早的日志`compact`掉以节约内存（这在应用每次收到`raft`协议核心的`Ready`通知时，都会检查是否可以触发构建快照）。因此，若`leader`在给`follower`节点同步日志时，其可能发现对应的（需要从哪一项日志开始同步）日志项不存在，那么它会认为对应的日志已经被`compact`掉，因此尝试使用同步快照来代替（即发送`MsgSnap`消息）。换言之，`unstable`中的`snapshot`是来自于`leader`节点的同步（若`follower`节点允许直接执行快照同步，会将`unstable`中的快照直接进行替换）。

而关于`Storage`日志存储中的快照的来源，则可能来自两处，其一是节点自身主动构建`snapshot`，即应用程序发现达到快照构建条件时，便触发快照创建，所以这部分快照所对应的数据已存在于节点的应用状态机中，因此也不需要被重放，其主要目的是进行日志压缩。其二是`leader`节点通过`MsgSnap`将快照同步到`follower`节点的`unstable`中，然后`follower`的会生成`Ready`结构并传递给上层应用（里面封装了`unstable`的`snapshot`数据），因此最终由`follower`节点的应用将`unstable`中的`snapshot`应用到节点的`Storage`中。此处的快照的作用使用同步快照数据来代替同步日志项数据，因此减少了网络及 IO 开销，并加速了节点状态的同步。

对比`unstable`和`Storage`中快照数据的来源可知，`unstable`中的快照数据也必须交给上层应用，由上层应用进行`WAL`持久化、保存`snap`日志并应用到`Storage`中。而`Storage`中的快照数据的另外一个来源则由节点应用层自身直接创建，当然，此时也要作`WAL`持久化并且记录`snap`日志。由此可见，`unstable`与`Storage`中的日志存储的内容差别较大。另外需要强调的是，`WAL`日志中的快照部分存储`snapshot`元信息。而`snap`的数据存储方法由使用`etcd-raft`的应用实现，这取决于应用存储的数据类型（在`etcd-raft`中使用的是`Snapshot`数据结构来存储）。

综上，基本涵盖了整个关于`snapshot`流程的逻辑。下面结合代码更详细地阐述各个逻辑，本文将它分为四个方面进行叙述：其一，`leader`节点何时执行`snapshot`同步复制，其二，（应用程序）何时触发`snapshot`操作及，其三，（应用程序）如何应用`snapshot`数据，最后，`follower`节点何时以及如何应用`snapshot`数据。（这四点其实可以串联在一起叙述，但本文还是将它们分开叙述，希望读者能够理清并串联好整个逻辑）

### leader 节点执行 snapshot 同步复制

上文提到当`leader`节点发现`follower`节点日志过旧时会使用同步`snapshot`复制来代替普通的日志同步（即发送`MsgSnap`而非`MsgApp`消息），这`leadaer`节点之所以能够发现`follower`节点的日志进度过慢的原因是，它使用为此`follower`节点保存的当前已同步日志索引来获取其`unstable`（也包括`Storage`）中的日志项（集合）时，发现不能成功获取对应的日志项，由此说明对应的日志项已经被`compact`掉了，即已经创建了快照。（关于如何创建快照，在下小节详述），因此，`leader`节点会向`follower`节点发送`MsgSnap`消息。相关代码及部分关键注释如下（下面只展示了关键函数的代码，整个流程为：`stepLeader() -> bcastAppend() -> sendAppend() -> maybeSendAppend()`）：

```go
func (r *raft) maybeSendAppend(to uint64, sendIfEmpty bool) bool {
	// 1. 获取 id 为 to 的 follower 的日志同步进度视图（具体查看 progress.go）
	pr := r.getProgress(to)
	// 2. 若对应 follower 节点未停止接收消息（停止的原因可能是在执行一个耗时操作，如应用快照数据）
	if pr.IsPaused() {
		return false
	}
	// 3. 构建消息实例
	m := pb.Message{}
	m.To = to
	// 4. 通过 Next(为节点维护的下一个需要同步的日志索引)查找对应的 term 及 ents
	// 注意：1. maxMsgSize 是作为控制最大的传输日志项数量
	// 		2. 其在查找对应的 term 及 ents 时，也会查找 Storage 中的日志项集合
	term, errt := r.raftLog.term(pr.Next - 1)
	ents, erre := r.raftLog.entries(pr.Next, r.maxMsgSize)
	if len(ents) == 0 && !sendIfEmpty {
		return false
	}
	// 5. 如果查找失败，则考虑发送 MsgSnap 消息
	if errt != nil || erre != nil { // send snapshot if we failed to get term or entries
		// 此处记录对应节点最近是活跃
		if !pr.RecentActive {
			r.logger.Debugf("ignore sending snapshot to %x since it is not recently active", to)
			return false
		}
		m.Type = pb.MsgSnap
		// 5.1 通过 raftLog 获取 snapshot 数据，若 unstable 中没有，则从 Storage 中获取
		snapshot, err := r.raftLog.snapshot()
		// ...
		m.Snapshot = snapshot
		sindex, sterm := snapshot.Metadata.Index, snapshot.Metadata.Term
		r.logger.Debugf("%x [firstindex: %d, commit: %d] sent snapshot[index: %d, term: %d] to %x [%s]",
			r.id, r.raftLog.firstIndex(), r.raftLog.committed, sindex, sterm, to, pr)
		// 5.2 更新对应节点的 progress 实例对象
		pr.becomeSnapshot(sindex)
		r.logger.Debugf("%x paused sending replication messages to %x [%s]", r.id, to, pr)
	} else { // 6. 否则进行日志同步，即发送正常的 MsgApp 消息
		m.Type = pb.MsgApp
		// ...
	}
	// 此处会将此消息打包到 raft.msgs 中，进一步会由 node 将其打包到 Ready 结构中，并转发给上层应用程序，
	// 由应用程序调用启用网络传输的组件，将消息发送出去（在上一篇文章中已经详述）
	r.send(m)
	return true
} // /etcd/raft/raft.go
```

### 何时触发  snapshot  操作

事实上，触发`snapshot`操作是由上层应用程序完成的（并非底层`raft`协议核心库的功能）。触发构建快照的规则是：`Storage`中的日志条目的数量大于 10000，一旦达到此条件，则会将日志项索引不在过去 10000 条索引范围内的日志执行`compact`操作，并创建对应的快照数据，记录到`WAL`日志文件，以及`snap`快照文件中。相关代码及部分关键注释如下（下面只展示了关键函数的代码，整个流程为：`startRaft() -> serveChannels() -> maybeTriggerSnapshot()`）：

```go
// 针对 memoryStorage 触发快照操作（如果满足条件）（注意这是对 memoryStorage 中保存的日志信息作快照）
func (rc *raftNode) maybeTriggerSnapshot() {
	// 0. 判断是否达到创建快照（compact）的条件
	if rc.appliedIndex-rc.snapshotIndex <= rc.snapCount {
		return
	}
	log.Printf("start snapshot [applied index: %d | last snapshot index: %d]", rc.appliedIndex, rc.snapshotIndex)
	// 1. 加载状态机中当前的状态数据（此方法由应用程序提供，在 kvstore 中）
	data, err := rc.getSnapshot()
	if err != nil {
		log.Panic(err)
	}
	// 2. 利用上述快照数据、以及 appliedIndex 等为 memoryStorage 实例创建快照（它会覆盖/更新 memoryStorage 已有的快照信息）
	snap, err := rc.raftStorage.CreateSnapshot(rc.appliedIndex, &rc.confState, data)
	if err != nil {
		panic(err)
	}
	// 3. 保存快照到 WAL 日志（快照的索引/元数据信息）
	// 以及到 snap 日志文件中（它包含所有信息，一般而言，此 snap 结构由应用程序决定，etcd-raft 的实现包含了元数据及实际数据）
	if err := rc.saveSnap(snap); err != nil {
		panic(err)
	}

	// 4. 如果满足日志被 compact 的条件（防止内存中的日志项过多），则对内存中的日志项集合作 compact 操作
	// compact 操作会丢弃 memoryStorage 日志项集中 compactIndex 之前的日志
	compactIndex := uint64(1)
	if rc.appliedIndex > snapshotCatchUpEntriesN {
		compactIndex = rc.appliedIndex - snapshotCatchUpEntriesN
	}
	if err := rc.raftStorage.Compact(compactIndex); err != nil {
		panic(err)
	}

	log.Printf("compacted log at index %d", compactIndex)
    // 5. 更新应用程序的快照位置(进度)信息
	rc.snapshotIndex = rc.appliedIndex
} // /etcd/contrib/raftexample/raft.go
```

### 如何应用 snapshot 数据

本小节所涉及的如何应用`snapshot`数据亦是针对应用程序而言（因为`follower`节点的`unstable`也会由协议库来应用`leader`节点发送的快照数据）。大概地，应用程序应用快照数据包含两个方面：其一，在节点刚启动时（宕机后重启）会进行日志重放，因此在重放过程中，若快照数据不为空（由`snap`存盘的快照数据，包括元信息及实际数据），则加载快照数据，并将其应用到`Storage`的快照中，而且会重放快照数据后的`WAL`日志项数据，并将其追加到`Storage`的日志项集。如此以来，节点便能重构其状态数据。其相关代码如下（实际完整调用为：`startRaft() -> serveChannels()`）：

```go
func (rc *raftNode) replayWAL() *wal.WAL {
	log.Printf("replaying WAL of member %d", rc.id)
	// 1. 从 snap 快照文件中加载 快照数据（包含元信息及实际数据）
	snapshot := rc.loadSnapshot()
	// 2. 从指定日志索引位置打开 WAL 日志，以准备读取快照之后的日志项
	w := rc.openWAL(snapshot)
	// 3. 读取指定索引位置后的所有日志
	_, st, ents, err := w.ReadAll()
	if err != nil {
		log.Fatalf("raftexample: failed to read WAL (%v)", err)
	}
	// 4. 应用程序创建一个 MemoryStorage 实例
	rc.raftStorage = raft.NewMemoryStorage()
	// 5. 若快照数据不为空，则将快照数据应用到 memoryStorage 中，替换掉已有的 snapshot 实例
	if snapshot != nil {
		rc.raftStorage.ApplySnapshot(*snapshot)
	}
	// 6. 设置 HardState 到 memoryStorage 实例
	rc.raftStorage.SetHardState(st)

	// append to storage so raft starts at the right place in log
	// 7. 将 WAL 重放的日志项集追加到 memoryStorage 实例（显然，此日志项不包含已经快照的日志项）
	rc.raftStorage.Append(ents)
	// send nil once lastIndex is published so client knows commit channel is current
	if len(ents) > 0 {
		// 8. 如果在快照后，仍存在日志项记录，则设置 lastIndex
		rc.lastIndex = ents[len(ents)-1].Index
	} else {
		// 9. 通知 kvstore，日志重放已经完毕，因此 kvstore 状态机也会从 snap 快照文件中加载数据
		// 参见下面的代码片段
        rc.commitC <- nil
	}
	return w
} // /etcd/raftexample/raft.go
```

```go
func (s *kvstore) readCommits(commitC <-chan *string, errorC <-chan error) {
	// raftNode 会将日志项 或 nil 放入 commitC 管道
	for data := range commitC {
		if data == nil {
			// done replaying log; new data incoming
			// OR signaled to load snapshot
			// 从 snap 快照文件中加载数据，这包括两种情形：
			// 一是重启时重放日志，
			// 二是当 leader 向 follower 同步 snapshot 数据时，节点会将其应用到 unstable 及 Storage 中，同样会保存到 WAL 及 snap 文件
			// 因此让状态机重新加载 snap 快照数据
			snapshot, err := s.snapshotter.Load()
			// ...
			if err := s.recoverFromSnapshot(snapshot.Data); err != nil {
				log.Panic(err)
			}
			continue
		}
		// 有新的数据已经被提交，因此将其应用到状态机中
		var dataKv kv
		dec := gob.NewDecoder(bytes.NewBufferString(*data))
		if err := dec.Decode(&dataKv); err != nil {
			log.Fatalf("raftexample: could not decode message (%v)", err)
		}
		s.mu.Lock()
		s.kvStore[dataKv.Key] = dataKv.Val
		s.mu.Unlock()
	}
// ...
} // /etcd/raftexample/kvstore.go

func (s *kvstore) recoverFromSnapshot(snapshot []byte) error {
	var store map[string]string
	if err := json.Unmarshal(snapshot, &store); err != nil {
		return err
	}
	s.mu.Lock()
	s.kvStore = store
	s.mu.Unlock()
	return nil
} // /etcd/raftexample/kvstore.go
```

其二，当`leader`节点同步快照数据给`follower`节点时，协议库会将快照数据应用到`unstable`（如果合法的话），然后，将`Ready`实例返回给应用程序，应用程序会检测到`Ready`结构中包含快照数据，因此，会将快照数据应用到`Storage`中。其相关代码如下（实际完整调用为：`startRaft() -> serveChannels()`）：

```go
func (rc *raftNode) serveChannels() {
    // 节点刚启动时，通过加载 snap 快照 && 重放 WAL 日志，以将其应用到 memoryStorage 中
    // 因此可以从 memoryStorage 中取出相关数据
	snap, err := rc.raftStorage.Snapshot()
	rc.confState = snap.Metadata.ConfState
	rc.snapshotIndex = snap.Metadata.Index
	rc.appliedIndex = snap.Metadata.Index
	// ...
	go func() {
	// ...
	// 应用程序状态机更新的事件循环，即循环等待底层协议库的 Ready 通知
	for {
		select {
		case <-ticker.C:
			rc.node.Tick()
		// 1. 收到底层协议库的 Ready 通知，关于 Ready 的结构已经在介绍 raftexample 文章中简要介绍
		case rd := <-rc.node.Ready():
			// 2. 先将 Ready 中需要被持久化的数据保存到 WAL 日志文件（在消息转发前）
			rc.wal.Save(rd.HardState, rd.Entries)
			// 3. 如果 Ready 中的需要被持久化的快照不为空
			// 此部分快照数据的来源是 leader 节点通过 MsgSnap 消息同步给 follower 节点
			if !raft.IsEmptySnap(rd.Snapshot) {
				// 3.1 保存快照到 WAL 日志（快照的索引/元数据信息）以及到
				// snap 日志文件中（由应用程序来实现 snap 的数据结构，etcd-raft 的实现包含了快照的元信息及实际数据）
				// snap 日志文件会作为 状态机 (kvstore) 加载快照数据的来源（重启时加载，以及快照更新时重新加载）
				rc.saveSnap(rd.Snapshot)
				// 3.2 将快照应用到 memoryStorage 实例，替换掉其 snapshot 实例
				rc.raftStorage.ApplySnapshot(rd.Snapshot)
				// 3.3 更新应用程序保存的快照信息
				// 这包括更新 snapshotIndex、appliedIndex以及confState
				// 另外，还会通知 kvstore 重新加载 snap 文件的快照数据
				rc.publishSnapshot(rd.Snapshot)
			}
			// 4. 追加 Ready 结构中需要被持久化的信息（在消息转发前）
			rc.raftStorage.Append(rd.Entries)
			// 5. 转发 Ready 结构中的消息
			rc.transport.Send(rd.Messages)
			// 6. 将日志应用到状态机（如果存在已经提交，即准备应用的日志项）
			// 会更新 appliedIndex
			if ok := rc.publishEntries(rc.entriesToApply(rd.CommittedEntries)); !ok {
				rc.stop()
				return
			}
			// 7. 触发快照操作（如果满足条件）
			rc.maybeTriggerSnapshot()
			// 8. 通知底层 raft 协议库实例 node，即告知当前 Ready 已经处理完毕，可以准备下一个
			rc.node.Advance()
		// ...
		}
	}
} // /etcd/contrib/raftexample/raft.go
```

### follower 节点何时以及如何应用 snapshot 数据

 最后，我们来简单了解`follower`节点收到`leader`节点的`MsgSnap`消息时，如何应用`snapshot`数据。其大致的逻辑为：当`follower`节点收到`MsgSnap`消息时，会判断此快照是否合法，若合法，则将共应用到`unstable`，并且更新相关的记录索引（如`offset`等），返回快照应用成功的消息。否则，返回快照已应用的消息（事实上回复消息没有明显区分应用失败还是成功，实际上是以`lastIndex`及`commited`来区分，这足以使得`leader`节点获悉`follower`节点日志进度）。同时`follower`节点还会更新集群的拓扑结构信息。再提醒一次，其最后调用的`send()`函数使得节点的上层应用程序将`snapshot`应用到`Storage`，并且作`WAL`日志以及`snap`快照。其相关代码为（实际完整调用为：`stepFollower() -> handleSnapshot() -> restore()`）：

```go
func (r *raft) handleSnapshot(m pb.Message) {
	sindex, sterm := m.Snapshot.Metadata.Index, m.Snapshot.Metadata.Term
	// 1. 若应用成功，则发送当前 raftLog 中（包括 unstable 及 Storage）的最后一项日志（之前的日志已作为快照数据存储）
	if r.restore(m.Snapshot) {
		r.logger.Infof("%x [commit: %d] restored snapshot [index: %d, term: %d]",
			r.id, r.raftLog.committed, sindex, sterm)
		// 1.1 此 send 函数会将消息最终放入 Ready 结构中，node 会将 Ready 实例进行打包，以发送给节点上层应用程序
		// 上层应用程序收到 Ready 通知后，检查到此消息中包含 snapshot 数据，则应用到 Storage，并作 WAL日志以及 snap 快照记录
		r.send(pb.Message{To: m.From, Type: pb.MsgAppResp, Index: r.raftLog.lastIndex()})
	} else {
		// 1.2 否则说明此快照数据已应用，则发送目前已提交的日志项的索引给 leader
		r.logger.Infof("%x [commit: %d] ignored snapshot [index: %d, term: %d]",
			r.id, r.raftLog.committed, sindex, sterm)
		r.send(pb.Message{To: m.From, Type: pb.MsgAppResp, Index: r.raftLog.committed})
	}
} // /etcd/raft/raft.go
```

```go
func (r *raft) restore(s pb.Snapshot) bool {
	// 1. 若快照消息中的快照索引小于已提交的日志项的日志索引，则不能应用此快照（之前已应用）
	if s.Metadata.Index <= r.raftLog.committed {
		return false
	}
	// 2. 否则，若此索引与任期匹配
	if r.raftLog.matchTerm(s.Metadata.Index, s.Metadata.Term) {
		r.logger.Infof("%x [commit: %d, lastindex: %d, lastterm: %d] fast-forwarded commit to snapshot [index: %d, term: %d]",
			r.id, r.raftLog.committed, r.raftLog.lastIndex(), r.raftLog.lastTerm(), s.Metadata.Index, s.Metadata.Term)
		// 2.1 则更新 raftLog 中的 commited 字段，因为 committed 之前的日志代表已经提交
		r.raftLog.commitTo(s.Metadata.Index)
		return false
	}

	// The normal peer can't become learner.
	// 3. 这里是更新当前节点的集群的拓扑结构信息，即集群中包含哪些节点，它们各自的角色是什么
	if !r.isLearner {
		for _, id := range s.Metadata.ConfState.Learners {
			if id == r.id {
				r.logger.Errorf("%x can't become learner when restores snapshot [index: %d, term: %d]", r.id, s.Metadata.Index, s.Metadata.Term)
				return false
			}
		}
	}

	r.logger.Infof("%x [commit: %d, lastindex: %d, lastterm: %d] starts to restore snapshot [index: %d, term: %d]",
		r.id, r.raftLog.committed, r.raftLog.lastIndex(), r.raftLog.lastTerm(), s.Metadata.Index, s.Metadata.Term)
 	// 4. 更新 raftLog 的 commited 为快照消息中的索引，以及更换 unstable 中的 snapshot 实例为快照消息中的快照实例
 	// 并更新 unstable 的 offset 为 快照消息索引+1，更新 ents 字段为空
	r.raftLog.restore(s)
	// 5. 以下同样是重构节点的拓扑信息
	r.prs = make(map[uint64]*Progress)
	r.learnerPrs = make(map[uint64]*Progress)
	r.restoreNode(s.Metadata.ConfState.Nodes, false)
	r.restoreNode(s.Metadata.ConfState.Learners, true)
	return true
} // /etcd/raft/raft.go
```

至此，关于`snapshot`的逻辑已经阐述完毕。

简单小结，本文先是简单介绍了`Snapshot`的数据结构及接口实现（该`Snapshot`为重启的快照数据加载来源，并配合`WAL`日志重放记录，以重构节点宕机前的状态），然后围绕`unstable`及`Storage`总结了关于`snapshot`的流程逻辑，以在总体上把握`snapshot`的核心设计流程。最后，结合代码分析从四个方面梳理`snapshot`的相关流程，目的是加深读者对整个系统中如何使用`snapshot`的印象，并且需要理解为何如此设计。



参考文献

[1]. https://github.com/etcd-io/etcd
[2]. [etcd-raft snapshot实现分析](https://zhuanlan.zhihu.com/p/29865583)



