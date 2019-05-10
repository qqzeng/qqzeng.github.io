---
title: etcd raftexample 源码简析
date: 2019-01-09 19:55:11
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 分布式存储
- 分布式缓存
- 一致性协议
- 分布式协调服务
---

最近集中了解了`ZAB`、`Raft`及`Paxos`协议的基本理论，因此想进一步深入到源代码仔细体验一致性协议如何在分布式系统中发挥作用。虽然在 MIT 6.824 课程中有简单实现`Raft`协议，并基于`Raft`构建了一个粗糙的 kv 存储系统。但还是想了解下工业生产级别的`Raft`协议的实现内幕，故选择`etcd`进行解读。`etcd`是 CoreOS 基于`Raft`协议使用 go 开发的分布式 kv 存储系统，可用于服务发现、共享配置及其它利用一致性保障的功能（如`leader`选举及分布式锁、队列等）。这些功能`ZooKeeper`不也有提供？没错。它们都可以作为其它分布式应用的独立协调服务，这通过通用的一致性元信息存储来实现。但在易用性上，`etcd`可谓略胜一筹。因此，后续的一系列博客会简单对`etcd`各重要组成部分的源码进行简要分析（重点在`Raft`实现）。本文主要是分析`etcd`的`raftexample`的代码。它是`etcd`官方提供的如何使用`etcd`内部的`Raft`协议组件来构建分布式应用的一个简单示例。

<!--More-->

（阐述`etcd-raft`的系列文章对应的`etcd-raft`的版本为 3.3.11，但遗憾实际上看的`master unstable`版本）`etcd`内部使用`Raft`协议对集群各节点的状态（数据、日志及快照等）进行同步。类似于`ZooKeeper`利用`ZAB`协议作为底层的可靠的事务广播协议。但`etcd`对`Raft`的实现有点特殊，它底层的`Raft`组件库只实现了`Raft`协议最核心的部分，这主要包括选主逻辑、一致性具体实现以及成员关系变化。而将诸如`WAL`、`snapshot`以及网络传输等模块让用户来实现，这明显增加了使用的难度，但对于应用本质上也更灵活。

本文会简单分析`etcd`提供的如何其核心的`Raft`协议组件来构建一个简单的高可用内存 kv 存储（其本质是一个状态机），用户可以通过 http 协议来访问应用（kv 存储系统），以对数据进行读写操作，在对日志进行读写过程中，`Raft`组件库能够保证各节点数据的一致性。其对应的源码目录为`/etcd-io/etcd/tree/master/contrib/raftexample`。另外，需要强调的是，本文的主题是利用`Raft`协议库来构建一个简单的 kv 存储，关于`Raft`协议库实现的细节不会过多阐述。若读者想继续了解此文，个人建议`clone`源代码，在阅读源代码的过程中，参考本文效果可能会更好，如果有理解错误的地方，欢迎指正！

## 数据结构

在按`raftexample/main`的示例完整解读整个流程之前，先熟悉几个重要的数据结构会有好处。此示例构建的应用为 kv 存储系统，因此，先来了解 `kvstore`定义的相关字段：

```go
// a key-value store backed by raft
type kvstore struct {
	proposeC    chan<- string // channel for proposing updates
	mu          sync.RWMutex
	kvStore     map[string]string // current committed key-value pairs
	snapshotter *snap.Snapshotter
} // kvstore.go
```

关键结构成员解释如下：

- `proposeC`: 应用与底层`Raft`核心库之间的通信`channel`，当用户向应用通过 http 发送更新请求时，应用会将此请求通过`channel`传递给底层的`Raft`库。
- `kvStore`:  kv 结构的内存存储，即对应应用的状态机。
- `snapshotter`: 由应用管理的快照`snapshot`接口。

接下来分析一下应用封装底层`Raft`核心库的结构`raftNode`，应用通过与`raftNode`结构进行交互来使用底层的`Raft`核心协议，它封装完整的`Raft`协议相关的逻辑（如`WAL`及`snapshot`等）。我们先列举它的相关处理逻辑，然后展示其结构内容。具体地逻辑如下：

