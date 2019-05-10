---
title: etcd-raft 网络传输源码简析
date: 2019-01-10 17:33:09
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 网络传输
---

上一篇文章简单分析了`etcd raftexample`的源码。我们知道，`etcd raft`只实现了`raft`协议核心部分，而将诸如日志、快照及消息的网络传输交给应用来管理。本文会简单分析`raft`集群用来实现消息在节点之间传输部分的相关逻辑。因为`etcd raft`会在节点之间传递各种消息指令，包括日志复制、快照拷贝等，这都需要通过应用来将对应的消息转发到集群中其它节点。简单而言，`raft`实现的节点之间的网络传输将消息的读写进行分离，即每两个节点之间存在两条消息通道，分别用作消息的接收与发送，另外针对不同类型的消息的收发，其也提供了不同的组件。本文会对大致的消息传输的流程进行介绍。

<!--More-->

## 数据结构

同上一篇博文类似，希望读者能够主动查看源码（主要涉及目录`/etcd/etcdserver/api/rafthttp`），文章只作参考。我们先来观察一下与网络传输相关的重要的数据结构，一般而言，只要理解了核心的数据结构的功能，基本就能推断相关的功能与大致的流程。网络传输最核心的结构为`Transporter`：

```go
type Transporter interface {
	// Start starts the given Transporter.
	// Start MUST be called before calling other functions in the interface.
    // 在处理具体的消息收发之前，需要启动网络传输组件。它在应用初始化（如初始化 raftNode）时启动
    // 网络传输组件
	Start() error
	// Handler returns the HTTP handler of the transporter.
	// A transporter HTTP handler handles the HTTP requests
	// from remote peers.
	// The handler MUST be used to handle RaftPrefix(/raft)
	// endpoint.
    // 消息传输组件的消息处理器，它对不同消息配置不同的消息处理器（如pipelineHandler、streamHandler）。
	Handler() http.Handler
	// Send sends out the given messages to the remote peers.
	// Each message has a To field, which is an id that maps
	// to an existing peer in the transport.
	// If the id cannot be found in the transport, the message
	// will be ignored.
    // 消息发送接口，即将消息发送到指定 id 的节点
	Send(m []raftpb.Message)
	// SendSnapshot sends out the given snapshot message to a remote peer.
	// The behavior of SendSnapshot is similar to Send.
    // 快照数据发送接口
	SendSnapshot(m snap.Message)
    // 后面都是关于节点的管理的方法，不作重点阐述
	// AddRemote adds a remote with given peer urls into the transport.
	// A remote helps newly joined member to catch up the progress of cluster,
	// and will not be used after that.
	// It is the caller's responsibility to ensure the urls are all valid,
	// or it panics.
	AddRemote(id types.ID, urls []string)
	// AddPeer adds a peer with given peer urls into the transport.
	// It is the caller's responsibility to ensure the urls are all valid,
	// or it panics.
	// Peer urls are used to connect to the remote peer.
	AddPeer(id types.ID, urls []string)
	// RemovePeer removes the peer with given id.
	RemovePeer(id types.ID)
	// RemoveAllPeers removes all the existing peers in the transport.
	RemoveAllPeers()
	// UpdatePeer updates the peer urls of the peer with the given id.
	// It is the caller's responsibility to ensure the urls are all valid,
	// or it panics.
	UpdatePeer(id types.ID, urls []string)
	// ActiveSince returns the time that the connection with the peer
	// of the given id becomes active.
	// If the connection is active since peer was added, it returns the adding time.
	// If the connection is currently inactive, it returns zero time.
	ActiveSince(id types.ID) time.Time
	// ActivePeers returns the number of active peers.
	ActivePeers() int
	// Stop closes the connections and stops the transporter.
	Stop()
} // transport.go
```

