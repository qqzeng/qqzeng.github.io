---
title: etcd-raft 存储模块源码简析
date: 2019-01-12 12:27:54
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 分布式协调服务
---

上一篇文章简单分析了`etcd-raft WAL`日志管理模块相关的源码。文章集中在`WAL`库提供的相关接口的阐述，而未将其与`raft`协议核心库关联起来，即尚未阐述`raft`协议核心库如何使用`WAL`日志库，并且上一篇文章虽然是以应用程序使用`WAL`库为切入点分析，但并没有阐述清楚`WAL`、`Storage`以及`unstable`三者的关联，鉴于三者提供日志存储的功能。本文的重点是分析`etcd-raft` 存储模块，它包括`Storage`及其实现`memoryStorage`（`etcd`为应用程序提供的一个`Storage`实现的范例）、`unstable`以及`raftLog`三个核心数据结构。另外，阐述`Storage`同应用程序的交互的细节以及`raft`协议库与`raftLog`的交互相关的逻辑，后者包括`raftLog`重要接口的实现，以及`raft`协议库的一个典型的简单的日志追加流程（即从`leader`追加日志，然后广播给`follower`节点，然后`follower`节点同样进行日志项的追加，最后`leader`节点处理`follower`节点的响应各个环节中日志追加的具体逻辑）。

<!--More-->

（**需要提醒的是，整篇文章较长，因此读者可以选择部分小节进行针对性参考，每个小节的最开始都有概括该小节的内容，各小节的分析是独立进行的**。）同样我们先重点了解几个数据结构，主要包括`raftLog`、`unstable`以及`Storage & MemoryStorage`，读者可以深入源码文件仔细查看相关字段及逻辑（主要涉及的目录`/etcd/raft/`，也有示例应用的部分代码`/etcd/contrib/raftexample`）。通过了解相关数据结构，就能大概推测出其相关功能。

## 数据结构

### raftLog

`raftLog`为`raft`协议核心处理日志复制提供接口，`raft`协议库对日志的操作都基于`raftLog`实施。换言之，协议核心库不会直接同`Storage`及`WAL`直接交互。`raftLog`的数据结构如下：

```go
type raftLog struct {
	// 包含从上一次快照以来的所有已被持久化的日志项集合
	storage Storage
	// 包含所有未被持久化（一旦宕机便丢失）的日志项集合及快照
	// 它们会被持久化到 storage
	unstable unstable
	// 已被持久化的最高的日志项的索引编号
	committed uint64
	// 已经被应用程序应用到状态机的最高手日志项索引编号
	// 必须保证： applied <= committed
	applied uint64
	logger Logger
	// 调用 nextEnts 时，返回的日志项集合的最大的大小
	// nextEnts 函数返回应用程序已经可以应用到状态机的日志项集合
	maxNextEntsSize uint64
} // log.go
```

关于`storage`及`unstable`两个数据我们暂时不知道其具体作用，比如它们是如何被`raftLog`使用的，它们的区别是什么？我们先继续了解这两个数据结构的内容。

### unstable

`unstable`顾名思义，表示非持久化的存储。其数据结构如下：

```go
// unstable.entries[i] 存储的日志的索引为 i+unstable.offset
// 另外，unstable.offset 可能会小于 storage.entries 中的最大的索引
// 此时，当继续向 storage 同步日志时，需要先截断其大于 unstable.offset 的部分
type unstable struct {
	// the incoming unstable snapshot, if any.
	// unstable 包含的快照数据
	snapshot *pb.Snapshot
	// 所有未被写入 storage 的日志
	entries []pb.Entry
	// entries 日志集合中起始的日志项编号
	offset  uint64

	logger Logger
} // log_unstable.go
```

### Storage & MemoryStorage

`Storage`表示`etcd-raft`提供的持久化存储的接口。应用程序负责实现此接口，以将日志信息落盘。并且，若在操作过程此持久化存储时出现错误，则应用程序应该停止对相应的 raft 实例的操作，并需要执行清理或恢复的操作。其数据结构如下：

```go
// Storage 接口需由应用程序来实现，以从存储中以出日志信息
// 如果在操作过程中出现错误，则应用程序应该停止对相应的 raft 实例的操作，并需要执行清理或恢复的操作
type Storage interface {
	// 返回 HardState 及 ConfState 数据
	InitialState() (pb.HardState, pb.ConfState, error)
	// 返回 [lo, hi) 范围的日志项集合
	Entries(lo, hi, maxSize uint64) ([]pb.Entry, error)
	// 返回指定日志项索引的 term
	Term(i uint64) (uint64, error)
	// 返回日志项中最后一条日志的索引编号
	LastIndex() (uint64, error)
	// 返回日志项中最后第一条日志的索引编号，注意在其被创建时，日志项集合会被填充一项 dummy entry
	FirstIndex() (uint64, error)
	// 返回最近一次的快照数据，如果快照不可用，则返回出错
	Snapshot() (pb.Snapshot, error)
} // storage.go

// MemoryStorage 实现了 Storage 接口，注意 MemoryStorage 也是基于内存的
type MemoryStorage struct {
	sync.Mutex
	hardState pb.HardState
	snapshot  pb.Snapshot
	// ents[i] 存储的日志项的编号为 i+snapshot.Metadata.Index，即要把快照考虑在内
	ents []pb.Entry
} // storage.go
```

## 关键流程



从上述数据结构中发现`raftLog`封装了`storage`及`unstable`。而且大概看一下`raftLog`中各个接口，发现主要不是同`unstable`进行交互（也有利用`storage`的数据）。所以，我们决定从两个方面来明晰主几个数据结构的作用。包括应用程序与`Storage`交互，以及`raft`协议核心同`raftLog(unstable/storage)`交互。希望通过从具体功能实现切入来摸索梳理相关逻辑，并结合数据结构，以达到由外至里尽可能把握其设计原理的效果。

### 应用程序与  Storage 交互