- 将应用的更新请求传递给`Raft`核心来执行。
- 同时，将`Raft`协议已提交的日志传回给应用，以指示应用来将日志请求应用到状态机。
- 另外，它也处理由`Raft`协议相关的指令，包括选举、成员变化等。
- 处理`WAL`日志相关逻辑。
- 处理快照相关的逻辑。
- 将底层`Raft`协议的指令消息传输到集群其它节点。

```go
// A key-value stream backed by raft
type raftNode struct {
	proposeC    <-chan string            // proposed messages (k,v)
	confChangeC <-chan raftpb.ConfChange // proposed cluster config changes
	commitC     chan<- *string           // entries committed to log (k,v)
	errorC      chan<- error             // errors from raft session

	id          int      // client ID for raft session
	peers       []string // raft peer URLs
	join        bool     // node is joining an existing cluster
	waldir      string   // path to WAL directory
	snapdir     string   // path to snapshot directory
	getSnapshot func() ([]byte, error)
	lastIndex   uint64 // index of log at start

	confState     raftpb.ConfState
	snapshotIndex uint64
	appliedIndex  uint64

	// raft backing for the commit/error channel
	node        raft.Node
	raftStorage *raft.MemoryStorage
	wal         *wal.WAL

	snapshotter      *snap.Snapshotter
	snapshotterReady chan *snap.Snapshotter // signals when snapshotter is ready

	snapCount uint64
	transport *rafthttp.Transport
	stopc     chan struct{} // signals proposal channel closed
	httpstopc chan struct{} // signals http server to shutdown
	httpdonec chan struct{} // signals http server shutdown complete
} // raft.go
```

关键结构成员解释如下：

- `proposeC`: 同`kvStore.proposeC`通道类似，事实上，`kvStore`会将用户的更新请求传递给`raftNode`以使得其最终能传递给底层的`Raft`协议库。
- `confChangeC`: `Raft`协议通过此`channel`来传递集群配置变更的请求给应用。
- `commitC`: 底层`Raft`协议通过此`channel`可以向应用传递准备提交或应用的`channel`，最终`kvStore`会反复从此通道中读取可以提交的日志`entry`，然后正式应用到状态机。
- `node`: 即底层`Raft`协议组件，`raftNode`可以通过`node`提供的接口来与`Raft`组件进行交互。
- `raftStorage`: `Raft`协议的状态存储组件，应用在更新`kvStore`状态机时，也会更新此组件，并且通过`raft.Config`传给`Raft`协议。
- `wal`: 管理`WAL`日志，前文提过`etcd`将日志的相关逻辑交由应用来管理。
- `snapshotter`: 管理 `snapshot`文件，快照文件也是由应用来管理。
- `transport`: 应用通过此接口与集群中其它的节点(`peer`)通信，比如传输日志同步消息、快照同步消息等。网络传输也是由应用来处理。

其它的相关的数据结构不再展开，具体可以查看源代码，辅助注释理解。

## 关键流程

我们从`main.go`中开始通过梳理一个典型的由客户端发起的状态更新请求的完整流程来理解如何利用`Raft`协议库来构建应用状态机。`main.go`的主要逻辑如下：

```go
func main() {
	// 解析客户端请求参数信息
    ...
	proposeC := make(chan string)
	defer close(proposeC)
	confChangeC := make(chan raftpb.ConfChange)
	defer close(confChangeC)

	// raft provides a commit stream for the proposals from the http api
	var kvs *kvstore
	getSnapshot := func() ([]byte, error) { return kvs.getSnapshot() }
	commitC, errorC, snapshotterReady := newRaftNode(*id, strings.Split(*cluster, ","), *join, getSnapshot, proposeC, confChangeC)

	kvs = newKVStore(<-snapshotterReady, proposeC, commitC, errorC)

	// the key-value http handler will propose updates to raft
	serveHttpKVAPI(kvs, *kvport, confChangeC, errorC)
} // main.go
```