需要补充一点的是，在上面的函数声明中，我们可以推测，节点采用`peer`的实例来进行消息的收发，由`transport`只是对外提供统一的接口，并提供逻辑框架。那`remote`又作何用？查看源码注释可以知道，`remote`是帮助新加入到集群的节点"追赶"当前集群正常节点的组件，除那之后，它没有其它作用。而相比之下，`peer`则代表`raft`节点与其它节点通信的实体。后面会详细阐述`peer`组件。下面来了解下`Trasnporter`的具体实现`Transport`结构：

```go
// Transport 实现了 Transporter 接口，用户使用其提供的接口实现完成消息收发
type Transport struct {
	Logger *zap.Logger

	DialTimeout time.Duration // maximum duration before timing out dial of the request
	// DialRetryFrequency defines the frequency of streamReader dial retrial attempts;
	// a distinct rate limiter is created per every peer (default value: 10 events/sec)
	DialRetryFrequency rate.Limit

	TLSInfo transport.TLSInfo // TLS information used when creating connection

	ID          types.ID   // local member ID
	URLs        types.URLs // local peer URLs
	ClusterID   types.ID   // raft cluster ID for request validation
	Raft        Raft       // raft state machine, to which the Transport forwards received messages and reports status
	Snapshotter *snap.Snapshotter
	ServerStats *stats.ServerStats // used to record general transportation statistics
	// used to record transportation statistics with followers when
	// performing as leader in raft protocol
	LeaderStats *stats.LeaderStats  // leader 节点用于记录传输消息到 follower 的相关数据统计
	ErrorC chan error

	streamRt   http.RoundTripper // roundTripper used by streams
	pipelineRt http.RoundTripper // roundTripper used by pipelines

	mu      sync.RWMutex         // protect the remote and peer map
	remotes map[types.ID]*remote // remotes map that helps newly joined member to catch up
	peers   map[types.ID]Peer    // peers map

	pipelineProber probing.Prober
	streamProber   probing.Prober
} // transport.go
```

可以发现，`Transport`里面包含了一个对`Raft`状态机接口，容易想到，因为，当网络传输组件接收到涎宾，需要对消息进行处理，具体即需要交给`Raft`来处理，因此它提供这样一个接口。应用可以实现此接口以实现对接收到的消息进行处理。

```go
type Raft interface {
    // 消息处理接口，raftNode 实现了此函数，并调用底层的 raft 协议库 node 的 Step 函数来处理消息
	Process(ctx context.Context, m raftpb.Message) error 
	IsIDRemoved(id uint64) bool
	ReportUnreachable(id uint64)
	ReportSnapshot(id uint64, status raft.SnapshotStatus)
} // transport.go
```

下面重点来查看一下`peer`数据结构（暂且忽略`remote`）。`Peer`接口定义如下：

```go
type Peer interface {
	// send sends the message to the remote peer. The function is non-blocking
	// and has no promise that the message will be received by the remote.
	// When it fails to send message out, it will report the status to underlying
	// raft.
    // 发送消息的接口，注意此接口是 non-blocking 的，但它不承诺可靠消息传输，但会报告出错信息
	send(m raftpb.Message)

	// sendSnap sends the merged snapshot message to the remote peer. Its behavior
	// is similar to send.
    // 传输快照数据
	sendSnap(m snap.Message)

	// update updates the urls of remote peer.
	update(urls types.URLs)

	// attachOutgoingConn attaches the outgoing connection to the peer for
	// stream usage. After the call, the ownership of the outgoing
	// connection hands over to the peer. The peer will close the connection
	// when it is no longer used.
    // 一旦接收到对端的连接，会把连接 attach 到节点 encoder 的 writer 中，以协同 encoder 和对端decoder的工作了
	attachOutgoingConn(conn *outgoingConn)
	activeSince() time.Time
	stop()
} // peer.go
```

紧接着，我们了解下`Peer`接口的实现`peer`：

```go
type peer struct {
	lg *zap.Logger

	localID types.ID
	// id of the remote raft peer node
	id types.ID

	r Raft

	status *peerStatus

	picker *urlPicker

	msgAppV2Writer *streamWriter
	writer         *streamWriter
	pipeline       *pipeline
	snapSender     *snapshotSender // snapshot sender to send v3 snapshot messages
	msgAppV2Reader *streamReader
	msgAppReader   *streamReader

	recvc chan raftpb.Message
	propc chan raftpb.Message

	mu     sync.Mutex
	paused bool

	cancel context.CancelFunc // cancel pending works in go routine created by peer.
	stopc  chan struct{}
} // peer.go
```