为了让读者有更好的理解，本文仍旧从`raftexample`中的`startRaft()`开始追溯与上述三个数据结构相关的逻辑，以明晰它们三者的作用。我们从两个方面来阐述交互的大致逻辑，包括应用程序启动（此时`raft`实例也会被初始化）以及上层应用收到底层`raft`协议核心的通知(`Ready`)时所执行的相关操作。

#### 应用初始化

首先来看第一个：在`startRaft()`函数中，我们先深入日志重放代码`rc.wal = rc.replayWAL()`：

```go
// 重放 WAL 日志到 raft 实例
func (rc *raftNode) replayWAL() *wal.WAL {
	log.Printf("replaying WAL of member %d", rc.id)
	// 1. 从持久化存储中加载 快照数据
	snapshot := rc.loadSnapshot()
	// 2. 从指定日志索引位置打开 WAL 日志，以准备读取日志
	w := rc.openWAL(snapshot)
	// 3. 读取指定索引位置后的所有日志
	_, st, ents, err := w.ReadAll()
	if err != nil {
		log.Fatalf("raftexample: failed to read WAL (%v)", err)
	}
	// 4. 应用程序创建一个 MemoryStorage 实例
	rc.raftStorage = raft.NewMemoryStorage()
	// 5. 若快照数据不为空，则将快照数据应用到 memoryStorage 中
	if snapshot != nil {
		rc.raftStorage.ApplySnapshot(*snapshot)
	}
	// 6. 设置 HardState 到 memoryStorage 实例
	rc.raftStorage.SetHardState(st)
	// append to storage so raft starts at the right place in log
	// 7. 将日志项追加到 memoryStorage 实例，注意，此日志项不包含已经快照的日志项
	rc.raftStorage.Append(ents)
	// send nil once lastIndex is published so client knows commit channel is current
	if len(ents) > 0 {
		// 8. 如果在快照后，仍存在日志项记录，则设置 lastIndex
		rc.lastIndex = ents[len(ents)-1].Index
	} else {
		// 9. 通知 kvstore，日志重放已经完毕
		rc.commitC <- nil
	}
	return w
} // raft.go
```

我们重点关注与`memoryStorage`相关的逻辑。步骤 4 创建了一个`memoryStorage`实例，创建逻辑也比较简单：

```go
// NewMemoryStorage creates an empty MemoryStorage.
func NewMemoryStorage() *MemoryStorage {
	return &MemoryStorage{
		// When starting from scratch populate the list with a dummy entry at term zero.
		ents: make([]pb.Entry, 1),
	}
} // storage.go
```

而步骤 5 将快照数据应用到了`memoryStorage`实例，其逻辑也较为简单：

```go
// ApplySnapshot overwrites the contents of this Storage object with
// those of the given snapshot.
func (ms *MemoryStorage) ApplySnapshot(snap pb.Snapshot) error {
	ms.Lock()
	defer ms.Unlock()

	//handle check for old snapshot being applied
	msIndex := ms.snapshot.Metadata.Index
	snapIndex := snap.Metadata.Index
	if msIndex >= snapIndex {
		return ErrSnapOutOfDate
	}
	ms.snapshot = snap
	ms.ents = []pb.Entry{{Term: snap.Metadata.Term, Index: snap.Metadata.Index}}
	return nil
} // storage.go
```

从代码可以看出，其只是将快照直接进行替换，并将快照的当前索引及任期存入日志项集合。而步骤 6 较为简单，在此略过。简单了解一下步骤 7，它往`memoryStorage`的日志项集合中追加日志项集合，其代码如下：

```go
// 新追加的日志项必须是连续的，且 entries[0].Index > ms.entries[0].Index
func (ms *MemoryStorage) Append(entries []pb.Entry) error {
	if len(entries) == 0 {
		return nil
	}
	ms.Lock()
	defer ms.Unlock()
	first := ms.firstIndex()
	last := entries[0].Index + uint64(len(entries)) - 1

	// shortcut if there is no new entry.
	if last < first {
		return nil
	}
	// truncate compacted entries
	// 若已有的 ms.ents 被 compact 了，则新追加的日志项集有可能为被 compact 掉中的一部分
	// 因此，需要将那一部进行移除，以免重复追加
	if first > entries[0].Index {
		entries = entries[first-entries[0].Index:]
	}
	// 判断新追加日志与已有日志是否有重叠，若是，则需要覆盖已有日志，否则直接追加到已有日志后面
	offset := entries[0].Index - ms.ents[0].Index
	switch {
	case uint64(len(ms.ents)) > offset:
		ms.ents = append([]pb.Entry{}, ms.ents[:offset]...)
		ms.ents = append(ms.ents, entries...)
	case uint64(len(ms.ents)) == offset:
		ms.ents = append(ms.ents, entries...)
	default:
		raftLogger.Panicf("missing log entry [last: %d, append at: %d]",
			ms.lastIndex(), entries[0].Index)
	}
	return nil
} // storage.go
```

日志追加流程基本符合逻辑，但需要注意如果已有日志项集合被`compact`，且追加的日志与已有日志重叠的情况。关于日志项被`compact`的相关逻辑，后面会叙述。现在作一个小结，上述逻辑发生在应用启动初始化时机，换言之，这包括两种情况，其一是整个集群刚启动，应用程序所在的节点没有任何持久化的快照记录；其二是此节点宕机，并且错过了部分日志的追加与快照操作，因此，应用程序需要恢复此节点对应的`raft`实例的`memoryStorge`信息以及增加快照数据（节点新加入时，也大致符合这种情况）。换言之，在有节点落后、刚重启、新加入的情况下，给这些节点的数据多数来自已落盘部分（持久化的快照及`WAL`日志）。

#### 处理 raft 协议库 Ready 消息

接下来，继续了解第二处交互逻辑：在`serverChannels()`函数中，应用等待接收底层`raft`协议库的通知：