显然，此示例的步骤较为清晰。主要包括三方面逻辑：其一，初始化`raftNode`，并通过 go routine 来启动相关的逻辑，实际上，这也是初始化并启动`Raft`协议组件，后面会详细相关流程。其二，初始化应用状态机，它会反复从`commitC`通道中读取`raftNode/Raft`传递给它的准备提交应用的日志。最后，启动 http 服务以接收客户端读写请求，并设置监听。下面会围绕这三个功能相关的逻辑进行阐述。

### Raft 初始化

首先我们来理顺`Raft`初始化的逻辑，这部分相对简单。

```go
func newRaftNode(id int, peers []string, join bool, getSnapshot func() ([]byte, error), proposeC <-chan string,
	confChangeC <-chan raftpb.ConfChange) (<-chan *string, <-chan error, <-chan *snap.Snapshotter) {

	commitC := make(chan *string)
	errorC := make(chan error)

	rc := &raftNode{
		proposeC:    proposeC,
		confChangeC: confChangeC,
		commitC:     commitC,
		errorC:      errorC,
		id:          id,
		peers:       peers,
		join:        join,
		waldir:      fmt.Sprintf("raftexample-%d", id),
		snapdir:     fmt.Sprintf("raftexample-%d-snap", id),
		getSnapshot: getSnapshot,
		snapCount:   defaultSnapshotCount, // 只有当日志数量达到此阈值时才执行快照
		stopc:       make(chan struct{}),
		httpstopc:   make(chan struct{}),
		httpdonec:   make(chan struct{}),

		snapshotterReady: make(chan *snap.Snapshotter, 1),
		// rest of structure populated after WAL replay
	}
	go rc.startRaft() // 通过 go routine 来启动 raftNode 的相关处理逻辑
	return commitC, errorC, rc.snapshotterReady
} // raft.go
```

`newRaftNode`初始化一个`Raft`实例，并且将`commitC`、`errorC`及`snapshotterReady`三个通道返回给`raftNode`。`raftNode`初始化所需要的信息包括集群中其它`peer`的地址、`WAL`管理日志以及`snapshot`管理快照的目录等。接下来，分析稍为复杂的`startRaft`的逻辑：

```go
func (rc *raftNode) startRaft() {
	if !fileutil.Exist(rc.snapdir) { // 若快照目录不存在，则创建
		if err := os.Mkdir(rc.snapdir, 0750); err != nil {
			log.Fatalf("raftexample: cannot create dir for snapshot (%v)", err)
		}
	}
	rc.snapshotter = snap.New(zap.NewExample(), rc.snapdir)
	rc.snapshotterReady <- rc.snapshotter

	oldwal := wal.Exist(rc.waldir) //判断是否已存在 WAL 日志（在节点宕机重启时会执行）
	rc.wal = rc.replayWAL() // 重放 WAL 日志以应用到 raft 实例中

	rpeers := make([]raft.Peer, len(rc.peers))
	for i := range rpeers { // 创建集群节点标识
		rpeers[i] = raft.Peer{ID: uint64(i + 1)}
	}
	c := &raft.Config{ // 初始化底层 raft 协议实例的配置结构
		ID:                        uint64(rc.id),
		ElectionTick:              10,
		HeartbeatTick:             1,
		Storage:                   rc.raftStorage,
		MaxSizePerMsg:             1024 * 1024,
		MaxInflightMsgs:           256,
		MaxUncommittedEntriesSize: 1 << 30,
	}

	if oldwal { // 若已存在 WAL 日志，则重启节点（并非第一次启动）
		rc.node = raft.RestartNode(c)
	} else {
		startPeers := rpeers
		if rc.join { // 节点可以通过两种不同的方式来加入集群，应用以 join 字段来区分
			startPeers = nil
		} // 启动底层 raft 的协议实体 node
		rc.node = raft.StartNode(c, startPeers)
	}
	// 初始化集群网格传输组件
	rc.transport = &rafthttp.Transport{
		Logger:      zap.NewExample(),
		ID:          types.ID(rc.id),
		ClusterID:   0x1000,
		Raft:        rc,
		ServerStats: stats.NewServerStats("", ""),
		LeaderStats: stats.NewLeaderStats(strconv.Itoa(rc.id)),
		ErrorC:      make(chan error),
	}
	// 启动（初始化）transport 的相关内容
	rc.transport.Start()
	for i := range rc.peers { // 为每一个节点添加集群中其它的 peer，并且会启动数据传输通道
		if i+1 != rc.id {
			rc.transport.AddPeer(types.ID(i+1), []string{rc.peers[i]})
		}
	}
	// 启动 go routine 来处理本节点与其它节点通信的 http 服务监听
	go rc.serveRaft()
    // 启动 go routine 来处理 raftNode 与 底层 raft 通过通道来进行通信
	go rc.serveChannels()
}
```