首先，需要说明的是，`peer`包含两种机制来发送消息：`stream`及`pipeline`。其中`stream`被初始化为一个长轮询的连接，在消息传输过程中保持打开的状态。另外，`peer`也提供一种优化后的`stream`以用来发送`msgApp`类型的消息，这种消息由`leader`向`follower`节点发送，其占据一大部分的消息内容。而对比之下，`pipeline`则是为`http`请求提供的`http`客户端。它只在`stream`还没有被建立的时候使用。另外，从`peer`结构中发现还有一个专门用于发送`snap`的发送器。换言之，针对不同的类型的消息采用不同的传输方式应该可以提高效率。

## 关键流程

下面从组件启动开始监听、消息发送及消息接收三个方面来阐述相关的逻辑，这三个方面可能会相互穿插，但如果读者跟着代码来解读，相信也较容易理解。

### 启动监听

下面会从`raftNode`(`raft.go`)中初始化代码开始索引(`startRaft()`)，它使用`rc.transport.Start()`启动网络传输组件，并通过`t.peers[id] = startPeer(t, urls, id, fs)`启动各节点上的网络传输实体。在`startPeer`函数中，分别创建启动了`pipeline`以及`stream`，并提供了两个管道，一个作为消息的缓冲区，但因为消息会被阻塞处理（调用了`Process()`），可能花费较长时间，因此额外提供了一个`pending`的管理用于接收消息。

另外，我们接紧着先来查看一下，`stream`监听消息的逻辑（`pipeline`监听的逻辑更为简单，但流程类似，初始化，然后设置监听）。注意到在`startPeer`函数中有两行代码（针对不同的版本同时启动了相关的逻辑处理），启用了`stream`监听(`p.msgAppV2Reader.start()`)，在`start()`方法中，开启了一个 `go routine`，它这个协程中(`run()`方法)，它会先与对端建立连接，通过`dial()`来实现，然后调用`decodeLoope()`函数来循环读取远程的节点发来的消息，并调用`decode()`函数进行消息解码处理。

### 消息发送

下面梳理一下消息的发送的流程，即在`raft.serveChannels()`函数中，当`raft`应用层收到底层`raft`的消息指令时，需要把消息指令转发给其它`peer`（`rc.transport.Send(rd.Messages)`）。在`Send()`方法中，其大致逻辑为取出对端地址，然后对消息进行发送。在`peer.send()`函数中，它将消息发送到指定的`writerc`中，`writerc`是`pipeline`的一个结构`p.pipeline.msgc`，它在`pipeline.start()`中被初始化，并且在`handler()`方法中持续监听此通道的消息，一旦管道中有消息，则取出消息，并使用`post()`函数发送。

```go
func (p *peer) send(m raftpb.Message) {
	p.mu.Lock()
	paused := p.paused
	p.mu.Unlock()

	if paused {
		return
	}
	// 1. 根据消息的类型选择具体的传输方式
	writec, name := p.pick(m)
	select {
    // 2. 将消息放到管道中
	case writec <- m:
	default:
		p.r.ReportUnreachable(m.To)
		if isMsgSnap(m) {
			p.r.ReportSnapshot(m.To, raft.SnapshotFailure)
		}
		// ...
	}
} // peer.go

// pick picks a chan for sending the given message. The picked chan and the picked chan
// string name are returned.
func (p *peer) pick(m raftpb.Message) (writec chan<- raftpb.Message, picked string) {
	var ok bool
	// Considering MsgSnap may have a big size, e.g., 1G, and will block
	// stream for a long time, only use one of the N pipelines to send MsgSnap.
	if isMsgSnap(m) {
		return p.pipeline.msgc, pipelineMsg
	} else if writec, ok = p.msgAppV2Writer.writec(); ok && isMsgApp(m) {
		return writec, streamAppV2
	} else if writec, ok = p.writer.writec(); ok {
		return writec, streamMsg
	}
	return p.pipeline.msgc, pipelineMsg
} // peer.go


func (p *pipeline) start() {
    p.stopc = make(chan struct{})
    p.msgc = make(chan raftpb.Message, pipelineBufSize)
    p.wg.Add(connPerPipeline)
    for i := 0; i < connPerPipeline; i++ {
        go p.handle()
    }
    // ...
} // pipeline.go

func (p *pipeline) handle() {
    defer p.wg.Done()
    for {
        select {
        case m := <-p.msgc:
            start := time.Now()
            err := p.post(pbutil.MustMarshal(&m)) // 发送消息
            end := time.Now()
            if err != nil {
                // ...
            }
        // ...
    }
} // pipeline.go
```

