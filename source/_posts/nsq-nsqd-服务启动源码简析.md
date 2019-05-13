---
title: nsq nsqd 服务启动源码简析
date: 2019-05-13 11:55:15
categories:
- 消息队列
tags:
- 消息队列
- 分布式系统
---

上一篇文章阐述了`nsqlookupd`模块的源码，主要分析`nsqlookupd`服务进程启动、实例构建及初始化、`tcp & http`请求处理器的构建和注册以及由`nsqlookupd`提供的`topic`注册及查询功能这几个流程的相关源码。`nsqlookupd`耦合的模块较少，程序逻辑也较简单。但由于其和`topic`及`channel`等密切相关，因此`nsqd`更为复杂。`nsqd`充当`nsq`消息队列核心角色，它负责接收、排队以及转发（投递）消息，因此这需要同`nsq`各个组件交互，包括生产者、消费者、`nsqlookupd`以及`nsqadmin`。`nsq`提供`http/https`的方式与生产者通信，主要包括`topic`和`channel`创建和查询，配置更新，以及消息发布等功能。另外`nsq`提供了`tcp`的方式与消费者及生产者通信，为消费者提供消息订阅功能，而为生产者提供消息发布的功能。最后，考虑到`nsqd`无状态的特性，`nsqd`可以通过横向扩展来增强请求处理能力，也可以通过增加一个或多个备份来提高数据可靠性。

<!--More-->