### 应用初始化

应用初始化相关代码较为简单，它只需要初始化内存状态机，并且监听从`raftNode`传来的准备提交的日志的`channel`即可，以将`commitC`读到的日志应用到内存状态机。应用初始化相关代码如下：

```go
func newKVStore(snapshotter *snap.Snapshotter, proposeC chan<- string, commitC <-chan *string, errorC <-chan error) *kvstore {
	s := &kvstore{proposeC: proposeC, kvStore: make(map[string]string), snapshotter: snapshotter}
	// replay log into key-value map
	s.readCommits(commitC, errorC)
	// read commits from raft into kvStore map until error
	go s.readCommits(commitC, errorC)
	return s
} // kvstore.go
```

其中`readComits`即循环监听通道，并从其中取出日志的函数。并且如果本地存在`snapshot`，则先将日志重放到内存状态机中。

```go
func (s *kvstore) readCommits(commitC <-chan *string, errorC <-chan error) {
	for data := range commitC {
		if data == nil {
			// done replaying log; new data incoming
			// OR signaled to load snapshot
			snapshot, err := s.snapshotter.Load()
			if err == snap.ErrNoSnapshot {
				return
			}
			if err != nil {
				log.Panic(err)
			}
			log.Printf("loading snapshot at term %d and index %d", snapshot.Metadata.Term, snapshot.Metadata.Index)
            // 将之前某时刻快照重新设置为状态机目前的状态
			if err := s.recoverFromSnapshot(snapshot.Data); err != nil {
				log.Panic(err)
			}
			continue
		}
		
        // 先对数据解码
		var dataKv kv
		dec := gob.NewDecoder(bytes.NewBufferString(*data))
		if err := dec.Decode(&dataKv); err != nil {
			log.Fatalf("raftexample: could not decode message (%v)", err)
		}
		s.mu.Lock()
		s.kvStore[dataKv.Key] = dataKv.Val
		s.mu.Unlock()
	}
	if err, ok := <-errorC; ok {
		log.Fatal(err)
	}
} // kvstore.go
```

### 开启 http 服务监听

此应用对用户（客户端）提供 http 接口服务。用户可以通过此 http 接口来提交对应用的数据更新请求，应用启动对外服务及设置监听相关逻辑如下：

```go
// serveHttpKVAPI starts a key-value server with a GET/PUT API and listens.
func serveHttpKVAPI(kv *kvstore, port int, confChangeC chan<- raftpb.ConfChange, errorC <-chan error) {
	srv := http.Server{
		Addr: ":" + strconv.Itoa(port),
		Handler: &httpKVAPI{
			store:       kv,
			confChangeC: confChangeC,
		},
	}
	go func() {
		if err := srv.ListenAndServe(); err != nil {
			log.Fatal(err)
		}
	}()

	// exit when raft goes down
	if err, ok := <-errorC; ok {
		log.Fatal(err)
	}
} // httpapi.go
```

而接收并解析用户的请求相关逻辑如下所示，它将从用户接收到的对应用的读写请求，传递给`raftNode`，由`raftNode`传递至底层的`raft`协议核心组件来处理。