```go
	// 应用程序状态机更新的事件循环，即循环等待底层协议库的 Ready 通知
	for {
		select {
		case <-ticker.C:
			rc.node.Tick()

		// store raft entries to wal, then publish over commit channel
		// 1. 收到底层协议库的 Ready 通知，关于 Ready 结构已经在介绍 raftexample 文章中简要介绍
		case rd := <-rc.node.Ready():
			// 2. 先将 Ready 中需要被持久化的数据保存到 WAL 日志文件（在消息转发前）
			rc.wal.Save(rd.HardState, rd.Entries)
			// 3. 如果 Ready 中的需要被持久化的快照不为空
			if !raft.IsEmptySnap(rd.Snapshot) {
                // 3.1 保存快照到 WAL 日志（快照索引/元数据信息）以及到 snap (后面文章会介绍)中
				rc.saveSnap(rd.Snapshot)
				// 3.2 将快照应用到 memoryStorage 实例
				rc.raftStorage.ApplySnapshot(rd.Snapshot)
				// 3.3 更新应用程序保存的快照信息
				rc.publishSnapshot(rd.Snapshot)
			}
			// 4. 追加 Ready 结构中需要被持久化的信息（在消息转发前）
			rc.raftStorage.Append(rd.Entries)
			// 5. 转发 Ready 结构中的消息
			rc.transport.Send(rd.Messages)
			// 6. 将日志应用到状态机（如果存在已经提交，即准备应用的日志项）
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
	} // raft.go
```

