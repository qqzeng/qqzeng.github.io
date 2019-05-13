---
title: nsq nsqlookupd 源码简析
date: 2019-05-12 10:17:39
categories:
- 消息队列
tags:
- 消息队列
- 分布式系统
---

上一篇文章简要介绍了`nsq`以及它的几个值得注意的特性，以对`nsq`有大体认识，并在整体上把握`nsq`的工作流程。这对于后面的源码分析工作会有帮助。本文重点阐述`nsqlookup`组件设计实现相关的源码。`nsqlookupd`是一个中心管理服务，负责管理集群(`nsqd`)的拓扑信息，并且为客户端（消费者）提供最终一致性的发现服务。具体而言，`nsqlookupd`用作解耦消费者和生产者(`nsqd`)。因为`nsqd`节点会将`topic`和`channel`的信息通过`tcp`广播到`nsqlookupd`节点（允许水平扩展）以实施服务注册，而客户端或`nsqadmin`通过`http`接口查询`nsqlookupd`来发现指定`topic`的生产者。引入`nsqlookupd`使得整个系统的模块更加清晰，且维护起来更加方便。值得注意的是，`nsqlookupd`本身对存储在其上的数据不做任何持久化。

<!--More-->

考虑到`nsqlookupd`本身所提供的功能比较简单，代码结构并不复杂，因此以`nsqlookupd`为分析入口。个人建议，查看或分析源码最好从某个业务逻辑流程切入，这样更具针对性，忽略某些旁支或细节，先从宏观上把握整个流程。按照惯例，读者可以自己`clone`源码进行分析。本文分析`nsqlookupd`关键流程，较为完整的[`nsq`源码注释](https://github.com/qqzeng/nsqio/tree/master/nsq)可在这里找到，其注释源码版本为`v1.1.0`，仅供参考。

本文主要从三个方面来阐述`nsqlookupd`：其一，以`nsqlookupd`命令为切入点，介绍其启动流程；其二，通过启动流程，继续追溯到`NSQLookupd`的创建及初始化过程。最后，阐述初始化过程中`tcp`和`http`请求处理器相关逻辑，并示例分析几个典型请求的详细处理逻辑，比如，`nsqd`通过`tcp`协议订阅`topic`。另外，`nsqd`通过`http`协议请求`nsqlookupd`执行`topic`的创建过程，以及客户端（消费者）请求`nsqlookupd`执行`topic`的查询过程。本文所涉及到源码主要为`/nsq/apps/nsqlookupd/`、`/nsq/nsqlookupd/`和`/nsq/internal/`下的若干子目录，`/nsq/apps`目录是官方提供的一些工具包，而`/nsq/nsqlookupd`会对应具体的实现，`/nsq/internal`则为`nsq`内部的核心（公共）库，目录结构比较简单，不多阐述。

当我们在命令行执行`nsqlookupd`命令时（同时可指定参数），相当于运行了`nsq/apps/nsqlookupd`程序的`main`方法。此方法启动了一个进程（服务），并且通过创建`NSQLookupd`并调用其`Main`方法执行启动逻辑。

## 利用 svc 启动进程

具体而言，其利用 [`svc`](https://github.com/judwhite/go-svc/svc)的`Run`方法启动一个进程（守护进程或服务），在 `svc.Run` 方法中依次调用 `Init` 和 `Start` 方法，`Init` 和 `Start` 方法都是 `no-blocking`的；`Run` 方法会阻塞直到接收到 `SIGINT`(程序终止信号，如`ctrl+c`)或`SIGTERM`（程序结束信号，如`kill -15 PID`），然后调用 `stop`方法后退出，这通过传递一个`channel`及感兴趣的信号集(`SIGINT&SGITERM`)给 `signal.Notify` 方法实现；`Run`方法中阻塞等待从`channel`中接收消息，一旦收到消息，则调用`stop`方法返回，进程退出。更多可以查看 `golang` 标准包的`signal.Notify`以及`svc`包是如何协助启动一个进程。相关代码如下：

```go
type program struct { // 代表此进程结构，包装了一个 nsqlookupd 实例
	once       sync.Once
	nsqlookupd *nsqlookupd.NSQLookupd
}

// nsqlookupd 服务程序执行入口
func main() 
	prg := &program{}
	// 1. 利用 svc 启动一个进程，在 svc.Run 方法中会依次调用 Init 和 Start 方法，Init 和 Start 方法都是 no-blocking的；
	// 2. Run 方法会阻塞直到接收到 SIGINT(程序终止)或SIGTERM(程序结束信号)，然后调用stop方法后退出；
	// 3. 这是通过传递一个 channel 及感兴趣信号集(SIGINT&SGITERM)给 signal.Notify 方法实现；
	// 4. Run方法中阻塞等待从 channel 中接收消息，一旦收到消息，则调用 stop 方法返回，进程退出。
	if err := svc.Run(prg, syscall.SIGINT, syscall.SIGTERM); err != nil {
		logFatal("%s", err)
	}
}

func (p *program) Init(env svc.Environment) error {// 初始化函数没有做实质性工作
	if env.IsWindowsService() {
		dir := filepath.Dir(os.Args[0])
		return os.Chdir(dir)
	}
	return nil
}

// Start 方法包含进程启动的主要执行逻辑
func (p *program) Start() error {
	// 1. 默认初始化 nsqlookupd 配置参数
	opts := nsqlookupd.NewOptions()
	// 2. 根据命令行传递的参数更新默认参数
	flagSet := nsqlookupdFlagSet(opts)
	flagSet.Parse(os.Args[1:])
	// 3. 输出版本号并退出
	if flagSet.Lookup("version").Value.(flag.Getter).Get().(bool) {
		fmt.Println(version.String("nsqlookupd"))
		os.Exit(0)
	}
	// 4. 解析配置文件获取用户设置参数
	var cfg map[string]interface{}
	configFile := flagSet.Lookup("config").Value.String()
	if configFile != "" {
		_, err := toml.DecodeFile(configFile, &cfg)
		if err != nil {
			logFatal("failed to load config file %s - %s", configFile, err)
		}
	}
	options.Resolve(opts, flagSet, cfg) // 5. 合并默认参数及配置文件中的参数
	nsqlookupd, err := nsqlookupd.New(opts) // 6. 创建 nsqlookupd 进程
	if err != nil {
		logFatal("failed to instantiate nsqlookupd", err)
	}
	p.nsqlookupd = nsqlookupd
	go func() { // 7. 执行 nsqlookupd 的主函数
		err := p.nsqlookupd.Main()
		if err != nil {
			p.Stop()
			os.Exit(1)
		}
	}()
	return nil
}

// 进程退出方法，注意使用 sync.Once 来保证 nsqlookupd.Exit 方法只被执行一次
func (p *program) Stop() error {
	p.once.Do(func() {
		p.nsqlookupd.Exit()
	})
	return nil
} // /nsq/apps/nsqlookupd.go
```

```go
// 使用 Run 方法来开启一个进程
func Run(service Service, sig ...os.Signal) error {
	env := environment{}
	if err := service.Init(env); err != nil { // 1.初始化环境，没什么实质性内容
		return err
	}
    if err := service.Start(); err != nil { // 2. 调用上面的 Start 方法来执行进程启动逻辑
		return err
	}
	if len(sig) == 0 {// 3. 默认响应 SIGINT和SIGTERM信号
		sig = []os.Signal{syscall.SIGINT, syscall.SIGTERM}
	}
    signalChan := make(chan os.Signal, 1) // 4. 调用 signalNotify 方法，使用阻塞等待信号产生
	signalNotify(signalChan, sig...)
	<-signalChan
	// 5. 在进程退出之前，调用 Stop 方法做清理工作
	return service.Stop()
} // /svc/svc/svc_other.go
```

代码中注释已经介绍得比较清晰，这里简单阐述下`Start`方法的逻辑：首先会通过默认参数创建配置参数实例`opts`，然后合并命令行参数及配置文件参数（若存在），接下来创建`nsqlookupd`实例，并调用`nsqlookupd.Main`函数，这是最关键的步骤。下面展开分析。

## NSQLookupd 启动初始化

在介绍构造方法前，先贴出`NSQLookupd`结构：

```go
type NSQLookupd struct {
	sync.RWMutex                       // 读写锁
	opts         *Options              // 参数配置信息
	tcpListener  net.Listener          // tcp 监听器用于监听 tcp 连接
	httpListener net.Listener          // 监听 http 连接
    // sync.WaitGroup 增强体，功能类似于 sync.WaitGroup，一般用于等待所有的 goroutine 全部退出
	waitGroup    util.WaitGroupWrapper 
    DB           *RegistrationDB       // 生产者注册信息(topic、channel及producer) DB
}
```

构造方法中并没有太多逻辑，启用了日志输出，并构建`NSQLookupd`结构实例，然后开启了`tcp`和`http`连接的监听。代码如下所示（省去了一些错误处理及其它无关紧要的代码片段）：

```go
// 创建 NSQLookupd 实例
func New(opts *Options) (*NSQLookupd, error) {
	var err error
	// 1. 启用日志输出
	if opts.Logger == nil {
		opts.Logger = log.New(os.Stderr, opts.LogPrefix, log.Ldate|log.Ltime|log.Lmicroseconds)
	}
	// 2. 创建 NSQLookupd 实例
	l := &NSQLookupd{
		opts: opts, // 配置参数实例
		DB:   NewRegistrationDB(), // topic、channel及producer的存储，一个 map 实例
	}
	// 3. 版本号等信息
	l.logf(LOG_INFO, version.String("nsqlookupd"))
	// 4. 开启 tcp 和 http 连接监听
	l.tcpListener, err = net.Listen("tcp", opts.TCPAddress)
	// ...
	l.httpListener, err = net.Listen("tcp", opts.HTTPAddress)
	// ...
	return l, nil
}
```

下面重点介绍其`Main`启动方法，即启动一个`NSQLookupd`实例，具体逻辑比较简单：构建了一个`Context`实例，它纯粹只是一个`NSQLookupd`实例的`wrapper`。然后注册了进程退出前需要执行的`hook`函数。关键步骤为创建用于处理`tcp`和`http`连接的`handler`，同时异步开启`tcp`和`http`连接的监听动作，最后通过一个`channel`阻塞等待方法退出，详细代码逻辑如下：

```go
// 启动 NSQLookupd 实例
func (l *NSQLookupd) Main() error {
	// 1. 构建 Context 实例， Context 是 NSQLookupd 的一个 wrapper
	ctx := &Context{l}
	// 2. 创建进程退出前需要执行的 hook 函数
	exitCh := make(chan error)
	var once sync.Once
	exitFunc := func(err error) {
		once.Do(func() {
			if err != nil {
				l.logf(LOG_FATAL, "%s", err)
			}
			exitCh <- err
		})
	}
	// 3. 创建用于处理 tcp 连接的 handler，并开启 tcp 连接的监听动作
    // tcp协议处理函数其实是 LookupProtocolV1.IOLoop, 它支持 IDENTIFY、REGISTER及UNREGISTER等命令请求的处理
	tcpServer := &tcpServer{ctx: ctx}
	l.waitGroup.Wrap(func() {
		// 3.1 在 protocol.TCPServer 方法中统一处理监听
		exitFunc(protocol.TCPServer(l.tcpListener, tcpServer, l.logf))
	})
	// 4. 创建用于处理 http 连接的 handler，并开启 http 连接的监听动作
    // 而 http连接处理，它利用了 httpServer，一个高效的请求路由库
	httpServer := newHTTPServer(ctx)
	l.waitGroup.Wrap(func() {
		exitFunc(http_api.Serve(l.httpListener, httpServer, "HTTP", l.logf))
	})
	// 5. 阻塞等待错误退出
	err := <-exitCh
	return err
}

// NSQLookupd 服务退出方法中，关闭了网络连接，并且需等待 hook 函数被执行
func (l *NSQLookupd) Exit() {
	if l.tcpListener != nil {
		l.tcpListener.Close()
	}
	if l.httpListener != nil {
		l.httpListener.Close()
	}
	l.waitGroup.Wait()
} // /nsq/nsqlookupd/nsqlookupd.go
```

## tcp & http 请求处理

`Main`方法中关键代码为构建`tcp`及`http`请求的`handler`，并异步调用它们以处理请求。

### 客户端 tcp 请求处理

其中`tcp`请求的`handler`比较简单：直接使用标准库的`tcp`相关函数，在一个单独的`goroutine`中启用了`tcp handler`。对于监听到每一个连接，开启一个额外的`goroutine`来处理请求。相关代码如下：

```go
// tcp 连接处理器，只是一个统一的入口，当 accept 到一个连接后，将此连接交给对应的 handler 处理
type TCPHandler interface {
	Handle(net.Conn)
}
func TCPServer(listener net.Listener, handler TCPHandler, logf lg.AppLogFunc) error {
	logf(lg.INFO, "TCP: listening on %s", listener.Addr())
	for {
		clientConn, err := listener.Accept()
		// ...
		// 针对每一个连接到 nsqd 的 client，会单独开启一个 goroutine 去处理
        // 实际上是由 /nsq/nsqlookupd/tcp.go 中的 tcpServer.Handle 方法处理
		go handler.Handle(clientConn)
	}
	logf(lg.INFO, "TCP: closing %s", listener.Addr())
	return nil
} // /nsq/internal/protocol/tcp_server.go
```

对于`accpet`到的每一个连接，都交给了`tcpServer.Handle`方法异步处理。需要注意的是`tcpServer.Handle`只是对连接进行初步处理，不涉及到具体的业务逻辑。其主要是验证客户端使用的协议版本，然后就调用`lookup_protocol_v1.go`中的`LookupProtocolV1.IOLoop`方法处理。相关代码如下：

```go
// tcp 连接 handler。 Context/NSQLookupd 的一个 wrapper
type tcpServer struct {
	ctx *Context
}

func (p *tcpServer) Handle(clientConn net.Conn) {
	p.ctx.nsqlookupd.logf(LOG_INFO, "TCP: new client(%s)", clientConn.RemoteAddr())
	// 在 client 同 NSQLookupd 正式通信前，需要发送一个 4byte 的序列号，以商定协议版本
	buf := make([]byte, 4)
	_, err := io.ReadFull(clientConn, buf)
	// ...
	protocolMagic := string(buf)
	p.ctx.nsqlookupd.logf(LOG_INFO, "CLIENT(%s): desired protocol magic '%s'",
		clientConn.RemoteAddr(), protocolMagic)
	var prot protocol.Protocol
	switch protocolMagic {
	// 构建 LookupProtocolV1 来真正处理连接的业务请求
	case "  V1":
		prot = &LookupProtocolV1{ctx: p.ctx}
	default:
		// 只支持V1版本，否则发送 E_BAD_PROTOCOL，关闭连接
		protocol.SendResponse(clientConn, []byte("E_BAD_PROTOCOL"))
		clientConn.Close()
		// ...
        return
	}
	// 调用 prot.IOLoop 方法循环处理指定连接的请求
	err = prot.IOLoop(clientConn)
	// ...
}
```

在`LookupProtocolV1.IOLoop`方法中，它开启了一个循环，为每一个连接创建对应的`client`（`/nsq/nsqlookupd/client_v1`的`ClientV1`）实例，然后读取请求内容，解析请求参数，并调用`Exec`方法执行请求，最后将结果返回，而在连接关闭时，它会清除`client`（其实代指的是`nsqd`实例）在`NSQLookupd`注册的信息（包括`topic`、`channel`和`producer`等）。相关代码如下：

```go
// LookupProtocolV1： Context/NSQLookupd 的一个 wrapper。是 protocol.Protocol 的一个实现。
// nsqd 使用 tcp 接口来广播
type LookupProtocolV1 struct {
	ctx *Context
}

func (p *LookupProtocolV1) IOLoop(conn net.Conn) error {
	var err error
	var line string
	// 1. 先创建客户端实例，并构建对应的 reader
	client := NewClientV1(conn)
	reader := bufio.NewReader(client)
	for {
		// 2. 读取一行内容，并分离出参数信息
		line, err = reader.ReadString('\n')
		// ...
		line = strings.TrimSpace(line)
		params := strings.Split(line, " ")
		// 3. 调用 Exec 方法获取响应内容
		var response []byte
		response, err = p.Exec(client, reader, params)
		// 4. Exec 方法执行失败，返回对应的异常信息
        // ...
		// 5. 执行成功，则返回响应内容
		if response != nil {
			_, err = protocol.SendResponse(client, response)
			// ...
		}
	}
	// 6. 连接关闭时，清除  client(nsqd) 在 NSQLookupd 注册的信息
	conn.Close()
	p.ctx.nsqlookupd.logf(LOG_INFO, "CLIENT(%s): closing", client)
	if client.peerInfo != nil {
		registrations := p.ctx.nsqlookupd.DB.LookupRegistrations(client.peerInfo.id)
		for _, r := range registrations {
			if removed, _ := p.ctx.nsqlookupd.DB.RemoveProducer(
                r, client.peerInfo.id); removed {
				p.ctx.nsqlookupd.logf(LOG_INFO, 
                    "DB: client(%s) UNREGISTER category:%s key:%s subkey:%s",
					client, r.Category, r.Key, r.SubKey)
			}
		}
	}
	return err
}
```

先了解`Exec`如何处理请求的。其实比较简单，对于通过`tcp`连接所发送请求，只支持`PING`、`IDENTIFY`、`REGISTER`和`UNREGISTER`这四种类型。针对每一种类型的请求，分别调用它们所关联的请求处理函数。如下：

```go
func (p *LookupProtocolV1) Exec(client *ClientV1, reader *bufio.Reader, 
                                params []string) ([]byte, error) {
	switch params[0] {
	case "PING":
		return p.PING(client, params)
	case "IDENTIFY":
		return p.IDENTIFY(client, reader, params[1:])
	case "REGISTER":
		return p.REGISTER(client, reader, params[1:])
	case "UNREGISTER":
		return p.UNREGISTER(client, reader, params[1:])
	}
	return nil, protocol.NewFatalClientErr(nil, "E_INVALID", 
                fmt.Sprintf("invalid command %s", params[0]))
}
```

在介绍具体的请求处理逻辑前，先介绍一下在构建`NSQLookupd`实例时，构建的`RegistrationDB`实例，因为它代表了客户端往`nsqlookupd`所注册信息的存储或容器。其实质上是一个`map`结构，其中`key`为`Registration`，值为`ProduceMap(map[string]*Producer)`。且`Registration`主要包含了`topic`和`channel`的信息，而`ProduceMap`则包含了生产者(`nsqd`)的信息。因此，围绕`RegistrationDB`的操作也比较简单，即对相关的数据的`CRUD`操作。相关代码如下：

```go
// NSQLookupd 的注册信息DB，即为 nqsd 的注册信息
type RegistrationDB struct {
	sync.RWMutex			// guards registrationMap
	registrationMap map[Registration]ProducerMap
}
type Registration struct {
	Category string 		// client|channel|topic
	Key      string			// topic
	SubKey   string			// channel
}
type Registrations []Registration
// PeerInfo 封装了 client/sqsd 中与网络通信相关的字段，即client 在 NSQLookupd 端的逻辑视图
type PeerInfo struct {
	lastUpdate       int64		// nsqd 上一次向 NSQLookupd 发送心跳的 timestamp
	id               string			// nsqd 实例的 id
	RemoteAddress    string `json:"remote_address"`		// ip 地址
	Hostname         string `json:"hostname"`			// 主机名
	BroadcastAddress string `json:"broadcast_address"`	// 广播地址
	TCPPort          int    `json:"tcp_port"`			// TCP 端口
	HTTPPort         int    `json:"http_port"`			// http 端口
	Version          string `json:"version"`			// nsqd 版本号
}
type Producer struct {
	peerInfo     *PeerInfo		// client/nsqd 的 PeerInfo
	tombstoned   bool			// 标记 nsqd 是否被逻辑删除
	tombstonedAt time.Time		// 若被逻辑删除，则记录时间戳
}
type Producers []*Producer
type ProducerMap map[string]*Producer
// /nsq/nsqlookupd/registration_db.go

// 当 nsqd 创建topic或channel时，需要将其注册到 NSQLookupd 的 DB 中
func (r *RegistrationDB) AddRegistration(k Registration) 

// 添加一个 Producer 到 registration 集合中，返回此 Producer 之前是否已注册
func (r *RegistrationDB) AddProducer(k Registration, p *Producer) bool 

// 从 Registration 对应的 ProducerMap 移除指定的 client/peer
func (r *RegistrationDB) RemoveProducer(k Registration, id string) (bool, int) 

// 删除 DB 中指定的 Registration 实例（若此 channel 为 ephemeral，
// 则当其对应的 producer/client 集合为空时，会被移除）所对应的 producerMap
func (r *RegistrationDB) RemoveRegistration(k Registration)

// 根据 category、key和 subkey 来查找 Registration 集合。注意 key 或 subkey 中可能包含 通配符*
func (r *RegistrationDB) FindRegistrations(category string, key string, subkey string) Registrations 

// 根据 category、key和 subkey 来查找 Producer 集合。注意 key 或 subkey 中可能包含 通配符*
func (r *RegistrationDB) FindProducers(category string, key string, subkey string) Producers

// 根据 peer id 来查找 Registration 集合。
func (r *RegistrationDB) LookupRegistrations(id string) Registrations 
// /nsq/nsqlookupd/registration_db.go
```

接下来具体介绍各具体的命令请求是如下处理的，其中`PING`命令用于维持`nsqd`与`nsqlookupd`实例之间的连接通信，其处理也比较简单，更新一下此客户端的活跃时间`lastUpdate`，并回复`OK`。当我们使用`nsqd --lookupd-tcp-address=127.0.0.1:4160`启动一个`nsqd`实例时，它会在它的`Main`方法中使用一个额外的`goroutine`来开启`lookupd`扫描。当第一次执行时，它会向它知道的`nsqlookupd`地址（通过配置文件或命令行指定）建立连接。当`nsqd`与`nsqlookupd`连接建立成功后，会向`nsqlookupd`发送一个`MagicV1`的命令请求以校验目前自己所使用的协议版本，然后，会向`nsqlookupd`发送一个`IDENTIFY`命令请求，以认证自己身份，在此处理方法中会将客户端构造成`Producer`添加到`RegistrationDB`，并且返回自己的一些信息，当`nsqd`收到这些信息后，会遍历自己所有的`topic`，针对每一个`topic`，若其没有关联的`channel`，则发送只包含`topic`的`REGISTER`命令请求，否则还会遍历`topic`所关联的`channel`集合，针对每一个`channel`，发送一个包含`topic`和`channel`的`REGISTER`命令。所谓的`REGISTER`命令请求表示`nsqd`向 `nsqlookupd` 发送注册 `topic`的请求，当`nsqlookupd`收到`REGISTER`命令请求时，且若消息中带有`channel`时，会为此客户端会注册两个`producer`，即分别针对`channel`和`topic`构建。注意，在这里个人对`nsqd`启动后与`nsqdlookupd`建立连接以及`REGISTER`的过程阐述得比较详细，希望读者能够对一个二者的交互有一个全局的把握，但这里面涉及到`nsqd`启动的过程，会在后续的文章中详细阐述。而各命令请求处理逻辑则比较简单：

```go
// PING 消息： client 在发送其它命令之前，可能会先发送一个 PING 消息。
func (p *LookupProtocolV1) PING(client *ClientV1, params []string) ([]byte, error) {
	if client.peerInfo != nil {
		// we could get a PING before other commands on the same client connection
		cur := time.Unix(0, atomic.LoadInt64(&client.peerInfo.lastUpdate))
		now := time.Now()
		// 打印 PING 日志
		p.ctx.nsqlookupd.logf(LOG_INFO, "CLIENT(%s): pinged (last ping %s)", client.peerInfo.id,
			now.Sub(cur))
		// 更新上一次PING的时间
		atomic.StoreInt64(&client.peerInfo.lastUpdate, now.UnixNano())
	}
	// 回复 OK
	return []byte("OK"), nil
}  // /nsq/nsqlookup/lookup_protocol_v1.go

// client 向 NSQLookupd 发送认证身份的消息。 注意在此过程中会将客户端构造成Producer添加到 Registration DB中。
func (p *LookupProtocolV1) IDENTIFY(client *ClientV1, reader *bufio.Reader, 
                                    params []string) ([]byte, error) {
	var err error

	// 1. client 不能重复发送 IDENTIFY 消息
	if client.peerInfo != nil {
		return nil, protocol.NewFatalClientErr(err, "E_INVALID", "cannot IDENTIFY again")
	}
	// 2. 读取消息体的长度
	var bodyLen int32
	err = binary.Read(reader, binary.BigEndian, &bodyLen)
	// ...
	// 3. 读取消息体内容，包含生产者的信息
	body := make([]byte, bodyLen)
	_, err = io.ReadFull(reader, body)
	// ...
	// 4. 根据消息体构建 PeerInfo 实例
	peerInfo := PeerInfo{id: client.RemoteAddr().String()}
	err = json.Unmarshal(body, &peerInfo)
	// ...
	peerInfo.RemoteAddress = client.RemoteAddr().String()
	// 5. 检验属性不能为空，同时更新上一次PING的时间
	if peerInfo.BroadcastAddress == "" || peerInfo.TCPPort == 0 
    || peerInfo.HTTPPort == 0 || peerInfo.Version == "" {
		return nil, protocol.NewFatalClientErr(nil, "E_BAD_BODY", "IDENTIFY missing fields")
	}
	atomic.StoreInt64(&peerInfo.lastUpdate, time.Now().UnixNano())
	// 6. 将此 client 构建成一个 Producer 注册到 DB中
	client.peerInfo = &peerInfo
	if p.ctx.nsqlookupd.DB.AddProducer(Registration{"client", "", ""},
                                       &Producer{peerInfo: client.peerInfo}) {
		p.ctx.nsqlookupd.logf(LOG_INFO, "DB: client(%s) REGISTER category:%s key:%s subkey:%s", client, "client", "", "")
	}
	// 7. 构建响应消息，包含 NSQLookupd 的 hostname、port及 version
	data := make(map[string]interface{})
	data["tcp_port"] = p.ctx.nsqlookupd.RealTCPAddr().Port
	data["http_port"] = p.ctx.nsqlookupd.RealHTTPAddr().Port
	data["version"] = version.Binary
	hostname, err := os.Hostname()
	if err != nil {
		log.Fatalf("ERROR: unable to get hostname %s", err)
	}
	data["broadcast_address"] = p.ctx.nsqlookupd.opts.BroadcastAddress
	data["hostname"] = hostname
	response, err := json.Marshal(data)
	// ...
	return response, nil
}  // /nsq/nsqlookup/lookup_protocol_v1.go

//  Client 向 NSQLookupd 发送取消注册/订阅 topic 的消息。即为 REGISTER 的逆过程
func (p *LookupProtocolV1) UNREGISTER(client *ClientV1, reader *bufio.Reader, 
                                      params []string) ([]byte, error) {
	// 1. 必须先要发送 IDENTIFY 消息进行身份认证
	if client.peerInfo == nil {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "client must IDENTIFY")
	}
	// 2. 获取 client 注册的 topic 和 channel(若有的话)
	topic, channel, err := getTopicChan("UNREGISTER", params)
	// ...
	// 3. 若 channel 不为空，则在 DB 中移除一个 Producer 实例，
    // 其键(Category)为 channel 类型的 Registration。
	if channel != "" {
		key := Registration{"channel", topic, channel}
		removed, left := p.ctx.nsqlookupd.DB.RemoveProducer(key, client.peerInfo.id)
		// ...
		// 对于 ephemeral 类型的 channel，
        // 若它未被任何 Producer 订阅，则需要移除此 channel 代表的 Registration 对象
		// for ephemeral channels, remove the channel as well if it has no producers
		if left == 0 && strings.HasSuffix(channel, "#ephemeral") {
			p.ctx.nsqlookupd.DB.RemoveRegistration(key)
		}
	} else {
		// 4. 取消注册 topic。因此它会删除掉 类型(Category)为 channel 
        // 且 Key 为 topic 且 subKey不限的　Registration 集合；
		// 也会删除 Category 为 topic 且 Key 为 topic且 subKey为""的　Registration集合
		registrations := p.ctx.nsqlookupd.DB.FindRegistrations("channel", topic, "*")
		for _, r := range registrations {
			removed, _ := p.ctx.nsqlookupd.DB.RemoveProducer(r, client.peerInfo.id)
			// ...
		key := Registration{"topic", topic, ""}
		removed, left := p.ctx.nsqlookupd.DB.RemoveProducer(key, client.peerInfo.id)
		// ...
		// 同样，对于 ephemeral 类型的 topic，若它没有被任何 Producer 订阅，
            // 则需要移除此 channel 代表的 Registration 对象。
		if left == 0 && strings.HasSuffix(topic, "#ephemeral") {
			p.ctx.nsqlookupd.DB.RemoveRegistration(key)
		}
	}
	return []byte("OK"), nil
} // /nsq/nsqlookup/lookup_protocol_v1.go
```

#### tcp 请求 REGISTER 处理过程

这里简要阐述`REGISTER`请求处理的过程：当`nsqlookupd`收到`REGISTER`命令请求后，它首先确认对方是否已经发送过`IDENTIFY`命令请求，确认完成后，解析请求中的`topic`名称和`channel`名称，然后，进一步检查`topic`和`channel`命名的合法性，最后若`channel`不为空，则向`RegistrationDB`中添加一个`Producer` 实例，其`Category`为`channel`类型的`Registration`。同样，若`topic`不为空，则还需要向`RegistrationDB`中添加一个`Producer`实例，其`Category`为` topic` 类型的 `Registration`。最后返回`OK`。

```go
//  Client 向 NSQLookupd 发送注册 topic 的消息。注意，当消息中带有 channel 时，
// 对于此 client会注册两个 producer，分别针对 channel 和 topic
func (p *LookupProtocolV1) REGISTER(client *ClientV1, reader *bufio.Reader, 
                                    params []string) ([]byte, error) {
	// 1. 必须先要发送 IDENTIFY 消息进行身份认证。
	if client.peerInfo == nil {
		return nil, protocol.NewFatalClientErr(nil, "E_INVALID", "client must IDENTIFY")
	}
	// 2. 获取 client 注册的 topic 和 channel(若有的话)
	topic, channel, err := getTopicChan("REGISTER", params)
	// ...
	// 3. 若 channel 不为空，则向 DB 中添加一个 Producer 实例，其键(Category)为 channel 类型的 Registration
	if channel != "" {
		key := Registration{"channel", topic, channel}
		if p.ctx.nsqlookupd.DB.AddProducer(key, &Producer{peerInfo: client.peerInfo}) {
			p.ctx.nsqlookupd.logf(
                LOG_INFO, "DB: client(%s) REGISTER category:%s key:%s subkey:%s",
				client, "channel", topic, channel)
		}
	}
	// 4. 若 topic 不为空，则还需要向 DB 中添加一个 Producer 实例，其键(Category)为 topic 类型的 Registration
	key := Registration{"topic", topic, ""}
	if p.ctx.nsqlookupd.DB.AddProducer(key, &Producer{peerInfo: client.peerInfo}) {
		p.ctx.nsqlookupd.logf(
            LOG_INFO, "DB: client(%s) REGISTER category:%s key:%s subkey:%s",
			client, "topic", topic, "")
	}
	// 5. 返回 OK
	return []byte("OK"), nil
}  // /nsq/nsqlookup/lookup_protocol_v1.go
```

需要注意的是，这几个接口都是`tcp`连接请求的对应的处理函数，并非是`http`请求（可以通过命令行的方式发起）所对应的处理函数。`nsq`官方提供了一个`go-nsq`的客户端库。我们可以通过这个库来显式调试这些命令请求处理函数，当然源码包下也有对应的测试文件`/nsq/nsqlookupd/nsqlookupd_test.go`。到此为止通过`tcp`协议发起的请求的处理逻辑已经阐述完毕。下面介绍`http`协议的请求处理逻辑。

### 客户端 http 请求处理

前面提到，在`NSQLookupd.Main`方法中，同样创建了一个`http`请求处理器`httpServer`，并设置了请求的监听器`http_api.Serve`。它们的功能及用法可以[参考这里](https://nsq.io/components/nsqlookupd.html)。我们先来简单了解`http`请求的监听器是怎样工作的。很简单，它同样使用的是标准库中的`http`相关的接口，即调用`server.Serve`函数监听连接请求，但其采用的是自定义的`handler`，即前方所提到的`httprouter`来作为请求路由处理器。相关代码如下：

```go
// http 连接处理器，类似于 tcp_server 只是一个统一的入口，具体监听动作是在标准包 http.Server.Serve 方法中完成
func Serve(listener net.Listener, handler http.Handler, proto string, logf lg.AppLogFunc) error {
	logf(lg.INFO, "%s: listening on %s", proto, listener.Addr())
	server := &http.Server{
		Handler:  handler,
		ErrorLog: log.New(logWriter{logf}, "", 0),
	}
	err := server.Serve(listener)
	// ...
	logf(lg.INFO, "%s: closing %s", proto, listener.Addr())
	return nil
}
```

而`http`请求处理的重点在于`http`请求的路由器，即`/nsq/nsqlookupd/http.go`中所定义的`httpServer`，其仅仅是[`httprouter`](https://github.com/julienschmidt/httprouter)的一个`wrapper`。关于`httprouter`具体工作原理，读者可以阅读源码（比较短）或参考其它文章。这里简要介绍一下`httpServer`实例化的过程，首先会创建`httprouter`实例，然后设置参数信息，比如对于`403`、`404`和`500`等错误的`handler`。接下来，构建`httpServer`实例，然后通过`httprouter`实例来添加特定的路由规则。各具体的请求处理器也比较简单，纯粹就调用`RegistrationDB`相关接口，不多阐述，读者可深入源码查看。最后，值得学习的是，程度采用装饰者模式构建强大且灵活的请求处理器。相关代码如下：

```go
// http 连接的 handler。
// 客户端（消费者）使用这些 http　接口来发现和管理。
// 实现了 http.Handler 接口，实现了 ServeHTTP(ResponseWriter, *Request) 处理函数
type httpServer struct {
	ctx    *Context
	router http.Handler
}

// http 请求处理器构造函数
func newHTTPServer(ctx *Context) *httpServer {
	log := http_api.Log(ctx.nsqlookupd.logf)
	// 1. 创建 httprouter 实例。httprouter是一个高效的请求路由器，使用了一个后缀树来存储路由信息。
	// 更多 https://github.com/julienschmidt/httprouter 或参考博客 https://learnku.com/articles/27591
	router := httprouter.New()
	// 2. 配置参数信息
	router.HandleMethodNotAllowed = true
	router.PanicHandler = http_api.LogPanicHandler(ctx.nsqlookupd.logf)
	router.NotFound = http_api.LogNotFoundHandler(ctx.nsqlookupd.logf)
	router.MethodNotAllowed = http_api.LogMethodNotAllowedHandler(ctx.nsqlookupd.logf)
	// 3. 对此 httprouter 进行包装，构建 httpServer 实例
	s := &httpServer{
		ctx:    ctx,
		router: router,
	}
	// 4. 为 httprouter 实例添加特定路由规则
	// 对于 PING 请求而言，其 handler 为调用 Decorate 后的返回值，
	// 以 pingHandler 作为被装饰函数，可变的装饰参数列表为 log, http_api.PlainText（用于返回纯文本内容）
	// 后面的程序结构类似
	router.Handle("GET", "/ping", http_api.Decorate(s.pingHandler, log, http_api.PlainText))
	router.Handle("GET", "/info", http_api.Decorate(s.doInfo, log, http_api.V1))

	// v1 negotiate
	router.Handle("GET", "/debug", http_api.Decorate(s.doDebug, log, http_api.V1))
	router.Handle("GET", "/lookup", http_api.Decorate(s.doLookup, log, http_api.V1))
	router.Handle("GET", "/topics", http_api.Decorate(s.doTopics, log, http_api.V1))
	router.Handle("GET", "/channels", http_api.Decorate(s.doChannels, log, http_api.V1))
	router.Handle("GET", "/nodes", http_api.Decorate(s.doNodes, log, http_api.V1))

	// only v1
	router.Handle("POST", "/topic/create", http_api.Decorate(s.doCreateTopic, log, http_api.V1))
	router.Handle("POST", "/topic/delete", http_api.Decorate(s.doDeleteTopic, log, http_api.V1))
	router.Handle("POST", "/channel/create", http_api.Decorate(s.doCreateChannel, log, http_api.V1))
	router.Handle("POST", "/channel/delete", http_api.Decorate(s.doDeleteChannel, log, http_api.V1))
	router.Handle("POST", "/topic/tombstone", http_api.Decorate(s.doTombstoneTopicProducer, log, http_api.V1))

	// debug
	router.HandlerFunc("GET", "/debug/pprof", pprof.Index)
	// ...
	return s
} // /nsq/nsqlookupd/http.go

func (s *httpServer) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	s.router.ServeHTTP(w, req)
}

// PING 请求处理器
func (s *httpServer) pingHandler(w http.ResponseWriter, req *http.Request, 
                                 ps httprouter.Params) (interface{}, error) 

// INFO（版本信息）查询请求处理器
func (s *httpServer) doInfo(w http.ResponseWriter, req *http.Request, 
                            ps httprouter.Params) (interface{}, error)

// 查询所有 Category 为 topic的 Registration 的集合所包含的 Key 集合（topic名称集合）
func (s *httpServer) doTopics(w http.ResponseWriter, req *http.Request, 
                              ps httprouter.Params) (interface{}, error)

// 查询所有 Category 为 channel，
// 且 topic 为请求参数中指定的 topic 的 Registration 的集合包含的 SubKey 集合（channel名称集合）
func (s *httpServer) doChannels(w http.ResponseWriter, req *http.Request, 
                                ps httprouter.Params) (interface{}, error) 

// 查询所有 Category 为 topic的 channels 的集合以及producers集合。
func (s *httpServer) doLookup(w http.ResponseWriter, req *http.Request, 
                              ps httprouter.Params) (interface{}, error) 

// 根据 topic 来添加注册信息 Registration
func (s *httpServer) doCreateTopic(w http.ResponseWriter, req *http.Request, 
                                   ps httprouter.Params) (interface{}, error)

// 根据 topic 来删移除注册信息 Registration
func (s *httpServer) doDeleteTopic(w http.ResponseWriter, req *http.Request, 
                                   ps httprouter.Params) (interface{}, error) 

// 为指定 topic 关联的 producer 设置为 tombstone 状态。
func (s *httpServer) doTombstoneTopicProducer(w http.ResponseWriter, req *http.Request, 
                    ps httprouter.Params) (interface{}, error) 

// 根据 topic 和 channel 的名称添加注册信息
func (s *httpServer) doCreateChannel(w http.ResponseWriter, 
                                     req *http.Request, ps httprouter.Params) (interface{}, error)

// 根据 topic 和 channel 的名称移除注册信息
func (s *httpServer) doDeleteChannel(w http.ResponseWriter, req *http.Request, 
                                     ps httprouter.Params) (interface{}, error) 
// /nsq/nsqlookupd/http.go
```

#### http 请求 topic 创建/查询处理过程

最后，笔者简要介绍，消费者请求`nsqlookupd`的完成的请求服务。比如，当消费者需要查询某个`topic`在哪些`nsqd`上时，它可以通过`/lookup`的`http GET`请求来查询结果，`nsqlookupd`所提供的查询的指定`topic`信息的接口为：`curl 'http://127.0.0.1:4161/lookup?topic=test-topic'`，从返回结果为此`topic`所关联的`channels`列表和`producer`列表。其具体处理流程不再阐述，比较简单，其详细代码如下：

```go
// 查询所有 Category 为 topic的 channels 的集合以及producers集合。
func (s *httpServer) doLookup(w http.ResponseWriter, req *http.Request, 
                              ps httprouter.Params) (interface{}, error) {
	reqParams, err := http_api.NewReqParams(req) // 1. 解析请求参数
	// ...
	topicName, err := reqParams.Get("topic") // 2. 获取请求查询的 topic
	// ...
    // 3. 根据 topic 查询 registration
	registration := s.ctx.nsqlookupd.DB.FindRegistrations("topic", topicName, "")
	// ...
    // 4. 根据 topic 查询 channel 列表
	channels := s.ctx.nsqlookupd.DB.FindRegistrations("channel", topicName, "*").SubKeys()
    // 5. 根据 topic 查询 producer 列表
	producers := s.ctx.nsqlookupd.DB.FindProducers("topic", topicName, "")
	// 6. 过滤掉那些 inActive 的 producers，同时也过滤那些 tombstone 状态的 producers
	producers = producers.FilterByActive(s.ctx.nsqlookupd.opts.InactiveProducerTimeout,
		s.ctx.nsqlookupd.opts.TombstoneLifetime)
	return map[string]interface{}{ // 7. 返回 topic 所关联的 channel 和 producer 列表
		"channels":  channels,
		"producers": producers.PeerInfo(),
	}, nil
} // /nsq/nsqlookupd/http.go
```

同样，也介绍一个`nsqd`请求`nsqlookupd`通过`http`协议完成的请求服务。比如，当`nsqd`需要请求`nsqlookupd`注册`topic`信息时，其可通过`/topic/create`的`http POST`请求来创建，而参数为`topic`名称，对应的请求处理函数为`doCreateTopic`，且没有返回值，处理函数的具体逻辑即为通过`topic`创建一个`Registration`实例，然后添加到`RegistrationDB`中。相关代码如下：

```go
// 根据 topic 来添加注册信息 Registration
func (s *httpServer) doCreateTopic(w http.ResponseWriter, req *http.Request, 
                                   ps httprouter.Params) (interface{}, error) {
	reqParams, err := http_api.NewReqParams(req) // 1. 解析请求参数
	// ... 
	topicName, err := reqParams.Get("topic") // 2. 获取请求创建的 topic
	// ...
	s.ctx.nsqlookupd.logf(LOG_INFO, "DB: adding topic(%s)", topicName)
	key := Registration{"topic", topicName, ""} // 3. 构建一个 Registration
	// 4. 将其添加到 RegistrationDB（value 为空的 map）
    s.ctx.nsqlookupd.DB.AddRegistration(key) 
	return nil, nil
}// /nsq/nsqlookupd/http.go
```

至此，关于`nsqlookupd`相关的逻辑的源码已经分析完毕。相比`nsqd`要简单，没有复杂的流程。

简单小结，本文以执行`nsqlookupd`命令为切入点，先是简要分析了`nsqlookupd`其利用`svc`启动一个进程的过程。进而分析了`NSQLookupd`的`Main`方法的执行流程，其核心逻辑为创建了`tcp`及`http`请求的处理器，并注册了监听函数。本文的重点在于分析`tcp`请求处理器的详细内容，附带阐述了`nsqd`实例启动后与`nsqlookupd`实例的一个交互过程，具体包括`IDENTIFY`、`REGISTER`及`PING`等命令请求。然后，对于`http`请求处理器也进行了简要分析，侧重于处理器的创建过程。最后，对于`http`请求的方式，以两个示例分别阐述了客户端（消费者）及`nsqd`请求`nsqlookupd`完成`topic`查询和`topic`注册过程。更详细内容可以参考笔者简要[注释的源码](https://github.com/qqzeng/nsqio/tree/master/nsq)。





参考文献

[1].  https://github.com/nsqio/nsq
[2]. https://nsq.io/overview/quick_start.html