```go
func (h *httpKVAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	key := r.RequestURI
	switch {
	case r.Method == "PUT":
		v, err := ioutil.ReadAll(r.Body)
		if err != nil {
			log.Printf("Failed to read on PUT (%v)\n", err)
			http.Error(w, "Failed on PUT", http.StatusBadRequest)
			return
		}
		// 将请求传递至 raftNode 组件，最终会传递到底层的 raft 核心协议模块
		h.store.Propose(key, string(v))

		// Optimistic-- no waiting for ack from raft. Value is not yet
		// committed so a subsequent GET on the key may return old value
		w.WriteHeader(http.StatusNoContent)
	case r.Method == "GET":
		if v, ok := h.store.Lookup(key); ok {
			w.Write([]byte(v))
		} else {
			http.Error(w, "Failed to GET", http.StatusNotFound)
		}
	case r.Method == "POST":
		url, err := ioutil.ReadAll(r.Body)
		if err != nil {
			log.Printf("Failed to read on POST (%v)\n", err)
			http.Error(w, "Failed on POST", http.StatusBadRequest)
			return
		}

		nodeId, err := strconv.ParseUint(key[1:], 0, 64)
		if err != nil {
			log.Printf("Failed to convert ID for conf change (%v)\n", err)
			http.Error(w, "Failed on POST", http.StatusBadRequest)
			return
		}

		cc := raftpb.ConfChange{
			Type:    raftpb.ConfChangeAddNode,
			NodeID:  nodeId,
			Context: url,
		}
		h.confChangeC <- cc

		// As above, optimistic that raft will apply the conf change
		w.WriteHeader(http.StatusNoContent)
	case r.Method == "DELETE":
		nodeId, err := strconv.ParseUint(key[1:], 0, 64)
		if err != nil {
			log.Printf("Failed to convert ID for conf change (%v)\n", err)
			http.Error(w, "Failed on DELETE", http.StatusBadRequest)
			return
		}

		cc := raftpb.ConfChange{
			Type:   raftpb.ConfChangeRemoveNode,
			NodeID: nodeId,
		}
		h.confChangeC <- cc
		// ..
	}
} // httpapi.go
```

### 状态机更新请求

在 `httpapi.go` 的逻辑中，我们选择 PUT 请求分支来进行分析。当它接收到用户发送的更新请求时。它会调用 `kvstore`的`Propose`函数，并将更新请求相关参数传递过去：

```go
func (s *kvstore) Propose(k string, v string) {
	var buf bytes.Buffer
    // 编码后，传递至 raftNode
	if err := gob.NewEncoder(&buf).Encode(kv{k, v}); err != nil {
		log.Fatal(err)
	}
	s.proposeC <- buf.String()
} // kvstore.go
```

在`kvstore`将请求 buf 压到管道后，`raftNode`可以在管道的另一端取出，即在`serverChannel`函数取出请求，并交由底层 `raft`协议核心库来保证此次集群状态的更新。相关代码如下：