再次强调，个人认为查看或分析源码最好从某个业务逻辑流程切入，必要时忽略某些旁支或细节，做到从宏观上把握整个流程。本文分析`nsqd`服务启动的关键流程，更详细`nsq`源码注释可在[这里](https://github.com/qqzeng/nsqio/tree/master/nsq)找到，注释源码版本为`v1.1.0`，仅供参考。本文所涉及到源码主要为`/nsq/apps/nsqd/`、`/nsq/nsqd/`和`/nsq/internal/`下的若干子目录。

考虑到`nsqd`本身比较复杂，难以在一篇文章中介绍全部内容，因此选择将其进行拆分。本文侧重于分析`nsqd`服务启动相关源码，而在启动过程中涉及到的与`topic`和`channel`耦合部分会另外写一篇文章专门阐述。本文从五个方面来阐述`nsqd`：其一，以`nsqd`命令为切入点，介绍服务启动流程（这部分同`nsqlookupd`非常类似，因此会简述）；其二，同样追溯`nsqd`启动流程，进一步分析介绍初始化过程中`NSQ`的创建及初始化逻辑；其三，阐述`nsqd`异步开启`nsqlookupd`查询过程；其四，阐述`nsqd`同`nsqlookupd`交互的主循环的逻辑（对应源码的`NSQD.lookupLoop`方法）；最后，分析初始化过程所涵盖的`nsqd`建立`tcp`和`http`请求处理器相关逻辑。注意，`nsqd`的核心流程——开启消息队列扫描（对应源码的`NSQD.queueScanLoop`方法），这部分与`topic`及`channel`密切相关，因此放到后面单独阐述。

当我们在命令行执行`nsqd`命令时（同时可指定参数），相当于运行了`nsq/apps/nsqd`程序的`main`方法。此方法启动了一个进程（服务），并且通过创建`NSQD`并调用其`Main`方法执行启动逻辑。

## 利用 svc 启动进程

同[`nsqlookupd`进程启动](https://qqzeng.top/2019/05/12/nsq-nsqlookupd-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/#%E5%88%A9%E7%94%A8-svc-%E5%90%AF%E5%8A%A8%E8%BF%9B%E7%A8%8B)类似，`nsqd`进程的启动，同样是简单包装 [`svc`](https://github.com/judwhite/go-svc/svc)的`Run`方法以启动一个进程（守护进程或服务），然后在 `svc.Run` 方法中依次调用 `Init` 和 `Start` 方法，并阻塞直到接收到 `SIGINT`或`SIGTERM`，最后调用 `stop`方法后退出进程。更多可以查看 `golang` 标准包的`signal.Notify`以及`svc`包是如何协助启动一个进程。启动过程中，首先加载、设置并解析配置参数实例`opts`，然后由此配置实例化`NSQD`。接下来调用`nsqd`的`LoadMetaData`方法加载元数据信息，所谓的元数据信息即包括了`nsqd`所维护的`topic`及`channel`信息（重点是其名称及`paused`状态）。加载完成后，立即就重新将元信息存盘（个人暂时也没完全想明白原因 `#TODO`）。最后异步调用`nsqd.Main`方法完成启动过程的核心逻辑，同时在退出时先调用了`nsqd.Exit`方法。下面对这些过程一一展开叙述。启动过程代码如下：

```go
type program struct {  
	once sync.Once
	nsqd *nsqd.NSQD
}
// nsqd 服务程序执行入口，关于 svc 参考 apps/nsqlookupd/main.go
func main() {
	prg := &program{}
	if err := svc.Run(prg, syscall.SIGINT, syscall.SIGTERM); err != nil {
		logFatal("%s", err)
	}
} // /nsq/apps/nsqd/main.go
// 在 Start 方法调用之前执行，在此无实际用途
func (p *program) Init(env svc.Environment) error {
	if env.IsWindowsService() {
		dir := filepath.Dir(os.Args[0])
		return os.Chdir(dir)
	}
	return nil
}
// 启动方法
func (p *program) Start() error {
	// 1. 通过程序默认的参数构建 options 实例
	opts := nsqd.NewOptions()
	// 2. 将 opts 结合命令行参数集进行进一步初始化
	flagSet := nsqdFlagSet(opts)
	flagSet.Parse(os.Args[1:])
	rand.Seed(time.Now().UTC().UnixNano())
	// 3. 若 version 参数存在，则打印版本号，然后退出
	if flagSet.Lookup("version").Value.(flag.Getter).Get().(bool) {
		fmt.Println(version.String("nsqd"))
		os.Exit(0)
	}
	// 4. 若用户指定了自定义配置文件，则加载配置文件，读取配置文件，校验配置文件合法性
	// 读取解析配置文件采用的是第三方库 https://github.com/BurntSushi/toml
	var cfg config
	configFile := flagSet.Lookup("config").Value.String()
	if configFile != "" {
		_, err := toml.DecodeFile(configFile, &cfg)
		// ...
	}
	cfg.Validate()
	options.Resolve(opts, flagSet, cfg)
	// 5. 通过给定参数 opts 构建 nsqd 实例
	nsqd, err := nsqd.New(opts)
	if err != nil {
		logFatal("failed to instantiate nsqd - %s", err)
	}
	p.nsqd = nsqd
	// 6. 加载 metadata　文件，
    // 若文件存在，则恢复 topic 和 channel的信息（如pause状态），并调用 topic.Start方法
	err = p.nsqd.LoadMetadata()
	if err != nil {
		logFatal("failed to load metadata - %s", err)
	}
	// 7. 重新持久化 metadata 到文件，原因？　TODO
	// 即持久化 topic 及 channel的元信息（即不包括其数据）到文件中
	err = p.nsqd.PersistMetadata()
	if err != nil {
		logFatal("failed to persist metadata - %s", err)
	}
	// 8. 在单独的 go routine 中启动 nsqd.Main 方法
	go func() {
		err := p.nsqd.Main()
		if err != nil {
			p.Stop()
			os.Exit(1)
		}
	}()
	return nil
} // /nsq/apps/nsqd/main.go
func (p *program) Stop() error {
	p.once.Do(func() {
		p.nsqd.Exit()
	})
	return nil
} // /nsq/apps/nsqd/main.go
```

下面分析`main`方法中的关键方法。元数据加载和持久化方法（`nsqd.LoadMetadata`和`nsqd.persistMetadata`），这里的元数据不包括具体的数据，比如`message`。在加载元数据过程中即读取`nsqd.dat`文件，如果文件内容为空，则表明是首次启动，直接返回。否则，读取文件内容并反序列化，针对读取的`topic`的列表中的每一个`topic`，会获取与其关联的`channel`列表，并设置它们的`paused`属性。关于`paused`属性，对于`topic`而言，若`paused`属性被设置，则它不会将由生产者发布的消息写入到关联的`channel`的消息队列。而对`channel`而言，若其`paused`属性被设置，则那些订阅了此`channel`的客户端不会被推送消息（这两点在后面的源码中可以验证）。其中根据`topic`或`channel`的名称获取对应的实例的方法为`nsqd.GetTopic`和`topic.GetChannel`方法，这两个方法会在阐述`topic`和`channel`的时详细分析。但注意一点是，若获取一个不存在的`topic/channel`，则会创建一个对应实例（还记得第一篇文章所述，`topic`及`channel`实例不会被提前创建，而是在生产者发布消息或显式创建一个`topic`时才被创建，而`channel`则是在生产者显式地订阅一个`channel`时才被创建）。最后调用`topic.Start`方法向`topic.startChan`通道中压入一条消息，消息会在`topic.messagePump`方法中被取出，以表明`topic`可以开始进入消息队列处理的主循环。元数据的持久化则恰是一个逆过程，即获取`nsqd`实例内存中的`topic`集合，并递归地将其对应的`channel`集合保存到文件，且持久化也是通过先写临时文件，再原子性地重命名。值得注意的是整个`nsq`中（包括`nsqd`和`nsqlookupd`）涉及到数据持久化的过程只有`nsqd`的元数据的持久化以及`nsqd`对消息的持久化（通过`diskQueue`完成），而`nsqlookupd`则不涉及持久化操作。元数据加载和持久化相关代码如下：

```go
// metadata 结构， Topic 结构的数组
type meta struct {
	Topics []struct {
		Name     string `json:"name"`
		Paused   bool   `json:"paused"`
		Channels []struct {
			Name   string `json:"name"`
			Paused bool   `json:"paused"`
		} `json:"channels"`
	} `json:"topics"`
}
// 加载 metadata 
func (n *NSQD) LoadMetadata() error {
	atomic.StoreInt32(&n.isLoading, 1)
	defer atomic.StoreInt32(&n.isLoading, 0)
	// 1. 构建 metadata 文件全路径， nsqd.dat，并读取文件内容
	fn := newMetadataFile(n.getOpts())
	data, err := readOrEmpty(fn)
	// ...
	// 2. 若文件内容为空，则表明是第一次启动， metadata 加载过程结束
	if data == nil {
		return nil // fresh start
	}
	var m meta
	err = json.Unmarshal(data, &m)
	// ...
	// 3. 若文件内容不为空，则遍历所有 topic，针对每一个 topic 及 channel先前保持的情况进行还原．
    // 比如是否有被 pause，最后启动 topic
	for _, t := range m.Topics {
		// ...
		// 根据 topic name 获取对应的 topic 实例，若对应的 topic 实例不存在，则会创建它。
		// （因此在刚启动时，会创建所有之前保存的到文件中的 topic 实例，后面的 channel 也是类似的）
		topic := n.GetTopic(t.Name)
		if t.Paused {
			topic.Pause()
		}
		for _, c := range t.Channels {
			if !protocol.IsValidChannelName(c.Name) {
				n.logf(LOG_WARN, "skipping creation of invalid channel %s", c.Name)
				continue
			}
			channel := topic.GetChannel(c.Name)
			if c.Paused {
				channel.Pause()
			}
		}
		// 启动对应的 topic，开启了消息处理循环
		topic.Start()
	}
	return nil
} // /nsq/nsqd/nsqd.go

// 创建 metadata 文件，遍历 nsqd 节点所有的 topic，
// 针对每一个非 ephemeral 属性的 topic，保存其 name、paused 属性
//（换言之不涉及到 topic 及 channel 的数据部分）
// 另外，保存 topic 所关联的非 ephemeral 的 channel 的 name、paused 属性
// 最后同步写入文件，注意在写文件，先是写到临时文件中，然后调用　OS.rename操作，以保证写入文件的原子性
func (n *NSQD) PersistMetadata() error {
	// persist metadata about what topics/channels we have, across restarts
	fileName := newMetadataFile(n.getOpts())
	n.logf(LOG_INFO, "NSQ: persisting topic/channel metadata to %s", fileName)
	js := make(map[string]interface{})
	topics := []interface{}{}
	for _, topic := range n.topicMap {
		if topic.ephemeral { // 临时的 topic 不被持久化
			continue
		}
		topicData := make(map[string]interface{})
		topicData["name"] = topic.name
		topicData["paused"] = topic.IsPaused()
		channels := []interface{}{}
		topic.Lock()
		for _, channel := range topic.channelMap {
			channel.Lock()
			if channel.ephemeral { // 临时的 channel 不被持久化
				channel.Unlock()
				continue
			}
			channelData := make(map[string]interface{})
			channelData["name"] = channel.name
			channelData["paused"] = channel.IsPaused()
			channels = append(channels, channelData)
			channel.Unlock()
		}
		topic.Unlock()
		topicData["channels"] = channels
		topics = append(topics, topicData)
	}
	js["version"] = version.Binary
	js["topics"] = topics
	data, err := json.Marshal(&js)
	// ...
	tmpFileName := fmt.Sprintf("%s.%d.tmp", fileName, rand.Int())
	err = writeSyncFile(tmpFileName, data)
	// ...
	err = os.Rename(tmpFileName, fileName)
	// ...
	// technically should fsync DataPath here
	return nil
} // /nsq/nsqd/nsqd.go
```

至此，`nsqd`的进程启动过程进行了大概地梳理。其包含两个重点一个是其利用`svc`来启动一个进程，另一个为`nsqd`加载及持久化元数据相关的逻辑，其中的`paused`属性与`topic/channel`密切相关。

## nsqd 创建及初始化

在阐述`nsqd`实例创建和启动过程前，先了解下其组成结构。其中最重要的几个字段为`topicMap`存储`nsqd`所维护的`topic`集合，`lookupPeers`为`nsqd`与`nsqlookupd`之间网络连接的抽象实体，`cliens`为订阅了此`nsqd`所维护的`topic`的客户端实体，还有`notifyChan`通道的作用是当`channel`或`topic`更新时（新增或删除），通知`nsqlookupd`服务更新对应的注册信息。相关代码如下：

```go
type NSQD struct {
	// 64bit atomic vars need to be first for proper alignment on 32bit platforms
	clientIDSequence int64							// nsqd 借助它为订阅的 client 生成 ID
	sync.RWMutex
	opts atomic.Value								// 配置参数实例
	dl        *dirlock.DirLock
	isLoading int32									// nsqd 当前是否处于启动加载过程
	errValue  atomic.Value
	startTime time.Time
	topicMap map[string]*Topic						// nsqd 所包含的 topic 集合
	clientLock sync.RWMutex							// guards clients
	// 向 nsqd 订阅的 client 的集合，即订阅了此 nsqd 所维护的 topic 的客户端
    clients    map[int64]Client						
	lookupPeers atomic.Value						// nsqd与nsqlookupd之间网络连接抽象实体
	tcpListener   net.Listener						// tcp 连接 listener
	httpListener  net.Listener						// http 连接 listener
	httpsListener net.Listener						// https 连接 listener
	tlsConfig     *tls.Config
	// queueScanWorker 的数量，每个 queueScanWorker代表一个单独的goroutine，用于处理消息队列
    poolSize int
    // 当 channel 或 topic 更新时（新增或删除），用于通知 nsqlookupd 服务更新对应的注册信息
	notifyChan           chan interface{}			
	optsNotificationChan chan struct{}	// 当 nsqd 的配置发生变更时，可以通过此 channel 通知
	exitChan             chan int					// nsqd 退出开关
	waitGroup            util.WaitGroupWrapper		// waitGroup 的一个 wrapper 结构

	ci *clusterinfo.ClusterInfo
} // /nsq/nsqd/nsqd.go
```

`nsqd`实例化过程，比较简单，没有特别关键逻辑，主要是初始化一些属性，创建`tcp/http/https`的连接监听。简要贴下代码：

```go
func New(opts *Options) (*NSQD, error) {
	var err error
	dataPath := opts.DataPath
	// ...
	n := &NSQD{
		startTime:            time.Now(),
		topicMap:             make(map[string]*Topic),
		clients:              make(map[int64]Client),
		exitChan:             make(chan int),
		notifyChan:           make(chan interface{}),
		optsNotificationChan: make(chan struct{}, 1),
		dl:                   dirlock.New(dataPath),
	}
	httpcli := http_api.NewClient(nil, opts.HTTPClientConnectTimeout, opts.HTTPClientRequestTimeout)
	n.ci = clusterinfo.New(n.logf, httpcli)
	n.lookupPeers.Store([]*lookupPeer{})
	n.swapOpts(opts)
	n.errValue.Store(errStore{})
	err = n.dl.Lock()
	// ...
	// ...
	if opts.TLSClientAuthPolicy != "" && opts.TLSRequired == TLSNotRequired {
		opts.TLSRequired = TLSRequired
	}
	tlsConfig, err := buildTLSConfig(opts)
	// ...
	n.tlsConfig = tlsConfig
	for _, v := range opts.E2EProcessingLatencyPercentiles {
		if v <= 0 || v > 1 {
			return nil, fmt.Errorf("invalid E2E processing latency percentile: %v", v)
		}
	}
	n.tcpListener, err = net.Listen("tcp", opts.TCPAddress)
	// ...
	n.httpListener, err = net.Listen("tcp", opts.HTTPAddress)
	// ...
	if n.tlsConfig != nil && opts.HTTPSAddress != "" {
		n.httpsListener, err = tls.Listen("tcp", opts.HTTPSAddress, n.tlsConfig)
		// ...
	}
	return n, nil
} // /nsq/nsqd/nsqd.go
```

重点在`nsqd.Main`方法中所涉及到的逻辑。它首先构建一个`Context`实例（纯粹`nsqd`实例的`wrapper`），然后注册一个方法退出的`hook`函数。接下来，构建并注册用于处理`tcp`和`http`请求的`handler`，其中`tpc handler`比较简单，而`http handler`同样复用[`httprouter`](https://github.com/julienschmidt/httprouter)作为请求路由器。而最关键的部分在于开启了三个`goroutine`用于处理`nsqd`内部逻辑，其中`NSQD.queueScanLoop`开启了`nsqd`的消息队列扫描处理逻辑，而`NSQD.lookupLoop`则开启了`nsqlookupd`查询过程，以及同`nsqlookupd`交互的主循环中的逻辑，最后的`NSQD.statsdLoop`则开启了一些数据统计工作（这部分不会做多介绍）。在`nsqd.Main`方法的最后，阻塞等待退出的信号`exitChan`。上述逻辑的相关代码如下：

```go
// NSQD 进程启动入口程序
func (n *NSQD) Main() error {
	// 1. 构建 Context 实例， NSQD wrapper
	ctx := &context{n}
	// 2. 同 NSQLookupd 类似，构建一个退出 hook 函数，且在退出时仅执行一次
	exitCh := make(chan error)
	var once sync.Once
	exitFunc := func(err error) {
		once.Do(func() {
			if err != nil {
				n.logf(LOG_FATAL, "%s", err)
			}
			exitCh <- err
		})
	}
	// 3. 构建用于处理 tcp连接的tcp handler，同样注册退出前需要执行的函数（打印连接关闭错误信息）
	tcpServer := &tcpServer{ctx: ctx}
	n.waitGroup.Wrap(func() {
		exitFunc(protocol.TCPServer(n.tcpListener, tcpServer, n.logf))
	})
	// 4. 构建用于处理 http 连接的 http handler，注册错误打印函数
	httpServer := newHTTPServer(ctx, false, n.getOpts().TLSRequired == TLSRequired)
	n.waitGroup.Wrap(func() {
		exitFunc(http_api.Serve(n.httpListener, httpServer, "HTTP", n.logf))
	})
	// 5. 若配置了 https 通信，则仍然构建 http 连接的 https handler（但同时开启 tls），
    // 同样注册错误打印函数
	if n.tlsConfig != nil && n.getOpts().HTTPSAddress != "" {
		httpsServer := newHTTPServer(ctx, true, true)
		n.waitGroup.Wrap(func() {
			exitFunc(http_api.Serve(n.httpsListener, httpsServer, "HTTPS", n.logf))
		})
	}
	// 6. 等待直到 queueScanLoop循环，lookupLoop 循环以及 statsdLoop，主程序才能退出
	// 即开启了 队列scan扫描 goroutine 以及  lookup 的查找 goroutine
	n.waitGroup.Wrap(n.queueScanLoop)
	n.waitGroup.Wrap(n.lookupLoop)
	if n.getOpts().StatsdAddress != "" {
		// 还有 状态统计处理 go routine
		n.waitGroup.Wrap(n.statsdLoop)
	}
	err := <-exitCh
	return err
} // /nsq/nsqd/nsqd.go
```

## nsqd 开启 nsqlookupd 查询过程

这一小节介绍`NSQD.lookupLoop`方法，它代表`nsqd`开启`nsqlookupd`查询过程（这在[一篇文章](https://qqzeng.top/2019/05/12/nsq-nsqlookupd-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)有介绍）。在`nsqd`刚创建时，通过读取配置文件中所配置的`nsqlookupd`实例地址(`nsqlookupd_tcp_addresses`)集合（一个`nsqd`可连接到多个`nsqlookupd`实例），建立对应的网络连接的抽象实体(`lookupPeer`实例)，设置自己的状态为`stateDisconnected`，同时传入连接建立成功后的一个回调函数(`connectCallback`)。接下来，则调用`lookupPeer.Command`方法向指定`nsqlookupd`发起连接建立过程。此时，连接建立成功后，立即向对方发送一个`MagicV1`的消息以声明自己的通信协议版本（官方称这有用于协议升级），并忽略响应。并判断若此前的连接状态为`stateDisconnected`，则调用其连接成功的回调函数`connectCallback`。上述逻辑相关的代码如下：

```go
// 开启 lookup 循环
func (n *NSQD) lookupLoop() {
	var lookupPeers []*lookupPeer
	var lookupAddrs []string
	connect := true
	hostname, err := os.Hostname()
	// ...
	// for announcements, lookupd determines the host automatically
	ticker := time.Tick(15 * time.Second)
	for {
		// 1. 在 nsqd 刚创建时，先构造 nsqd 同各 nsqlookupd（从配置文件中读取）
        // 的 lookupPeer 连接，并执行一个回调函数
		if connect { // 在 nsqd 启动时会进入到这里，即创建与各 nsqlookupd 的连接
			for _, host := range n.getOpts().NSQLookupdTCPAddresses {
				if in(host, lookupAddrs) {
					continue
				}
				n.logf(LOG_INFO, "LOOKUP(%s): adding peer", host)
				lookupPeer := newLookupPeer(host, n.getOpts().MaxBodySize, n.logf,
					connectCallback(n, hostname))
				lookupPeer.Command(nil) // 开始建立连接，nil 代表连接初始建立，没用实际命令请求
				// 更新 nsqlookupd 的连接实体和地址
                lookupPeers = append(lookupPeers, lookupPeer)
				lookupAddrs = append(lookupAddrs, host)
			}
			n.lookupPeers.Store(lookupPeers)
			connect = false
		}
        // 这里是 nsqd 实例处理与 nsqlookupd 实例交互的主循环（在后面详细介绍）
        // ...
    }
exit:
	n.logf(LOG_INFO, "LOOKUP: closing")
} // /nsq/nsqd/nsqd.go
```

```go
// lookupPeer 代表 nsqd 同 nsqdlookupd 进行连接、读取以及写入操作的一种抽象类型结构
// lookupPeer 实例被设计成延迟连接到 nsqlookupd，并且会自动重连
type lookupPeer struct {
	logf            lg.AppLogFunc
	addr            string            // 需要连接到对端的地址信息，即为 nsqlookupd 的地址
	conn            net.Conn          // 网络连接
	state           int32             // 当前 lookupPeer 连接的状态 5 种状态之一
	connectCallback func(*lookupPeer) // 成功连接到指定的地址后的回调函数
	maxBodySize     int64             // 在读取命令请求的处理返回结果时，消息体的最大字节数
	Info            peerInfo
}  // /nsq/nsqd/lookup_peer.go

// peerInfo contains metadata for a lookupPeer instance (and is JSON marshalable)
// peerInfo 代表 lookupPeer 实例的与网络连接相关的信息实体
type peerInfo struct {
	TCPPort          int    `json:"tcp_port"`
	HTTPPort         int    `json:"http_port"`
	Version          string `json:"version"`
	BroadcastAddress string `json:"broadcast_address"`
}
// ...
// Read implements the io.Reader interface, adding deadlines
// lookupPeer 实例从指定的连接中　lookupPeer.conn　中读取数据，并指定超时时间
func (lp *lookupPeer) Read(data []byte) (int, error) {
	lp.conn.SetReadDeadline(time.Now().Add(time.Second))
	return lp.conn.Read(data)
}

// Write implements the io.Writer interface, adding deadlines
// lookupPeer 实例将数据写入到指定连接中，并指定超时时间
func (lp *lookupPeer) Write(data []byte) (int, error) {
	lp.conn.SetWriteDeadline(time.Now().Add(time.Second))
	return lp.conn.Write(data)
}  // /nsq/nsqd/lookup_peer.go
// ...
// 为 lookupPeer执行一个指定的命令，并且获取返回的结果。
// 如果在这之前没有连接到对端，则会先进行连接动作
func (lp *lookupPeer) Command(cmd *nsq.Command) ([]byte, error) {
	initialState := lp.state
	// 1. 当连接尚未建立时，走这里
	if lp.state != stateConnected {
		err := lp.Connect() // 2. 发起连接建立过程
		// ...
		lp.state = stateConnected // 3. 更新对应的连接状态
		// 4. 在发送正式的命令请求前，需要要先发送一个 4byte 的序列号，用于协定后面用于通信的协议版本
		_, err = lp.Write(nsq.MagicV1)
		if err != nil {
			lp.Close()
			return nil, err
		}
		// 5. 在连接成功后，需要执行一个成功连接的回调函数（在正式发送命令请求之前）
		if initialState == stateDisconnected {
			lp.connectCallback(lp)
		}
		if lp.state != stateConnected {
			return nil, fmt.Errorf("lookupPeer connectCallback() failed")
		}
	}
	// 6. 在创建 lookupPeer 时会发送一个空的命令请求，
	// 其目的为创建正式的网络连接，同时，执行连接成功的回调函数
	if cmd == nil {
		return nil, nil
	}
	// 7. 发送指定的命令请求到对端（包括命令的 name、params，一个空行以及body（写body之前要先写入其长度））
	_, err := cmd.WriteTo(lp)
	// ...
	// 8. 读取并返回响应内容
	resp, err := readResponseBounded(lp, lp.maxBodySize)
	// ...
	return resp, nil
} // /nsq/nsqd/lookup_peer.go
```

当连接建立成功后（不要忘记在这之前发送了一个`MagicV1`的消息），会执行一个回调函数。此回调函数的主要逻辑为`nsqd`向`nsqlookupd`发送一个`IDENTIFY`命令请求以表明自己身份信息，然后遍历自己所维护的`topicMap`集合，构建所有即将执行的`REGISTER`命令请求，最后依次执行每一个请求。相关代码如下：

```go
// 连接成功后需要执行的回调函数
func connectCallback(n *NSQD, hostname string) func(*lookupPeer) {
	return func(lp *lookupPeer) {
		// 1. 打包 nsqd 自己的信息，主要是与网络连接相关
		ci := make(map[string]interface{})
		ci["version"] = version.Binary
		ci["tcp_port"] = n.RealTCPAddr().Port
		ci["http_port"] = n.RealHTTPAddr().Port
		ci["hostname"] = hostname
		ci["broadcast_address"] = n.getOpts().BroadcastAddress
		// 2. 发送一个 IDENTIFY 命令请求，以提供自己的身份信息
		cmd, err := nsq.Identify(ci)
		// ...
		resp, err := lp.Command(cmd)
		// 3. 解析并校验 IDENTIFY 请求的响应内容
		// ...
		// 4. 构建所有即将发送的 REGISTER 请求，用于向 nsqlookupd注册信息 topic 和channel信息
		var commands []*nsq.Command
		n.RLock()
		for _, topic := range n.topicMap {
			topic.RLock()
			if len(topic.channelMap) == 0 {
				commands = append(commands, nsq.Register(topic.name, ""))
			} else {
				for _, channel := range topic.channelMap {
					commands = append(commands, nsq.Register(
                        channel.topicName, channel.name))
				}
			}
			topic.RUnlock()
		}
		n.RUnlock()
		// 5. 最后，遍历 REGISTER 命令集合，依次执行它们，
        // 并忽略返回结果（当然肯定要检测请求是否执行成功）
		for _, cmd := range commands {
			n.logf(LOG_INFO, "LOOKUPD(%s): %s", lp, cmd)
			_, err := lp.Command(cmd)
			// ...
		}
	}
} // /nsq/nsqd/lookup.go
```

## nsqd 与 nsqlookupd 交互主循环

当`nsqd`启动后与`nsqlookup`之后，它便开启了和`nsqlookupd`交互的主循环，即`lookupLoop`方法剩余部分。主循环中的逻辑主要分为三个部分，通过`select`语法来触发执行。其一，`nsqd`每过15s（好像是硬编码的）向`nsqlookupd`发送一个心跳消息(`PING`)；其二，通过`notifyChan`通道从`nsqd`收到消息时（即`nsqd.Notify`方法被调用），表明`nsqd`所维护的`topic`集合（包括`channel`）发生了变更（添加或移除）。若接收到的消息为`channel`，则根据此`channel`是否存在，进而发送`REGISTER/UNREGISTER`通知所有的`nsqlookupd`有`channel` 添加或除移。而`topic`的执行逻辑完全类似；最后，当从`nsqd`通过`optsNotificationChan`通道收到`nsqlookupd`地址变更消息，则重新从配置文件中加载`nsqlookupd`的配置信息。当然，若`nsqd`退出了，此处理循环也需要退出。相关的代码如下：

```go
// 开启 lookup 循环
func (n *NSQD) lookupLoop() {
	var lookupPeers []*lookupPeer
	var lookupAddrs []string
	connect := true
	hostname, err := os.Hostname()
	// ...
	// for announcements, lookupd determines the host automatically
	ticker := time.Tick(15 * time.Second)
	for {
		// 1. 在 nsqd 刚创建时，先构造 nsqd 同各 nsqlookupd（从配置文件中读取）
        // 的 lookupPeer 连接，并执行一个回调函数
		// ...
		select {
		// 2. 每 15s 就发送一个 heartbeat 消息给所有的 nsqlookupd，并读取响应。
            // 此目的是为了及时检测到已关闭的连接
		case <-ticker:
			// send a heartbeat and read a response (read detects closed conns)
			for _, lookupPeer := range lookupPeers {
				n.logf(LOG_DEBUG, "LOOKUPD(%s): sending heartbeat", lookupPeer)
				// 发送一个 PING 命令请求，利用 lookupPeer 的 Command 方法发送此命令请求，
                // 并读取响应，忽略响应（正常情况下 nsqlookupd 端的响应为 ok）
				cmd := nsq.Ping()
				_, err := lookupPeer.Command(cmd)
				// ...
			}
		// 3. 收到 nsqd 的通知，即 nsqd.Notify 方法被调用，
		// 从 notifyChan 中取出对应的对象 channel 或 topic
        //（在 channel 或 topic 创建及退出/exit(Delete)会调用 nsqd.Notify 方法）
		case val := <-n.notifyChan:
			var cmd *nsq.Command
			var branch string
			switch val.(type) {
			// 3.1 若是 Channel，则通知所有的 nsqlookupd 有 channel 更新（新增或者移除）
			case *Channel:
				branch = "channel"
				channel := val.(*Channel)
                // 若 channel 已退出，即 channel被 Delete，则构造 UNREGISTER 命令请求
				if channel.Exiting() == true { 
					cmd = nsq.UnRegister(channel.topicName, channel.name)
				} else { // 否则表明 channel 是新创建的，则构造 REGISTER 命令请求
					cmd = nsq.Register(channel.topicName, channel.name)
				}
			// 3.2 若是 Topic，则通知所有的 nsqlookupd 有 topic 更新（新增或者移除），
                // 处理同 channel 类似
			case *Topic:
				branch = "topic"
				topic := val.(*Topic)
                // 若 topic 已经退出，即 topic 被 Delete，则 nsqd 构造 UNREGISTER 命令请求
				if topic.Exiting() == true {
					cmd = nsq.UnRegister(topic.name, "")
				} else {
                 // 若 topic 已经退出，即 topic 被 Delete，则 nsqd 构造 UNREGISTER 命令请求
					cmd = nsq.Register(topic.name, "")
				}
			}
			// 3.3 遍历所有 nsqd 保存的 nsqlookupd 实例的地址信息
			// 向每个 nsqlookupd 发送对应的 Command
			for _, lookupPeer := range lookupPeers {
				n.logf(LOG_INFO, "LOOKUPD(%s): %s %s", lookupPeer, branch, cmd)
                // 这里忽略了返回的结果，nsqlookupd 返回的是 ok
				_, err := lookupPeer.Command(cmd) 
				if err != nil {
					n.logf(LOG_ERROR, "LOOKUPD(%s): %s - %s", lookupPeer, cmd, err)
				}
			}
		// 4. 若是 nsqlookupd 的地址变更消息，则重新从配置文件中加载 nsqlookupd 的配置信息
		case <-n.optsNotificationChan:
			var tmpPeers []*lookupPeer
			var tmpAddrs []string
			for _, lp := range lookupPeers {
				if in(lp.addr, n.getOpts().NSQLookupdTCPAddresses) {
					tmpPeers = append(tmpPeers, lp)
					tmpAddrs = append(tmpAddrs, lp.addr)
					continue
				}
				n.logf(LOG_INFO, "LOOKUP(%s): removing peer", lp)
				lp.Close()
			}
			lookupPeers = tmpPeers
			lookupAddrs = tmpAddrs
			connect = true
		// 5. nsqd 退出消息
		case <-n.exitChan:
			goto exit
		}
	}
exit:
	n.logf(LOG_INFO, "LOOKUP: closing")
} // /nsq/nsqd/lookup.go
```

至此，`NSQD.lookupLoop`方法已经解析完毕。接下来，介绍`nsqd`网络连接`tpc/http`处理器的建立及注册。

## nsqd 的 tcp & http 连接处理器

`nsqd`为客户端（包括生产者和消费者）建立的`tcp/http`连接的请求处理器的逻辑，和`nsqlookupd`为客户端（包括`nsqd`和消费者）建立的`tcp/http`连接请求处理器是类似的。因此这里不会详细阐述。可参考[这里](https://qqzeng.top/2019/05/12/nsq-nsqlookupd-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/#tcp-amp-http-%E8%AF%B7%E6%B1%82%E5%A4%84%E7%90%86)。另外，监听`tcp`连接请求的处理器（用于`accpet`连接）与`nsqlookupd`的建立的都是`tcpServer`，另外，当`accpet`到连接后，首先从连接中读取一个`4byte`的协议版本号，且目前源码中只支持`V2`，真正处理连接请求的方法为`protocolV2.IOLoop`。而`http`连接请求，则同样复用`httprouter`作为请求路由器。

### tcp 连接处理器

`nsqd`为每一个客户端都会异步开启一个`protocolV2.IOLoop`方法处理作为参数的连接上的请求。本文只是涉及到`IOLoop`方法的主体结构，而对不同请求的特定处理过程，则留待后文分析。因此，这要包括两个方面的处理逻辑，其一为`IOLoop`中的主循环，其负责等待请求并从连接上读取请求内容，并分析命令请求类型（典型包括`PUB`、`SUB`等），调用对应的请求处理函数。另一个异步循环为`protocolV2.messagePump`，此方法更为复杂，其核心逻辑为负责处理此`nsqd`所维护的`channel`发送消息的流程。下面分别进行介绍。

#### tcp 请求读取解析

针对每个客户端，在`IOLoop`方法中，它首先创建此客户端在`nsqd`服务端所代表的通信实体`clientV2`(`/nsq/nsqd/client_v2.go`)，并将其添加到`nsqd`所维护的`clients`集合。然后通过`messagePumpStartedChan`同步等待`messagePump`先执行，之所以要先等待，原因是`messagePump`方法会从`client`获取的一些属性，因此需避免与执行`IDENTIFY`命令的`client`产生数据竞争，即在`IOLoop`方法后面可能修改相关的当前`client`的数据。而`messagePump`先执行的的部分为获取`client`的部分属性，然后通知`IOLoop`主循环可以继续执行。在`IOLoop`主循环中，其首先阻塞等待在客户端的连接上，需要注意的是，若客户端设置了心跳间隔(`HeartbeatInterval`)，则若间隔超过`2*HeartbeatInterval `未收到客户端的消息，则会关闭连接。相反，若未设置心跳间隔，则读取操作永不超时。当读取并解析请求内容后，会调用`protocolV2.Exec`方法来根据命令请求的类型来针对性处理。最后，将结果返回给客户端。相关代码如下：

```go
// 针对连接到 nsqd 的每一个 client，都会单独在一个 goroutine 中执行这样一个 IOLoop请求处理循环
func (p *protocolV2) IOLoop(conn net.Conn) error {
	var err error
	var line []byte
	var zeroTime time.Time
	clientID := atomic.AddInt64(&p.ctx.nsqd.clientIDSequence, 1)
	client := newClientV2(clientID, conn, p.ctx)
	p.ctx.nsqd.AddClient(client.ID, client)
	// 1. 同步 messagePump 的启动过程，因为 messagePump会从client获取的一些属性
	// 而避免与执行 IDENTIFY 命令的 client 产生数据竞争，即当前client在后面可能修改相关的数据
	messagePumpStartedChan := make(chan bool)
	go p.messagePump(client, messagePumpStartedChan)
	<-messagePumpStartedChan
	// 2. 开始循环读取 client 的请求，然后解析参数并处理
	for {
		// 如果在与客户端协商 negotiation过程中，客户端设置了 HeartbeatInterval，
		// 则在正常通信情况下，若间隔超过 2*HeartbeatInterval 未收到客户端的消息，
		// 则关闭连接。
		if client.HeartbeatInterval > 0 {
			client.SetReadDeadline(time.Now().Add(client.HeartbeatInterval * 2))
		} else {
			// 若客户端未设置 HeartbeatInterval，则读取等待不会超时。
			client.SetReadDeadline(zeroTime)
		}
		// 2.1 读取命令请求，并对它进行解析，解析命令的类型及参数
		line, err = client.Reader.ReadSlice('\n')
		// ..
		line = line[:len(line)-1]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		params := bytes.Split(line, separatorBytes)
		p.ctx.nsqd.logf(LOG_DEBUG, "PROTOCOL(V2): [%s] %s", client, params)
		var response []byte
		// 2.2 执行命令
		response, err = p.Exec(client, params)
		// ..
		// 2.3 返回命令处理结果
		if response != nil {
			err = p.Send(client, frameTypeResponse, response)
			// ...
		}
	}
	p.ctx.nsqd.logf(LOG_INFO, "PROTOCOL(V2): [%s] exiting ioloop", client)
	conn.Close()
	close(client.ExitChan)
	if client.Channel != nil {
		client.Channel.RemoveClient(client.ID)
	}
	p.ctx.nsqd.RemoveClient(client.ID)
	return err
} // /nsq/nsqd/protocol_v2.go
```

#### 消息发送处理

消息发送处理流程即为`protocolV2.messagePump`方法。此方法先获取客户端的一些属性信息，然后通知`protocolV2.IOLoop`主循环继续执行。接下来进入主循环，主循环主要包括两个部分的逻辑。

其一是更新`memoryMsgChan`、`backendMsgChan`和`flusherChan`通道，这三个`channel`在后面的作用至关重要，另外就是是否需要将发送给客户端的内容进行显式刷新（`V2`版本协议采用了选择性地将返回给`client`的数据进行缓冲，以通过减少系统调用频率来提高效率）。而`memoryMsgChan`和`backendMsgChan`都是`nsqd`所维护的`channel`的属性（不是拷贝），一个代表的是内存的消息队列，另一个代表的是持久化存储的消息队列，`messagePump`通过这从这两个`channel`中接收消息，以执行发送消息的逻辑，关于这两个`channel`会在分析`channel`时详细阐述。

其二，阻塞等待从各个`channel`通道中取出消息，通过一个`select`操作进行组织：
- `flusherChan`表示需要进行显式地刷新（是一个`ticker`）；
- 而`ReadyStateChan`则表示客户端的消息处理能力发生了变化，其主要与消息处理状态相关，而在这里并没有对应的后续处理；
- `subEventChan`通道起到传递另外两个关键的通道相关，当客户端发送了`SUB`命令请求时，即请求订阅某个`topic`的某个`channel`时，对应的`channel`实例会被压入到此通道中（`SUB`方法的逻辑）；
- 类似的，`identifyEventChan`通道起到传递一些由客户端设置的一些参数的作用，这些参数包括`OutputBufferTimeout`、`HeartbeatInterval`、`SampleRate`以及`MsgTimeout`，它们是在客户端发出`IDENTIFY`命令请求时，被压入到`identifyEventChan`管道的。其中`OutputBufferTimeout`用于构建`flusherChan`定时刷新发送给客户端的消息数据，而`HeartbeatInterval`用于定时向客户端发送心跳消息，`SampleRate`则用于确定此次从`channel`中取出的消息，是否应该发送给此客户端，还记得在第一篇文章中所提到的对于多个客户端连接到同一个`channel`的情形，`channel`会将`topic`发送给它的消息随机发送给其中一个客户端，此处就体现了随机负载。最后的`MsgTimeout`则用于设置消息投递并被处理的超时时间，最后会被设置成`message.pri`作为消息先后发送顺序的依据；
- `heartbeatChan`的作用就比较明显了，定时向客户端发送心跳消息，由`HeartbeatInterval`确定；
- `backendMsgChan`，它是`channel`实例的一个关键属性，表示`channel实例`维护的持久化存储中的消息队列，当`channel`所接收到的消息的长度超过内存消息队列长度时，则将消息压入到持久化存储中的消息队列`backendMsgChan`。因此，当从此通道中收到消息时，表明有`channel`实例有消息需要发送给此客户端。它首先通过生成一个0到100范围内的随机数，若此随机数小于`SampleRate`则此消息会发送给此客户端，反之亦然。并更新消息尝试发送的次数`msg.Attempts`。然后，调用`channel`实例的`StartInFlightTimeout`将消息压入到`in-flight queue`中（代表正在发送的消息队列），等待被`queueScanWorker`处理。接下来，更新为此客户端保存的关于消息的计数信息（比如增加正在发送消息的数量）。最后将消息通过网络发送出去，并更新`flushed`表示可能需要更新了；
- `memoryMsgChan`和`backendMsgChan`的作用非常类似，只不过它表示的是内存消息队列。处理过程也一样；
- `client.ExitChan`表示当客户端退出时，则对应的处理循环也需要退出。

这部分的逻辑较为复杂，希望上述的分析能够帮助读者理解，先看下相关代码：

```go
// nsqd 针对每一个 client 的订阅消息的处理循环
func (p *protocolV2) messagePump(client *clientV2, startedChan chan bool) {
	var err error
	var memoryMsgChan chan *Message
	var backendMsgChan chan []byte
	var subChannel *Channel
	var flusherChan <-chan time.Time
	var sampleRate int32
	// 1. 获取客户端的属性
	subEventChan := client.SubEventChan
	identifyEventChan := client.IdentifyEventChan
	outputBufferTicker := time.NewTicker(client.OutputBufferTimeout)
	heartbeatTicker := time.NewTicker(client.HeartbeatInterval)
	heartbeatChan := heartbeatTicker.C
	msgTimeout := client.MsgTimeout
	// V2 版本的协议采用了选择性地将返回给 client 的数据进行缓冲，即通过减少系统调用频率来提高效率
	// 只有在两种情况下才采取显式地刷新缓冲数据
	// 		1. 当 client 还未准备好接收数据。
	// 			a. 若 client 所订阅的 channel 被 paused
	// 			b. client 的readyCount被设置为0，
	// 			c. readyCount小于当前正在发送的消息的数量 inFlightCount
	//		2. 当 channel 没有更多的消息给我发送了，在这种情况下，当前程序会阻塞在两个通道上
	flushed := true
	// 2. 向 IOLoop goroutine 发送消息，可以继续运行
	close(startedChan)
	for {// 1. 当前 client 未准备好接消息，原因包括 subChannel为空，即此客户端未订阅任何 channel
		// 或者客户端还未准备好接收消息，
		// 即 ReadyCount(通过 RDY 命令设置) <= InFlightCount  \
        // InFlightCount (已经给此客户端正在发送的消息的数量) 或 ReadyCount <= 0
		// 刚开始进入循环是肯定会执行这个分支
		if subChannel == nil || !client.IsReadyForMessages() {
			// the client is not ready to receive messages...
			// 初始化各个消息 channel
			memoryMsgChan = nil
			backendMsgChan = nil
			flusherChan = nil
			// 强制刷新缓冲区
			client.writeLock.Lock()
			err = client.Flush()
			client.writeLock.Unlock()
			if err != nil {
				goto exit
			}
			flushed = true
		} else if flushed {
			// 2. 表明上一个循环中，我们已经显式地刷新过
			// 准确而言，应该上从 client.SubEventChan 中接收到了 subChannel
            //（client订阅某个 channel 导致的）
			// 因此 初始化 memoryMsgChan 和 backendMsgChan 两个 channel，
            // 实际上这两个 channel 即为 client 所订阅的 channel的两个消息队列
			memoryMsgChan = subChannel.memoryMsgChan
			backendMsgChan = subChannel.backend.ReadChan()
			// 同时，禁止从 flusherChan 取消息，
            // 因为才刚刚设置接收消息的 channel，缓冲区不会数据等待刷新
			flusherChan = nil
		} else {
			// 3. 在执行到此之前，subChannel 肯定已经被设置过了，
            // 且已经从 memoryMsgChan 或 backendMsgChan 取出过消息
			// 因此，可以准备刷新消息发送缓冲区了，即设置 flusherChan
			memoryMsgChan = subChannel.memoryMsgChan
			backendMsgChan = subChannel.backend.ReadChan()
			flusherChan = outputBufferTicker.C
		}
		select {
		// 4. 定时刷新消息发送缓冲区
		case <-flusherChan:
			client.writeLock.Lock()
			err = client.Flush()
			client.writeLock.Unlock()
			if err != nil {
				goto exit
			}
			flushed = true
		// 5. 客户端处理消息的能力发生了变化，比如客户端刚消费了某个消息
		case <-client.ReadyStateChan:
		// 6. 发现 client 订阅了某个 channel，channel 是在 SUB命令请求方法中被压入的
		// 然后，将 subEventChan 重置为nil，重置为 nil原因表之后不能从此通道中接收到消息
		// 而置为nil的原因是，在SUB命令请求方法中第一行即为检查此客户端是否处于 stateInit 状态，
        // 而调用 SUB 了之后，状态变为 stateSubscribed
		case subChannel = <-subEventChan:
			// you can't SUB anymore
			subEventChan = nil
		// 7. 当 nsqd 收到 client 发送的 IDENTIFY 请求时，会设置此 client 的属性信息，
        // 然后将信息 push 到	identifyEventChan。
		// 因此此处就会收到一条消息，同样将 identifyEventChan 重置为nil，
		// 这表明只能从 identifyEventChan 通道中接收一次消息，因为在一次连接过程中，
        // 只允许客户端初始化一次
		// 在 IDENTIFY 命令处理请求中可看到在第一行时进行了检查，
        // 若此时客户端的状态不是 stateInit，则会报错。
		// 最后，根据客户端设置的信息，更新部分属性，如心跳间隔 heartbeatTicker
		case identifyData := <-identifyEventChan:
			// you can't IDENTIFY anymore
			identifyEventChan = nil
			outputBufferTicker.Stop()
			if identifyData.OutputBufferTimeout > 0 {
				outputBufferTicker = time.NewTicker(identifyData.OutputBufferTimeout)
			}
			heartbeatTicker.Stop()
			heartbeatChan = nil
			if identifyData.HeartbeatInterval > 0 {
				heartbeatTicker = time.NewTicker(identifyData.HeartbeatInterval)
				heartbeatChan = heartbeatTicker.C
			}
			if identifyData.SampleRate > 0 {
				sampleRate = identifyData.SampleRate
			}
			msgTimeout = identifyData.MsgTimeout
		// 8. 定时向所连接的客户端发送 heartbeat 消息
		case <-heartbeatChan:
			err = p.Send(client, frameTypeResponse, heartbeatBytes)
			if err != nil {
				goto exit
			}
		// 9. 从 backendMsgChan 队列中收到了消息
		case b := <-backendMsgChan:
			// 根据 client 在与 nsqd 建立连接后，第一次 client 会向 nsqd 发送 IDENFITY 请求 \
            // 以为 nsqd 提供 client 自身的信息。
			// 即为 identifyData，而 sampleRate 就包含在其中。
            // 换言之，客户端会发送一个 0-100 的数字给 nsqd。
			// 在 nsqd 服务端，它通过从 0-100 之间随机生成一个数字，  \
            // 若其大于 客户端发送过来的数字 sampleRate    \
			// 则 client 虽然订阅了此 channel，且此 channel 中也有消息了， \
            // 但是不会发送给此 client。
			// 这里就体现了 官方文档 中所说的，当一个 channel 被 client 订阅时，  \
            // 它会将收到的消息随机发送给这一组 client 中的一个。
			// 而且，就算只有一个 client，从程序中来看，也不一定能够获取到此消息，  \
            // 具体情况也与 client 编写的程序规则相关
			if sampleRate > 0 && rand.Int31n(100) > sampleRate {
				continue
			}
			// 将消息解码
			msg, err := decodeMessage(b)
			if err != nil {
				p.ctx.nsqd.logf(LOG_ERROR, "failed to decode message - %s", err)
				continue
			}
			// 递增消息尝试发送次数
            // 注意： 当消息发送的次数超过一定限制时，可由 client 自己在应用程序中做处理
			msg.Attempts++ 
			// 调用client 所订阅 channel 的 StartInFlightTimeout 方法，将消息压入发送队列
			subChannel.StartInFlightTimeout(msg, client.ID, msgTimeout)
			// 更新client 的关于正在发送消息的属性
			client.SendingMessage()
			// 正式发送消息到指定的 client
			err = p.SendMessage(client, msg)
			if err != nil {
				goto exit
			}
			// 重置 flused 变量
			flushed = false
		// 9. 从 memoryMsgChan 队列中收到了消息
		case msg := <-memoryMsgChan:
			if sampleRate > 0 && rand.Int31n(100) > sampleRate {
				continue
			}
			msg.Attempts++

			subChannel.StartInFlightTimeout(msg, client.ID, msgTimeout)
			client.SendingMessage()
			err = p.SendMessage(client, msg)
			if err != nil {
				goto exit
			}
			flushed = false
		// 10. 客户端退出
		case <-client.ExitChan:
			goto exit
		}
	}
exit:
	// ...
	heartbeatTicker.Stop()
	outputBufferTicker.Stop()
	// ...
} // /nsq/nsqd/protocol_v2.go
```

读者在理解这一段代码时，先可以看懂每一段代码的含义，然后进行一次“肉眼DEBUG”，即走一遍正常的代码处理流程（注意那些`channel`上的竞争条件）。这里，我简要阐述一下（`for`循环中的处理逻辑）：

- 首先刚开始肯定是进行第一个`if`执行，因为`subChannel == nil`且客户端也未准备好接收消息。注意此时会将各个`channel`，并刷新缓冲，而且将`flushed`设置为`true`；
- 然后，正常情况下，应该是`identifyEventChan`分支被触发，即客户端发送了`IDENTIFY`命令，此时，设置了部分`channel`。比如`heartbeatChan`，因此`nsqd`可以定期向客户端发送`hearbeat`消息了。并且`heartbeatChan`可能在下述的任何时刻触发，但都不影响程序核心执行逻辑；
- 此时，就算触发了`heartbeatChan`，上面的仍然执行第一个`if`分支，没有太多改变；
- 假如此时客户端发送了一个`SUB`请求，则此时`subEventChan`分支被触发，此时`subChannel`被设置，且`subEventChan`之后再也不能被触发。此时客户端的状态为`stateSubscribed`；
- 接下来，上面的代码执行的仍然是第一个`if`分支，因为此时`subChannel != nil`，但是客户端仍未准备好接收消息，即客户端的`ReadyCount`属性还未初始化；
- 按正常情况，此时客户端应该会发送`RDY`命令请求，设置自己的`ReadyCount`，即表示客户端能够处理消息的数量。
- 接下来，上面的代码总算可以执行第二个`if`分支，终于初始化了`memoryMsgChan`和`backendMsgChan`两个用于发送消息的消息队列了，同时将`flusherChan`设置为`nil`，显然，此时不需要刷新缓冲区；
- 此时，`ReadyStateChan`分支会被触发，因为客户端的消息处理能力确实发生了改化；
- 但`ReadyStateChan`分支的执行不影响上面代码中被触发的`if`分支，执行第二个分支。换言之，此时程序中涉及到的各属性没有发生变化；
- 现在，按正常情况终于要触发了`memoryMsgChan`分支，即有生产者向此`channel`所关联的`topic`投递了消息，因此`nsqd`将`channel`内存队列的消息发送给订阅了此`channel`的消费者。此时`flushed`为`false`；
- 接下来，按正常情况（假设客户端还可以继续消息消息，且消息消费未超时），上面代码应该执行第三个`if`分支，即设置两个消息队列，并设置`flusherChan`，因为此时确实可能需要刷新缓冲区了。
- 一旦触发了`flusherChan`分支，则`flushed`又被设置成`true`。表明暂时不需要刷新缓冲区，直到`nsqd`发送了消息给客户端，即触发了`memoryMsgChan`或`backendMsgChan`分支；
- 然后可能又进入第二个`if`分支，然后发送消息，刷新缓冲区，反复循环...
- 假如某个时刻，消费者的消息处理能力已经变为0了，则此时执行第一个`if`分支，两个消息队列被重置，执行强刷。显然，此时考虑到消费者已经不能再处理消息了，因此需要“关闭”消息发送的管道。

至此，`nsqd`其为客户端提供的`tcp`请求处理器相关的处理逻辑已经阐述完毕。内容比较多，因为笔者也阐述的比较详细，尽可能希望读者能够清晰整个流程。下面阐述`nsqd`为客户端提供的`http`请求处理器的相关逻辑。

### http 连接处理器

`http`连接处理器则相对简单很多，因为大部分内容已经由`httprouter`这个请求路由器完成了。我们简单看一下`http handler`的创建过程。同`nsqlookupd`创建`http handler`完全一样。首先设置了`httprouter`一些重要属性，然后构建`httpServer`实例，最后，调用`router.Handle`添加特定请求的处理器。关于具体请求的处理逻辑，后面会单开一篇文章来阐述。这里只涉及处理过程的框架。相关代码如下：

```go
// 同 nsqlookupd.httpServer 类似，参考 nsqlookupd/http.go 的源码注释
type httpServer struct {
	ctx         *context
	tlsEnabled  bool
	tlsRequired bool
	router      http.Handler
}
func newHTTPServer(ctx *context, tlsEnabled bool, tlsRequired bool) *httpServer {
	log := http_api.Log(ctx.nsqd.logf)
	router := httprouter.New()
	router.HandleMethodNotAllowed = true
	router.PanicHandler = http_api.LogPanicHandler(ctx.nsqd.logf)
	router.NotFound = http_api.LogNotFoundHandler(ctx.nsqd.logf)
	router.MethodNotAllowed = http_api.LogMethodNotAllowedHandler(ctx.nsqd.logf)
	s := &httpServer{
		ctx:         ctx,
		tlsEnabled:  tlsEnabled,
		tlsRequired: tlsRequired,
		router:      router,
	}
	router.Handle("GET", "/ping", http_api.Decorate(s.pingHandler, log, http_api.PlainText))
	router.Handle("GET", "/info", http_api.Decorate(s.doInfo, log, http_api.V1))
	// v1 negotiate
	router.Handle("POST", "/pub", http_api.Decorate(s.doPUB, http_api.V1))
	// only v1
	router.Handle("POST", "/topic/create", http_api.Decorate(s.doCreateTopic, log, http_api.V1))
	router.Handle("POST", "/channel/create", http_api.Decorate(s.doCreateChannel, log, http_api.V1))
    // ...
	// debug
	router.HandlerFunc("GET", "/debug/pprof/", pprof.Index)
	// ...
	return s
} // /nsq/nsqd/http.go
```

至此，`nsqd`服务启动相关的源码已经解析完毕了。整个文章非常长，读者能够看到这里实属不易。希望看完全文读者能够有所收获，源码分析也并不难。

最后，简单小结，本文从五个方面对`nsqd`服务启动相关的流程进行分析。具体地，其一，先以`nsqd`命令为切入点，简述服务启动流程；其二，紧追`nsqd`启动流程，进一步分析初始化过程中`NSQ`的创建及初始化相关逻辑；接下来，详细阐述`nsqd`异步开启`nsqlookupd`查询过程；其四，详细阐述了`nsqd`和`nsqlookupd`交互的主循环的逻辑。即第四点和第五点阐述的是`nsqd`与`nsqlookupd`交互部分；最后，分析了`nsqd`建立`tcp`和`http`请求处理器相关逻辑。其中，重点分析了`nsqd`为客户端（生产者和消费者）建立的`tcp`请求处理器，主要包括两个大的方面：`IOLoop`主循环主要是读取连接请求，调用对应的处理函数处理请求。另一个则是`messagePump`方法，其包含了`nsqd`处理消息发送的核心逻辑——即`nsqd`所维护的`channel`将消息发送给各个订阅了它的客户端，其涉及到的流程最为复杂。更详细内容可以参考笔者简要[注释的源码](https://github.com/qqzeng/nsqio/tree/master/nsq)。





参考文献

[1]. https://github.com/nsqio/nsq
[2]. https://nsq.io/overview/quick_start.html