同样，重点关注与`memoryStorage`相关的逻辑（其余的逻辑在【[etcd raftexample 源码简析](https://qqzeng.top/2019/01/09/etcd-raftexample-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)】中已阐述）。在步骤 3 中，当`Ready`结构中的快照不为空时，需要保存快照至一系列地方。其中步骤 3.1 的调用代码如下：

```go
func (rc *raftNode) saveSnap(snap raftpb.Snapshot) error {
	// must save the snapshot index to the WAL before saving the
	// snapshot to maintain the invariant that we only Open the
	// wal at previously-saved snapshot indexes.
	walSnap := walpb.Snapshot{ // 1. 构建快照索引（在【WAL 日志管理源码解析】文章有阐述）信息
		Index: snap.Metadata.Index,
		Term:  snap.Metadata.Term,
	}
    // 2. 保存快照索引信息到 WAL 日志
	if err := rc.wal.SaveSnapshot(walSnap); err != nil {
		return err
	} // 3. 保存快照完整数据到 snap（后面文章阐述）
	if err := rc.snapshotter.SaveSnap(snap); err != nil {
		return err
	} // 4. 更新 WAL 日志文件锁范围
	return rc.wal.ReleaseLockTo(snap.Metadata.Index)
} // raft.go
```

而步骤  3.2 在上文已阐述过，即将快照替换到`memoryStorage`关联的快照实例。而最后 3.3 的相关代码如下：

```go
// 更新应用程序保存的快照位置信息，并且通知上层应用(kvstore)可以重新加载快照
func (rc *raftNode) publishSnapshot(snapshotToSave raftpb.Snapshot) {
	if raft.IsEmptySnap(snapshotToSave) {
		return
	}
	log.Printf("publishing snapshot at index %d", rc.snapshotIndex)
	defer log.Printf("finished publishing snapshot at index %d", rc.snapshotIndex)
	// 1. 检验快照数据
	if snapshotToSave.Metadata.Index <= rc.appliedIndex {
		log.Fatalf("snapshot index [%d] should > progress.appliedIndex [%d]", snapshotToSave.Metadata.Index, rc.appliedIndex)
	} // 2. 通知上层应用(kvstore)可以重新加载快照
	rc.commitC <- nil // trigger kvstore to load snapshot
	// 3. 更新应用程序(raftNode)保存的快照位置信息，以及当前已应用到状态机的日志的索引信息
	rc.confState = snapshotToSave.Metadata.ConfState
	rc.snapshotIndex = snapshotToSave.Metadata.Index
	rc.appliedIndex = snapshotToSave.Metadata.Index
} // raft.go
```

小结步骤 3 逻辑（包括 3.1-3.3）：若底层协议传来的`Ready`结构中包含的快照不为空，则首先将快照保存到`WAL`日志（索引信息），并保存完整快照信息到`snap`，然后将快照替换掉内存(`memoryStorage`)关联的快照实例，最后更新应用保存的快照位置信息及当前已应用日志位置信息，并触发应用（状态机）重新加载快照。

同样，步骤 4 已在上文阐述过。

```go
// 针对 memoryStorage 触发快照操作（如果满足条件）
//（注意这是对 memoryStorage 中保存的日志信息作快照）
func (rc *raftNode) maybeTriggerSnapshot() {
	if rc.appliedIndex-rc.snapshotIndex <= rc.snapCount {
		return
	}

	log.Printf("start snapshot [applied index: %d | last snapshot index: %d]", rc.appliedIndex, rc.snapshotIndex)
	// 1. 加载状态机中当前的信息（此方法由应用程序提供，在 kvstore 中）
	data, err := rc.getSnapshot()
	if err != nil {
		log.Panic(err)
	}
	// 2. 利用上述快照数据、以及 appliedIndex 等为 memoryStorage 实例创建快照（它会覆盖/更新 memoryStorage 已有的快照信息）
	snap, err := rc.raftStorage.CreateSnapshot(rc.appliedIndex, &rc.confState, data)
	if err != nil {
		panic(err)
	}
	// 3. 保存快照到 WAL 日志（快照的索引/元数据信息）以及到 snap（后面文章会介绍）中
	if err := rc.saveSnap(snap); err != nil {
		panic(err)
	}

// 4. 若满足日志被 compact 的条件（防止内存中日志项过多），则对内存中日志项集合作 compact 操作
	// compact 操作会丢弃 memoryStorage 日志项中 compactIndex 之前的日志
	compactIndex := uint64(1)
	if rc.appliedIndex > snapshotCatchUpEntriesN {
		compactIndex = rc.appliedIndex - snapshotCatchUpEntriesN
	}
	if err := rc.raftStorage.Compact(compactIndex); err != nil {
		panic(err)
	}
	log.Printf("compacted log at index %d", compactIndex)
	// 5. 更新应用程序的快照位置信息
	rc.snapshotIndex = rc.appliedIndex
} // raft.go
```

上述代码逻辑比较简单，简单而言，它会从状态机中加载快照，然后覆盖`raft`实例关联的`memoryStorage`中的快照实例，而且，还会保存快照信息（上文已阐述），最后检查`memoryStorage`是否可以执行`compact`操作。其中`memoryStorage`的`compact`操作的逻辑也比较简单，即丢弃`compactIndex`之前的日志（注意：并不是丢弃 `appliedIndex`之前的日志，也不是丢弃`snapshotIndex`之前的日志）：

```go
// compact 操作会丢弃 compactIndex 之前的日志，
// 应用程序应该检查 compactIndex 应该在 appliedIndex 之前，因为，只允许 compact 掉已经 apply
func (ms *MemoryStorage) Compact(compactIndex uint64) error {
	ms.Lock()
	defer ms.Unlock()
	offset := ms.ents[0].Index
	if compactIndex <= offset {
		return ErrCompacted
	}
	if compactIndex > ms.lastIndex() {
		raftLogger.Panicf("compact %d is out of bound lastindex(%d)", compactIndex, ms.lastIndex())
	}
	i := compactIndex - offset
	ents := make([]pb.Entry, 1, 1+uint64(len(ms.ents))-i)
	ents[0].Index = ms.ents[i].Index
	ents[0].Term = ms.ents[i].Term
	ents = append(ents, ms.ents[i+1:]...)
	ms.ents = ents
	return nil
} // storage.go
```

至此，关于应用程序与`memoryStorage/Storage`的简单交互过程已经阐述完毕。作个简单小结：通过上述的分析，我们仔细关联各个流程，可以发现`WAL`中的日志项是已落盘的，而`Storage`则是`etcd-raft`提供的被应用程序访问已落盘数据的接口，`memoryStorage`实现了这个接口(`Storage`)（而且，从它的各个操作逻辑来看，它只是简单地将`WAL`已落盘的数据进行了拷贝，当然还有一个`compact`过程，如果满足条件的话），个人感觉似乎有一点多余（从网上查找资料发现，一般而言，`Storage`的实现应该是`WAL`与`cache`算法的组合，那显然，在这里的`memoryStorage`并没有实现某种`cache`算法）。另外值得注意的是，在`etcd-raft`的实现中，协议核心并不与`memoryStorage`直接交互，都是应用程序与`memoryStorage`交互。

### raft 协议库与  raftLog  交互

这部分内容包括两个部分：其一是先继续了解`raftLog`内部一些重要接口的实现，以更进一步理解直接与`raft`协议库交互的`raftLog`的实现原理。其二挑选一个简单的`raft`协议库的逻辑——日志追加操作以查看协议库使用`raftLog`的细节。

#### raftLog 接口实现逻辑

首先了解`raftLog`相关接口的实现细则。在上文已经初步了解过`raftLog`的数据结构。其构造函数如下：

```go
func newLog(storage Storage, logger Logger) *raftLog {
	return newLogWithSize(storage, logger, noLimit)
}
// newLogWithSize returns a log using the given storage and max
// message size.
func newLogWithSize(storage Storage, logger Logger, maxNextEntsSize uint64) *raftLog {
	if storage == nil { // storage 不能为空！
		log.Panic("storage must not be nil")
	}
	// 利用应用传入的 storage 及 logger 以及 maxNextEntsSize（如果有的话）构建 raftLog 实例
	log := &raftLog{
		storage:         storage,
		logger:          logger,
		maxNextEntsSize: maxNextEntsSize,
	}
	firstIndex, err := storage.FirstIndex()
	lastIndex, err := storage.LastIndex()
	// 将 unstable 的 offset 初始化为 storage 的 lastIndex+1
	log.unstable.offset = lastIndex + 1
	log.unstable.logger = logger
	// Initialize our committed and applied pointers to the time of the last compaction.
	// 将 raftLog 的 commited 及 applied 初始化为 firstIndex-1，即 storage 中第一项日志的索引号，
	// 因为第一项日志为已经被提交的（也是已经被快照的），可以仔细察看 storage 的 ApplySnapshot 逻辑
	log.committed = firstIndex - 1
	log.applied = firstIndex - 1
	return log
} // log.go
```

此构造函数在初始化`raft`结构时会被调用（具体可以查看代码）。从上述构造函数逻辑来看，`unstable`似乎是从`storage`最后一条日志后开始存储，换言之，从`raft`协议库的角度，`unstable`存储更新的日志。。我们可以从下面的几个函数来进一步证实这一点：

```go
func (l *raftLog) snapshot() (pb.Snapshot, error) {
	if l.unstable.snapshot != nil {
		return *l.unstable.snapshot, nil
	}
	return l.storage.Snapshot()
} // log.go

func (l *raftLog) firstIndex() uint64 {
	if i, ok := l.unstable.maybeFirstIndex(); ok {
		return i
	}
	index, err := l.storage.FirstIndex()
	return index
} // log.go

func (l *raftLog) lastIndex() uint64 {
	if i, ok := l.unstable.maybeLastIndex(); ok {
		return i
	}
	i, err := l.storage.LastIndex()
	return i
} // log.go
```

当`raftLog`都是先将`unstable`关联的数据返回给`raft`核心库。我们后面会来仔细了解这些函数如何被调用。我们继续了解两个较为重要的接口：

```go
// 日志追加，返回(0, false)若日志项不能被追加，否则返回 (最后一条日志索引, true)
func (l *raftLog) maybeAppend(index, logTerm, committed uint64, ents ...pb.Entry) (lastnewi uint64, ok bool) {
	if l.matchTerm(index, logTerm) { // 1. 检验 index 与 term 是否匹配
		lastnewi = index + uint64(len(ents)) // 2. 最后一条日志索引
		ci := l.findConflict(ents) // 3. 检查此次追加的日志项是否与已有的存在冲突（论文中有详述冲突情况）
		switch {
		case ci == 0: // 3.1 没有冲突，则直接提交（如果可以提交的话）
		case ci <= l.committed: // 3.2 冲突的索引不能比已经提交的索引还要小！
			l.logger.Panicf("entry %d conflict with committed entry [committed(%d)]", ci, l.committed)
		default: // 3.3 否则，与已有日志（未提交的）有冲突
            //（也有可能没有冲突，详情在 findConflict 函数中说明），并追加日志，最后提交
			offset := index + 1
			l.append(ents[ci-offset:]...)
		}
		l.commitTo(min(committed, lastnewi))
		return lastnewi, true
	}
	return 0, false
} // log.go

// 即检查追加的日志项集合与已有的日志项（包括已提交与未提交）是否存在冲突，返回第一次冲突的日志索引（如果有的话）
// 另外，需要注意的是，要追加的日志必须要连续
// 如果没有冲突，并且已有的日志包含了要追加的所有日志项，则返回 0
// 如果没有冲突，并且要追加的日志包含有新日志项，则返回第一次新的日志项
// 日志项冲突判定的条件是: 相同的 index 不同的 term
func (l *raftLog) findConflict(ents []pb.Entry) uint64 {
	for _, ne := range ents {
		if !l.matchTerm(ne.Index, ne.Term) {
			if ne.Index <= l.lastIndex() {
				l.logger.Infof("found conflict at index %d [existing term: %d, conflicting term: %d]",
					ne.Index, l.zeroTermOnErrCompacted(l.term(ne.Index)), ne.Term)
			}
			return ne.Index
		}
	}
	return 0
}
```

#### raft 协议库追加日志

接下来，我们把重点放在`/etcd/raft.log`文件中，并梳理日志追加的整体逻辑（关于文件中的数据结构以及一些细节我们暂且忽略，重点关注其逻辑流程）。为了让读者更容易理解整个过程的来龙去脉，我们仍然从应用程序提交日志开始切入，以将整个流程梳理一遍（同时，下文所展示的代码大部分只包含关键的逻辑）。下面的逻辑分析会大致依据实际逻辑顺利展开，即从应用程序提交日志开始，到`leader`节点在本地追加日志（若是`follower`节点收到请求消息，则一般是转发给`leader`节点），然后到`leader`节点广播日志给`follower`节点，最后到`follower`节点的日志追加，以及`leader`如何处理`follower`节点日志追加的响应消息。

##### leader 节点追加日志

我们从应用程序向`raft`协议库提交日志请求开始，当然，在应用启动初始化时，其实也涉及到`raft`协议库的初始化启动，如下代码所示：

```go
func (rc *raftNode) startRaft() {
	// ...
	rpeers := make([]raft.Peer, len(rc.peers))
	for i := range rpeers {
		rpeers[i] = raft.Peer{ID: uint64(i + 1)}
	}
	c := &raft.Config{
		ID:                        uint64(rc.id),
		ElectionTick:              10,
		HeartbeatTick:             1,
		Storage:                   rc.raftStorage,
		MaxSizePerMsg:             1024 * 1024,
		MaxInflightMsgs:           256,
		MaxUncommittedEntriesSize: 1 << 30,
	}
	if oldwal {
		rc.node = raft.RestartNode(c)
	} else {
		startPeers := rpeers
		if rc.join {
			startPeers = nil
		}
        // 启动底层 raft 协议核心库，并将 Config 及集群中节点信息传入
		rc.node = raft.StartNode(c, startPeers)
	}
	// ...
	go rc.serveRaft()
	go rc.serveChannels()
} // /etcd/contrib/raftexample/raft.go
```

在`raft.StartNode()`函数中，创建`node`，它表示底层`raft`协议的实例，构建了`raft`实例（封装协议实现的核心逻辑），并且调用了`n.run()`以等待上层应用程序向`node`提交请求，关键代码如下：

```go
func StartNode(c *Config, peers []Peer) Node {
	r := newRaft(c)
	// ...
	n := newNode()
	// ...
	go n.run(r)
	return &n
} // node.go


func (n *node) run(r *raft) {
	// ...
	for {
		if advancec != nil {
			readyc = nil
		} else {
			rd = newReady(r, prevSoftSt, prevHardSt)
			if rd.containsUpdates() {
				readyc = n.readyc
			} else {
				readyc = nil
			}
		}
		// ...
		select {
		case pm := <-propc:
			m := pm.m
			m.From = r.id
			err := r.Step(m) // 调用 Step 函数来进行处理
			if pm.result != nil {
				pm.result <- err
				close(pm.result)
			}
        case m := <-n.recvc: // 此处的逻辑会在 follower 节点接收 leader 节点广播的消息时调用
            // 具体地，会在下文的 【follower 节点追加日志】 小节涉及到
			// filter out response message from unknown From.
			if pr := r.getProgress(m.From); pr != nil || !IsResponseMsg(m.Type) {
				r.Step(m)
			}
		// ...
		case readyc <- rd:
			if rd.SoftState != nil {
				prevSoftSt = rd.SoftState
			}
			if len(rd.Entries) > 0 {
				prevLastUnstablei = rd.Entries[len(rd.Entries)-1].Index
				prevLastUnstablet = rd.Entries[len(rd.Entries)-1].Term
				havePrevLastUnstablei = true
			}
			if !IsEmptyHardState(rd.HardState) {
				prevHardSt = rd.HardState
			}
			if !IsEmptySnap(rd.Snapshot) {
				prevSnapi = rd.Snapshot.Metadata.Index
			}
			if index := rd.appliedCursor(); index != 0 {
				applyingToI = index
			}

			r.msgs = nil
			r.readStates = nil
			r.reduceUncommittedSize(rd.CommittedEntries)
			advancec = n.advancec
		case <-advancec:
		// ...
		// ...
		}
	}
} // node.go

func newReady(r *raft, prevSoftSt *SoftState, prevHardSt pb.HardState) Ready {
	rd := Ready{
		Entries:          r.raftLog.unstableEntries(),
		CommittedEntries: r.raftLog.nextEnts(),
		Messages:         r.msgs, // Step 函数将消息进行广播实际上会发送到此 msg 结构中
	}
	if softSt := r.softState(); !softSt.equal(prevSoftSt) {
		rd.SoftState = softSt
	}
	if hardSt := r.hardState(); !isHardStateEqual(hardSt, prevHardSt) {
		rd.HardState = hardSt
	}
	if r.raftLog.unstable.snapshot != nil {
		rd.Snapshot = *r.raftLog.unstable.snapshot
	}
	if len(r.readStates) != 0 {
		rd.ReadStates = r.readStates
	}
	rd.MustSync = MustSync(r.hardState(), prevHardSt, len(rd.Entries))
	return rd
} // node.go
```

从上面展示的三个函数，可以发现程序会开一个`go routine`通过`channel`来处理所有现应用程序（当然也有内部的一些逻辑）的交互。当`node`从`propc`管道中收到应用程序提交的请求后，它会将此请求交给`Step`函数处理，`Step`函数在经过一系列检查之后（比如检查`term`），会调用`step`函数（这里只考虑正常的`MsgProp`消息），`step`函数对于不同的角色的节点其实现不同，典型的，对于`leader`节点，其实现为`stepLeader`。另外，在循环中，程序会将打包好`Ready`结构通过`readc`的管道发送给应用程序，然后等待从`advancec`管道中接收应用程序的返回消息。下面，我们从`stepLeader`函数开始来一步步梳理`leader`的日志追加逻辑：

```go
func stepLeader(r *raft, m pb.Message) error {
	// These message types do not require any progress for m.From.
	switch m.Type {
	case pb.MsgBeat:
		// ...
		return nil
	case pb.MsgProp:
		// ...
        // 1. 追加日志
		if !r.appendEntry(m.Entries...) {
			return ErrProposalDropped
		}
        // 2. 广播日志追加
		r.bcastAppend()
		return nil
	case pb.MsgReadIndex:
		// ...
		return nil
	}
	// ...
	return nil
} // /etcd/raft/raft.go

func (r *raft) appendEntry(es ...pb.Entry) (accepted bool) {
    // ...
	// use latest "last" index after truncate/append
	li = r.raftLog.append(es...)
	r.getProgress(r.id).maybeUpdate(li)
	// Regardless of maybeCommit's return, our caller will call bcastAppend.
	r.maybeCommit()
	return true
} // /etcd/raft/raft.go

func (l *raftLog) append(ents ...pb.Entry) uint64 {
	// ...
	l.unstable.truncateAndAppend(ents)
	return l.lastIndex()
} // log.go

func (u *unstable) truncateAndAppend(ents []pb.Entry) {
	after := ents[0].Index
	switch {
	// 若需要追加的日志项集合中的第一条日志恰好是已有的日志的最后一条日志的后一条日志，则直接追加
	case after == u.offset+uint64(len(u.entries)):
		// after is the next index in the u.entries
		// directly append
		u.entries = append(u.entries, ents...)
	// 若需要追加的日志项集合中的第一条日志，要比 unstable 中的 offset 还要小
        //（即比 unstable 中日志项集合的开始日志的索引要小）
	// 则需要把重新设置 offset 索引，并且将 unstable 的日志项集合中的日志覆盖
	case after <= u.offset:
		u.logger.Infof("replace the unstable entries from index %d", after)
		// The log is being truncated to before our current offset
		// portion, so set the offset and replace the entries
		u.offset = after
		u.entries = ents
	default:
		// 否则，分段次进行日志追加
        //（包含两种情况，u.offset < after < u.offset+len(u.entries) 或者 after > u.offset+len(u.entries)）
		// 此种情况也可能涉及到 unstable 中已有日志的截断（前一种情况）
		// truncate to after and copy to u.entries
		// then append
		u.logger.Infof("truncate the unstable entries before index %d", after)
		u.entries = append([]pb.Entry{}, u.slice(u.offset, after)...)
		u.entries = append(u.entries, ents...)
	}
} // log_unstable.go
```

在`stepLeader`函数中，首先调用 了`appendEntry()`函数，它会将日志项集合追加到`raftLog`中（实际上是调用了`r.raftLog.append(es...)`追加到`unstable`日志项集合），并且提交本地的日志项（如果满足条件的话）。

##### leader 节点向 follower 节点广播日志

并且，在`stepLeader()`上会继续调用`r.bcastAppend()`函数向集群中其它节点广播日志，具体代码如下所示：

```go
func (r *raft) bcastAppend() {
	r.forEachProgress(func(id uint64, _ *Progress) {
		if id == r.id {
			return
		}
		r.sendAppend(id)
	})
} // /etcd/raft/raft.go

func (r *raft) sendAppend(to uint64) {
	r.maybeSendAppend(to, true)
} // /etcd/raft/raft.go
```

而`sendAppend()`函数又会调用`maybeSendAppend()`函数来向特定的节点发送日志同步命令。代码如下：

```go
func (r *raft) maybeSendAppend(to uint64, sendIfEmpty bool) bool {
	pr := r.getProgress(to)
	// ...
	m := pb.Message{}
	m.To = to
	term, errt := r.raftLog.term(pr.Next - 1)
	ents, erre := r.raftLog.entries(pr.Next, r.maxMsgSize)
	if len(ents) == 0 && !sendIfEmpty {
		return false
	} // sendIfEmpty 可以用作控制空消息是否可以被发送（消息过多时，肯定不建议发送）
    // 如果获取 term 或者 ents 失败，则发送 snap 消息
	if errt != nil || erre != nil { // 此处主要是构建 snap 消息的相关操作
		// ...
		m.Type = pb.MsgSnap
		snapshot, err := r.raftLog.snapshot()
		// ...
		m.Snapshot = snapshot
		sindex, sterm := snapshot.Metadata.Index, snapshot.Metadata.Term
		// ...
		pr.becomeSnapshot(sindex)
		r.logger.Debugf("%x paused sending replication messages to %x [%s]", r.id, to, pr)
	} else { // 先设置消息的相关属性
		m.Type = pb.MsgApp
		m.Index = pr.Next - 1
		m.LogTerm = term
		m.Entries = ents
		m.Commit = r.raftLog.committed
        // 此处针对节点不同的状态（定义在 progress.go 文件中），来控制一次性给节点发送的消息数量，是批量发送，还是一次只发一条，还是要先暂停探测一下
		if n := len(m.Entries); n != 0 {
			switch pr.State {
			// optimistically increase the next when in ProgressStateReplicate
			case ProgressStateReplicate:
				last := m.Entries[n-1].Index
				pr.optimisticUpdate(last)
				pr.ins.add(last)
			case ProgressStateProbe:
				pr.pause()
			default:
				r.logger.Panicf("%x is sending append in unhandled state %s", r.id, pr.State)
			}
		}
	}
    // send 函数会将消息保存到 raft.msgs 字段，最后用于构建 Ready 实例结构，以发送给应用程序，
    // 事实上，此步骤才是真正执行消息发送的步骤（raft 协议库向应用程序发送消息，然后应用程序来控制并执行具体的日志消息网络传输的操作）
	r.send(m)
	return true
} // /etcd/raft/raft.go
```

简单而言，上述函数的逻辑为：首先根据该节点上一次已同步的日志位置`pr.Next-1`，从`raftLog`中获取该位置之后的日志项，并且日志同步的数量会受到`maxMsgSize`控制。并且若果无法从`raftLog`获取到想要的日志项，此时需要只能发送`snap`（即`MsgSnap`消息），因为对应日志项可能由于已经被`commit`而丢弃了。另外，真正的发送消息的操作其实是向`r.msgs`字段中追加实际需要发送的消息，后面会由`node`将其打包入`Ready`结构中，转而发送给应用程序，由应用程序执行真正消息的网络传输操作。

至此，`leader`节点广播日志项给`follower`相关流程已经分析完毕。

##### follower 节点追加日志

在分析具体的`follower`节点追加`leader`节点给它发送的消息中的日志之前，我们把这个过程阐述得更完整一些。当应用程序调用`transport`网络传输组件将`MsgApp`类型的消息由传至`follower`节点时，更准确而言，`transport`组件的接收器在接收到消息后，会调用其`Raft`组件的`Process()`方法（此部分逻辑不再展示相关代码，在上上篇文章【[etcd-raft 网络传输源码简析](https://qqzeng.top/2019/01/10/etcd-raft-%E7%BD%91%E7%BB%9C%E4%BC%A0%E8%BE%93%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)】中包含了此部分逻辑）。而应用程序会实现此`Process()`接口，在`raftexample`示例程序中，其实现逻辑也较为简单：

```go
func (rc *raftNode) Process(ctx context.Context, m raftpb.Message) error {
	return rc.node.Step(ctx, m) // 直接调用底层协议核心结构 node 的 Step 函数来处理消息
} // /etcd/contrib/raftexample/raft.go
```

调用`Step()`函数后，类似于`leader`节点，会进入到`node`实例的`Step()`函数中，它会调用`node`的一系列函数，包括`step()`、`stepWithWaitOption()`函数，然后将消息传入`recvc`通道，然后在`node`节点的主循环函数`run()`中，会一直监视着各通道，因此会从`recvc`通道中取出消息，最后调用`raft.Step()`，接下来经过一系列的检查，会调用`step()`函数即，同样，这里是`follower`节点，因此最后会调用`stepFollower()`函数（后面这一个阶段的函数调用栈同`leader`节点接收到应用程序的请求的流程是一样的）。下面简要贴出在`recv`通道放入消息之前流程的相关代码：

```go
func (n *node) Step(ctx context.Context, m pb.Message) error {
	// ignore unexpected local messages receiving over network
	if IsLocalMsg(m.Type) {
		// TODO: return an error?
		return nil
	}
	return n.step(ctx, m)
} // node.go
func (n *node) step(ctx context.Context, m pb.Message) error {
	return n.stepWithWaitOption(ctx, m, false)
} // node.go
func (n *node) stepWait(ctx context.Context, m pb.Message) error {
	return n.stepWithWaitOption(ctx, m, true)
} // node.go
// Step advances the state machine using msgs. The ctx.Err() will be returned,
// if any.
func (n *node) stepWithWaitOption(ctx context.Context, m pb.Message, wait bool) error {
	if m.Type != pb.MsgProp {
		select {
		case n.recvc <- m:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		case <-n.done:
			return ErrStopped
		}
	}
	// ...
	return nil
} // node.go
```

下面来重点看一下`stepFolower()`函数的逻辑，具体是接收到`MsgApp`类型的消息的处理逻辑。

```go
func stepFollower(r *raft, m pb.Message) error {
	switch m.Type {
	case pb.MsgProp: // 如果应用程序将请求直接发到了 follower 节点，则可能会将消息转发给 leader
		if r.lead == None {
			r.logger.Infof("%x no leader at term %d; dropping proposal", r.id, r.Term)
			return ErrProposalDropped
		} else if r.disableProposalForwarding {
			r.logger.Infof("%x not forwarding to leader %x at term %d; dropping proposal", r.id, r.lead, r.Term)
			return ErrProposalDropped
		}
		m.To = r.lead
		r.send(m) // 转发给 leader
	case pb.MsgApp: // 接收到 leader 发送的日志同步消息
		r.electionElapsed = 0
		r.lead = m.From
		r.handleAppendEntries(m) // 追加日志操作
	case pb.MsgHeartbeat:
		r.electionElapsed = 0
		r.lead = m.From
		r.handleHeartbeat(m)
	case pb.MsgSnap:// 接收到 leader 发送的 snap 同步消息
		r.electionElapsed = 0
		r.lead = m.From
		r.handleSnapshot(m) // 处理快照同步的操作
	case pb.MsgTransferLeader:
		// ...
	case pb.MsgTimeoutNow:
		// ...
	case pb.MsgReadIndex:
		// ...
	case pb.MsgReadIndexResp:
		// ..
	}
	return nil
} // /etcd/raft/raft.go
```

上面的逻辑很清晰。我们紧接着查看`handleAppendEntries()`函数：

```go
func (r *raft) handleAppendEntries(m pb.Message) {
	// 消息中的索引不能小于节点已经提交的消息的索引，否则不追加消息，以已提交的索引作为参数直接回复
	if m.Index < r.raftLog.committed {
		// 此处的 send 函数同 前面 leader 节点在广播日志最终调用的 send 函数为同一个函数
		// 即将此消息放到 raft.msgs 结构中，此结构最后会作为 node 打包 Ready 结构的参数
		// 最后发送给应用程序，然后由应用程序通过网络转发给对应的节点（此处为 leader）
		r.send(pb.Message{To: m.From, Type: pb.MsgAppResp, Index: r.raftLog.committed})
		return
	}
	// 调用 maybeAppend 函数进行日志追加，若追加成功，则以追加后的日志项集合作为参数回复
	if mlastIndex, ok := r.raftLog.maybeAppend(m.Index, m.LogTerm, m.Commit, m.Entries...); ok {
		r.send(pb.Message{To: m.From, Type: pb.MsgAppResp, Index: mlastIndex})
	} else { // 否则表示日志追加失败，则是日志索引不匹配造成
        //（详情可查看 maybeAppedn函数，简而言之，最后会通过调用 append、truncateAndAppend函数以将消息追加到 raftLog 的 unstable 结构中。
        // 此函数在之前的 raftLog 接口实现分析中有涉及，因此不再阐述），
			// 则设置冲突的提示，以及本节点的最后的日志项索引作为参数进行回复
		r.logger.Debugf("%x [logterm: %d, index: %d] rejected msgApp [logterm: %d, index: %d] from %x",
			r.id, r.raftLog.zeroTermOnErrCompacted(r.raftLog.term(m.Index)), m.Index, m.LogTerm, m.Index, m.From)
		r.send(pb.Message{To: m.From, Type: pb.MsgAppResp, Index: m.Index, Reject: true, RejectHint: r.raftLog.lastIndex()})
	}
} // /etcd/raft/raft.go
```

作个简单小结，从上面分析的逻辑可以发现，同`leader`类似，`follower`节点的数据最终也是被写入了日志模块`raftLog`的`unstable`结构中，同样，`follower`节点的回复消息也是加入到`raft.msgs`结构中，最后会成为`Ready`的成员，以传递给应用程序，由应用程序进行实际的网络转发操作。

##### leader 节点处理 follower 节点日志追加响应

最后，同样，当`follower`将回复消息发送之后，再由网络传输组件`transport`调用`node.Process()`函数以处理此消息（此逻辑已在上面的【`folower`节点追加日志】小节中最开始阐述）。因此，最后同样会进入`leader`的`stepLeader()`函数，而且会进入消息类型为`MsgAppResp`分支处理逻辑中，关键代码如下：

```go
func stepLeader(r *raft, m pb.Message) error {
	// ...
	switch m.Type {
	case pb.MsgAppResp:
		pr.RecentActive = true
		if m.Reject { // 若 follower回复拒绝消息
			r.logger.Debugf("%x received msgApp rejection(lastindex: %d) from %x for index %d",
				r.id, m.RejectHint, m.From, m.Index)
            // 则需要减小消息的索引，即往前挑选消息（raft 论文中关于日志冲突已经详细介绍），
            // 即
			if pr.maybeDecrTo(m.Index, m.RejectHint) {
				r.logger.Debugf("%x decreased progress of %x to [%s]", r.id, m.From, pr)
				if pr.State == ProgressStateReplicate {
					pr.becomeProbe()
				} // 再次将消息发送给 follower
				r.sendAppend(m.From)
			}
		} else { // 否则 follower 回复成功追加日志
			oldPaused := pr.IsPaused()
            // 此处为更新 leader 维护的对各 follower 节点的进度详情（具体在 progress.go中描述）
            // 比较简单，因此为了节约篇幅，此处不展开叙述。
            // 事实上，这也是 etcd-raft 针对 原始的 raft 论文作的一些优化。
			if pr.maybeUpdate(m.Index) {
				switch {
				case pr.State == ProgressStateProbe:
					pr.becomeReplicate()
				case pr.State == ProgressStateSnapshot && pr.needSnapshotAbort():
					r.logger.Debugf("%x snapshot aborted, resumed sending replication messages to %x [%s]", r.id, m.From, pr)
					pr.becomeProbe()
					pr.becomeReplicate()
				case pr.State == ProgressStateReplicate:
					pr.ins.freeTo(m.Index)
				}
				// 检查是否需要提交，若的确可以提交，则同样将此消息进行广播
				if r.maybeCommit() {
					r.bcastAppend()
				} else if oldPaused {
					r.sendAppend(m.From)
				}
				// We've updated flow control information above, which may
				// allow us to send multiple (size-limited) in-flight messages
				// at once (such as when transitioning from probe to
				// replicate, or when freeTo() covers multiple messages). If
				// we have more entries to send, send as many messages as we
				// can (without sending empty messages for the commit index)
				for r.maybeSendAppend(m.From, false) {
				}
				// Transfer leadership is in progress.
				if m.From == r.leadTransferee && pr.Match == r.raftLog.lastIndex() {
					r.logger.Infof("%x sent MsgTimeoutNow to %x after received MsgAppResp", r.id, m.From)
					r.sendTimeoutNow(m.From)
				}
			}
		}
	case pb.MsgHeartbeatResp:
		// ...
	case pb.MsgSnapStatus:
		// ...
	case pb.MsgTransferLeader:
		// ...
	}
	return nil
} // /etcd/raft/raft.go
```

至此，`leader`节点处理`follower`节点对日志追加消息的回复也已经分析完毕。

因此，整个完整的流程也已经结束。我们也对`unstabel`以及`raftLog`的流程，即`raft`协议库与`raftLog`的交互作一个简单小结：可以发现，`unstable`或者说`raftLog`只是协议存储管理日志的组件，没有其它作用，即它没有用作诸如节点宕机后重启、新节点加入过程的日志来源。`unstable`是未落盘的日志项集合，即可能会丢失，因此`unstable`日志最终会持久化到`storage`中，即持久化到`snap`以及`WAL`日志。

最后，需要提醒读者的是，文章比较长，若读者没有时间，也可以挑选部分小节进行参考（各小节是独立分析阐述的）。最重要的是，读者自己能够进入到源码文件进行查看，那比本文所贴出的代码逻辑会更容易理解，读者也会获取得更多。





参考文献

[1]. https://github.com/etcd-io/etcd/tree/master/raft