```go
func (rc *raftNode) serveChannels() {
	snap, err := rc.raftStorage.Snapshot()
	if err != nil {
		panic(err)
	}
    // 利用 raft 实例的内存状态机初始化 snapshot 相关属性
	rc.confState = snap.Metadata.ConfState
	rc.snapshotIndex = snap.Metadata.Index
	rc.appliedIndex = snap.Metadata.Index

	defer rc.wal.Close()
    // 初始化一个定时器，每次触发 tick 都会调用底层 node.Tick()函数，以表示一次心跳事件，
    // 不同角色的事件处理函数不同。
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	// send proposals over raft
    // 开启 go routine 以接收应用层(kvstore)的请求（包括正常的日志请求及集群配置变更请求）
	go func() {
		confChangeCount := uint64(0)
		// 循环监听来自 kvstore 的请求消息
		for rc.proposeC != nil && rc.confChangeC != nil {
			select {
             // 1. 正常的日志请求
			case prop, ok := <-rc.proposeC:
				if !ok {
					rc.proposeC = nil
				} else {
					// blocks until accepted by raft state machine
                      // 调用底层的 raft 核心库的 node 的 Propose 接口来处理请求
					rc.node.Propose(context.TODO(), []byte(prop))
				}
			// 2. 配置变更请求类似处理
			case cc, ok := <-rc.confChangeC:
				if !ok {
					rc.confChangeC = nil
				} else {
					confChangeCount++
					cc.ID = confChangeCount
					rc.node.ProposeConfChange(context.TODO(), cc)
				}
			}
		}
		// client closed channel; shutdown raft if not already
		close(rc.stopc)
	}()

	// event loop on raft state machine updates
    // 开启 go routine 以循环处理底层 raft 核心库通过 Ready 通道发送给 raftNode 的指令
	for {
		select {
            // 触发定时器事件
		case <-ticker.C:
			rc.node.Tick()

		// store raft entries to wal, then publish over commit channel
         // 1.通过 Ready 获取 raft 核心库传递的指令
		case rd := <-rc.node.Ready():
            // 2. 先写 WAL 日志
			rc.wal.Save(rd.HardState, rd.Entries)
			if !raft.IsEmptySnap(rd.Snapshot) {
				rc.saveSnap(rd.Snapshot)
				rc.raftStorage.ApplySnapshot(rd.Snapshot)
				rc.publishSnapshot(rd.Snapshot)
			}
            // 3. 更新 raft 实例的内存状态
			rc.raftStorage.Append(rd.Entries)
            // 4. 将接收到消息传递通过 transport 组件传递给集群其它 peer
			rc.transport.Send(rd.Messages)
            // 5. 将已经提交的请求日志应用到状态机
			if ok := rc.publishEntries(rc.entriesToApply(rd.CommittedEntries)); !ok {
				rc.stop()
				return
			}
            // 6. 如果有必要，则会触发一次快照
			rc.maybeTriggerSnapshot()
            // 7. 通知底层 raft 核心库，当前的指令已经提交应用完成，这使得 raft 核心库可以发送下一个 Ready 指令了。
			rc.node.Advance()

		case err := <-rc.transport.ErrorC:
			rc.writeError(err)
			return

		case <-rc.stopc:
			rc.stop()
			return
		}
	}
} // raft.go
```

上述关于 `raftNode`与底层`Raft`核心库交互的相关逻辑大致已经清楚。大概地，`raftNode`会将从`kvstore`接收到的用户对状态机的更新请求传递给底层`raft`核心库来处理。此后，`raftNode`会阻塞直至收到由`raft`组件传回的`Ready`指令。根据指令的内容，先写`WAL`日志，更新内存状态存储，并分发至其它节点。最后如果指令已经可以提交，即底层`raft`组件判定请求在集群多数节点已经完成状态复制后，则应用到状态机，具体由`kvstore`来执行。并且若触发了快照的条件，则执行快照操作，最后才通知`raft`核心库可以准备下一个`Ready`指令。关于 `Ready`结构具体内容，我们可以大致看一下：