因此，整个消息发送的流程还是比较简单且清晰的。

### 消息接收

还记得在`raftNode`初始化的过程中，有一行这样的代码`go rc.serveRaft()`，没错，它是用于启动节点网络传输监听。它将监听的处理程序设置为`transport.Handler()`，相关代码如下：

```go
func (rc *raftNode) serveRaft() {
	url, err := url.Parse(rc.peers[rc.id-1])
	ln, err := newStoppableListener(url.Host, rc.httpstopc)
	err = (&http.Server{Handler: rc.transport.Handler()}).Serve(ln) // 开启监听，设置处理器
	select {
	case <-rc.httpstopc:
	default:
		log.Fatalf("raftexample: Failed to serve rafthttp (%v)", err)
	}
	close(rc.httpdonec)
} // raft.go

// 为不同的消息类型设置了不同类型的处理器程序
func (t *Transport) Handler() http.Handler {
	pipelineHandler := newPipelineHandler(t, t.Raft, t.ClusterID)
	streamHandler := newStreamHandler(t, t, t.Raft, t.ID, t.ClusterID)
	snapHandler := newSnapshotHandler(t, t.Raft, t.Snapshotter, t.ClusterID)
	mux := http.NewServeMux()
	mux.Handle(RaftPrefix, pipelineHandler)
	mux.Handle(RaftStreamPrefix+"/", streamHandler)
	mux.Handle(RaftSnapshotPrefix, snapHandler)
	mux.Handle(ProbingPrefix, probing.NewHandler())
	return mux
} // transport.go
```

我们具体到其中一个处理器进行查看，比如`pipelineHandler`，其相关代码如下：

```go
func (h *pipelineHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    // 1. 请求数据检查
	if r.Method != "POST" {
		w.Header().Set("Allow", "POST")
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("X-Etcd-Cluster-ID", h.cid.String())
	limitedr := pioutil.NewLimitedBufferReader(r.Body, connReadLimitByte)
	b, err := ioutil.ReadAll(limitedr)
	// ...
	}
    // 2. 消息解码
	var m raftpb.Message
	if err := m.Unmarshal(b); err != nil {
		// ...
	}
	receivedBytes.WithLabelValues(types.ID(m.From).String()).Add(float64(len(b)))
	// 3. 调用 Raft 的 Process 函数进行消息处理
	if err := h.r.Process(context.TODO(), m); err != nil {
		switch v := err.(type) {
		case writerToResponse:
			v.WriteTo(w)
		default:
		// ...
	}
} // http.go
```

同样，整个消息的接收的流程也较为简单，针对不同类型的消息采用不同的接收及发送处理器，并将接收到的消息直接交给由应用定义的消息处理接口。至此，整个关于`etcd-raft`的网络传输相关逻辑的大致流程已经梳理完毕，介绍得比较浅显，只大概梳理了整个流程，如果读者想要深入了解，可以具体到每一个环节的代码深入分析。



参考文献

[1]. [etcd-raft网络传输组件实现分析](https://zhuanlan.zhihu.com/p/29207055)
[2]. https://github.com/etcd-io/etcd/blob/master/etcdserver/api/rafthttp