```go
// Ready encapsulates the entries and messages that are ready to read,
// be saved to stable storage, committed or sent to other peers.
// All fields in Ready are read-only.
// Ready 结构包装了事务日志，以及需要发送给其它 peer 的消息指令，这些字段都是只读的，且有些必须进行持久化，或者已经可以提交应用。
type Ready struct {
	// The current volatile state of a Node.
	// SoftState will be nil if there is no update.
	// It is not required to consume or store SoftState.
    // 包含了内存中的状态，即瞬时状态数据
	*SoftState

	// The current state of a Node to be saved to stable storage BEFORE
	// Messages are sent.
	// HardState will be equal to empty state if there is no update.
    // 包含了持久化的状态，即在消息发送给其它节点前需要保存到磁盘
	pb.HardState

	// ReadStates can be used for node to serve linearizable read requests locally
	// when its applied index is greater than the index in ReadState.
	// Note that the readState will be returned when raft receives msgReadIndex.
	// The returned is only valid for the request that requested to read.
    // 用于节点提供本地的线性化读请求，但其条件是节点的 appliedIndex 必须要大于 ReadState 中的 index，这容易理解，否则会造成客户端的读的数据的不一致
	ReadStates []ReadState

	// Entries specifies entries to be saved to stable storage BEFORE
	// Messages are sent.
    // 表示在发送其它节点之前需要被持久化的状态数据
	Entries []pb.Entry

	// Snapshot specifies the snapshot to be saved to stable storage.
    // 与快照相关，指定了可以持久化的 snapshot 数据
	Snapshot pb.Snapshot

	// CommittedEntries specifies entries to be committed to a
	// store/state-machine. These have previously been committed to stable
	// store.
    // 可以被提交应用到状态机的状态数据
	CommittedEntries []pb.Entry

	// Messages specifies outbound messages to be sent AFTER Entries are
	// committed to stable storage.
	// If it contains a MsgSnap message, the application MUST report back to raft
	// when the snapshot has been received or has failed by calling ReportSnapshot.
    // 当 Entries 被持久化后，需要转发到其它节点的消息
	Messages []pb.Message

	// MustSync indicates whether the HardState and Entries must be synchronously
	// written to disk or if an asynchronous write is permissible.
	MustSync bool
} // /etcd/raft/node.go
```

### 日志管理

`raftexample`中使用了`etcd`提供的通用日志库来管理`WAL`日志，我们下面来分析下应用管理日志的相关逻辑。在上面的状态机更新请求中，注意到当`raftNode`接收到`raft`核心传递的`Ready`指令，第一步就进行写`WAL`日志操作，这种操作较为常见，以避免更新丢失。值得一提的的，`WAL`日志也会在各节点进行同步。另外在`startRaft`函数中，即启动`raftNode`相关逻辑时，便进行了`WAL`日志重放`rc.wal = rc.replayWAL()`，我们详细看一下日志重放的流程：

```go
// replayWAL replays WAL entries into the raft instance.
// 重放节点 WAL 日志，以将重新初始化 raft 实例的内存状态
func (rc *raftNode) replayWAL() *wal.WAL {
	log.Printf("replaying WAL of member %d", rc.id)
    // 1. 加载快照数据
	snapshot := rc.loadSnapshot()
    // 2. 借助快照数据（的相关属性）来打开 WAL 日志。应用只会重放快照时间点（索引）之后的日志，因为快照数据直接记录着状态机的状态数据（这等同于将快照数据所对应的 WAL 日志重放），因此可以直接应用到内存状态结构。换言之，不需要重放 WAL 包含的所有的日志项，这明显可以加快日志重放的速度。结合 openWAL 函数可以得出结论。
	w := rc.openWAL(snapshot)
    // 3. 从 WAL 日志中读取事务日志
	_, st, ents, err := w.ReadAll()
	if err != nil {
		log.Fatalf("raftexample: failed to read WAL (%v)", err)
	}
    // 4. 构建 raft 实例的内存状态结构
	rc.raftStorage = raft.NewMemoryStorage()
	if snapshot != nil {
        // 5. 将快照数据直接加载应用到内存结构
		rc.raftStorage.ApplySnapshot(*snapshot)
	}
	rc.raftStorage.SetHardState(st)

	// append to storage so raft starts at the right place in log
    // 6. 将 WAL 记录的日志项更新到内存状态结构
	rc.raftStorage.Append(ents)
	// send nil once lastIndex is published so client knows commit channel is current
	if len(ents) > 0 {
        // 更新最后一条日志索引的记录
		rc.lastIndex = ents[len(ents)-1].Index
	} else {
		rc.commitC <- nil
	}
	return w
} // raft.go
```

通过查看上述的流程，关于 `WAL`日志重放的流程也很清晰。

### 快照管理

快照(`snapshot`)本质是对日志进行压缩，它是对状态机某一时刻（或者日志的某一索引）的状态的保存。快照操作可以缓解日志文件无限制增长的问题，一旦达日志项达到某一临界值，可以将内存的状态数据进行压缩成为`snapshot`文件并存储在快照目录，这使得快照之前的日志项都可以被舍弃，节约了磁盘空间。我们在上文的状态机更新请求相关逻辑中，发现程序有可能会对日志项进行快照操作即这一行代码逻辑`rc.maybeTriggerSnapshot()`，那我们来具体了解快照是如何创建的：

```go
func (rc *raftNode) maybeTriggerSnapshot() {
    // 1. 只有当前已经提交应用的日志的数据达到 rc.snapCount 才会触发快照操作
	if rc.appliedIndex-rc.snapshotIndex <= rc.snapCount {
		return
	}

	log.Printf("start snapshot [applied index: %d | last snapshot index: %d]", rc.appliedIndex, rc.snapshotIndex)
    // 2. 生成此时应用的状态机的状态数据，此函数由应用提供，可以在 kvstore.go 找到它的定义
	data, err := rc.getSnapshot()
	if err != nil {
		log.Panic(err)
	}
    // 2. 结合已经提交的日志以及配置状态数据正式生成快照
	snap, err := rc.raftStorage.CreateSnapshot(rc.appliedIndex, &rc.confState, data)
	if err != nil {
		panic(err)
	}
    // 4. 快照存盘
	if err := rc.saveSnap(snap); err != nil {
		panic(err)
	}

	compactIndex := uint64(1)
    // 5. 判断是否达到阶段性整理内存日志的条件，若达到，则将内存中的数据进行阶段性整理标记
	if rc.appliedIndex > snapshotCatchUpEntriesN {
		compactIndex = rc.appliedIndex - snapshotCatchUpEntriesN
	}
	if err := rc.raftStorage.Compact(compactIndex); err != nil {
		panic(err)
	}

	log.Printf("compacted log at index %d", compactIndex)
    // 6. 最后更新当前已快照的日志索引
	rc.snapshotIndex = rc.appliedIndex
} // raft.go
```

需要注意的是，每次生成的快照实体包含两个方面的数据：一个显然是实际的内存状态机中的数据，一般将它存储到当前的快照目录中。另外一个为快照的索引数据，即当前快照的索引信息，换言之，即记录下当前已经被执行快照的日志的索引编号，因为在此索引之前的日志不需要执行重放操作，因此也不需要被`WAL`日志管理。快照的索引数据一般存储在日志目录下。

另外关于快照的操作还有利用快照进行恢复操作。这段逻辑较为简单，因为快照就代表内存状态机的瞬时的状态数据，因此，将此数据执行反序列化，并加载到内存状态机即可：

```go
func (s *kvstore) recoverFromSnapshot(snapshot []byte) error {
	var store map[string]string
	if err := json.Unmarshal(snapshot, &store); err != nil {
		return err
	}
	s.mu.Lock()
	s.kvStore = store
	s.mu.Unlock()
	return nil
} // kvstore.go
```

至此，`raftexmaple`主要流程已经简单分析完毕。这是一个简单的应用`etcd`提供的`raft`核心库来构建一个 kv 存储的示例，虽然示例的逻辑较为简单，但它却符合前面提到的一点：`raft`核心库只实现了`raft`协议的核心部分（包括集群选举、成员变更等），而将日志管理、快照管理、应用状态机实现以及消息转发传输相关逻辑交给应用来处理。这使得底层的`raft`核心库的逻辑简单化，只要实现协议的核心功能（一致性主义的保证），然后提供与上层应用的接口，并通过`channel`与上层应用组件交互，如此来构建基于`Raft`协议的分布式高可靠应用。





参考文献

[1]. [etcd-raftexample ](https://github.com/etcd-io/etcd/tree/master/contrib/raftexample)
[2]. [etcd-raft示例分析](https://zhuanlan.zhihu.com/p/29180575)







