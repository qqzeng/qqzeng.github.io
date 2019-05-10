---
title: 理解分布式协调服务 zookeeper
date: 2018-12-04 19:23:30
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- 分布式协调服务
- 分布式锁
- 原子广播协议
---

`ZooKeeper `是 Yahoo! 于 2010 年在 USENIX 会议上发表的一篇论文中提出的，被用作分布式应用程序的协调服务(`coordination service`)。虽然`ZooKeeper`被认为是 Google `Chubby`的开源实现，但其设计理念却存在较大差异：`ZooKeeper`致力于提供一个简单且高性能(`high performance`)的内核(`kernel`)以为客户端（应用程序）构建更复杂、更高层(`high level`)的协调原语(`coordination primitives`)。换言之，`ZooKeeper`并不针对特定应用或者具体某一协调服务而设计实现，它只提供构建应用协调原语的内核，而将具体协调原语的构建逻辑放权给客户端，并且，它确保了客户端在不需要更改内核服务的前提下，能够灵活构建出新的、更高级的且更强大的协调原语，比如分布式互斥锁、分布式队列等。`ZooKeeper`为每个客户端操作提供`FIFO`顺序保证，并且为所有写操作提供`linearlizablity`保证。`ZooKeeper`的实现原理为构建在其之上的服务提供高性能保证。

<!--More-->

[Zookeeper](https://scholar.google.com/scholar_url?url=https://www.usenix.org/event/usenix10/tech/full_papers/Hunt.pdf&hl=zh-CN&sa=T&oi=gsb-ggp&ct=res&cd=0&d=16979330189653726967&ei=n4kGXN6bNYSwyQTtrY2YBw&scisig=AAGBfm3u4LNga1CwiXqT9W5TbZFnKyv21Q) 为分布式应用提供诸如配置管理(`configuration managation`)、leader 选举等协调服务，这通过为应用程序提供构建协调原语的 `API`来实现。并且，与那些提供阻塞原语的服务不同，`ZooKeeper`实现的 [wait-free](https://en.wikipedia.org/wiki/Non-blocking_algorithm) 数据对象确保其容错和高性能特性，因为若利用阻塞原语来构建协调服务，可能会导致那些慢的(`slow`)或者有错误的(`faulty`)的客户端影响正常的客户端的服务性能。此博客阐述个人对`ZooKeeper`的理解，并从一个`ZooKeeper`的应用实例开始讨论，分别阐述`ZooKeeper`两个`ordering guarantees`、。因为本文并非对原论文的完整翻译，因此你需要提前阅读原论文，确保熟知`ZooKeeper`数据模型以及客户端`API`等内容，而且，博客也会省略论文所阐述的利用`ZooKeeper`来实现部分协调服务部分，具体内容可以参考原论文。

## 一个应用实例阐述

我们知道`MapReduce`需要知道集群`master`的`ip:port`以使得其它节点能够与`master`建立连接通信，为此，`MapReduce`可以利用`ZooKeeper`作为动态配置服务，让`master candidate`在`ZooKeeper`上并发注册（创建）各自`ephemeral`类型的`ip:port`节点，并让`slave`监听对应节点的`watch event`，因此一旦有`master candidate`注册成功（且只能有一个创建成功），则其它节点将能获取到`master`的`ip:port`。

若使用基于`raft`构建的复制状态机实现，比如在`raft`集群上构建一个`key/value`存储系统来存放`GFS master`的元信息。则整个过程大致如下：首先，`master candidate`向`raft`发送`Put("gfs-master", "ip:port")`命令日志，当`raft`集群`apply`此命令日志后，其它节点可通过向`raft`发送`Get("gfs-master")`命令来获取`master`的`ip:port`。但此过程存在几个问题：其一，若多个`master candidate`同时向`raft`发送节点地址的注册命令日志，此时将产生`race condition`，其会导致后发送的命令被应用到状态机，因此`master candidate`需要进一步判断自己是否成为真正的`master`（不能仅通过发送了节点地址命令日志来确定）；其二，若`master`失效，其地址项日志必须要从存储中移除，那么谁来执行此操作？因此，必须对`master`的元数据信息设置`timeout timestamp`，并且让`master`通过定期向`raft`发送`Put(ip:port, timestamp)`日志来更新`timeout`的`timestamp`，而集群其它节点通过向`raft`轮询(`poll`)此`timestamp`来确保`master`正常工作，毫无疑问，这将产生大量不必要的`poll cost`。对比使用`ZooKeeper`来提供此协调服务（上一段），问题是如何被`ZooKeeper`高效便捷地解决呢？首先它会确保在多个`master candidate`同时注册地址信息时，只会有一个操作成功；其次，`ZooKeeper`的`session`机制简化了`timestamp timeout`设置，一旦`master`宕机，其在`ZooKeeper`上注册的元信息节点将会自动清除。而且，对应的节点移除消息也会通知到其它节点，避免了`slave`的大量的轮询消耗。由此可见，使用`ZooKeeper`来进行集群配置信息的管理，有利于简化服务实现的逻辑。

## ZooKeeper 两个 ordering guarantees

在讨论`ZooKeeper`两个基本的`ordering guarantees`之前，先了解什么是 `wait-free`，你可以从[维基](https://en.wikipedia.org/wiki/Non-blocking_algorithm)或者 [Herlihy的论文](https://cs.brown.edu/~mph/Herlihy91/p124-herlihy.pdf) 上找到其明确定义：

> A wait-free implementation of a concurrent data object is one that guarantees that any process can complete any operation in a finite number of steps, regardless of the execution speeds of the other processes.

> Wait-freedom is the strongest non-blocking guarantee of progress, combining guaranteed system-wide throughput with starvation-freedom. An algorithm is wait-free if every operation has a bound on the number of steps the algorithm will take before the operation completes
>

而对于`ZooKeeper`而言，其提供的`API`被称为是`wait-free`的，因为`ZooKeeper`直接响应客户端请求，即此请求的返回并不会受到其它客户端操作的影响（通常是`slow`或者`faulty`）。换言之，若此客户端请求为写节点数据操作，只要`ZooKeeper`收到状态变更，则会立即响应此客户端。如果在这之前某一客户端监听了此节点的数据变更事件，则一旦此节点的数据发生变化，则`ZooKeeper`会推送变更事件给监听的客户端，然后立即返回给写数据的客户端，并不会等待此监听客户端确认此事件。相比于同步阻塞的调用，`wait-free`明显提供更好的性能，因为客户端不用同步等待每次调用的返回，且其可以进行异步的批量调用`batch call`操作，以均摊(`amortize`)网络传输和IO开销。`wait-free`的`API`是`ZooKeeper`具备高性能的基础，因此也是`ZooKeeper`的设计核心。

`ZooKeeper`提供了两个基本的`ordering guarantees`：`Linearizable writes`及`FIFO client order`。`Linearizable write`表示对`ZooKeeper`的节点状态更新的请求都是线性化的(`serializable`)，而`FIFO client order`则表示对于同一个客户端而言，`ZooKeeper`会保证其操作的执行顺序与客户端发送此操作的顺序一致。毫无疑问，这是两个很强的保证。

`ZooKeeper`提供了`Linearizable write`，那什么是`Linearizablility`？[Herlihy的论文](https://cs.brown.edu/~mph/Herlihy91/p124-herlihy.pdf)同样给出了其定义，为了方便，你也可以参考[这里](https://medium.com/databasss/on-ways-to-agree-part-2-path-to-atomic-broadcast-662cc86a4e5f)或者[这里](http://www.bailis.org/blog/linearizability-versus-serializability/)。

> Linearizability is a correctness condition for concurrent objects that provides the illusion that each operation applied by concurrent processes takes effect instantaneously at some point between its invocation and its response, implying that the meaning of a concurrent object’s operations can be given by pre- and post-conditions.

简单而言，`Linearizability`是分布式系统领域的概念（区别于数据库领域与事务相关的概念`Serializability`），一个分布式系统若实现了`linearizability`，它必须能够保证系统中存在一个时间点，在此时间点之后，整个系统会提交到新的状态，且绝不会返回到旧的状态，此过程是即时的(`instantaneous`)，一旦这个值被提交，其它所有的进程都会看到，系统的写操作会保证是全局有序(`totally ordered`)。

而`ZooKeeper`论文提到其`write`具备`Linearizability `，确切而言是` A-linearizability `(`asynchronous linearizability`)。简而言之，`Linearizability`原本（原论文）是针对单个对象，单个操作(`single object, single operation`)而言的，但`ZooKeeper`扩大其应用范围，它允许客户端同时执行多个操作（读写），并且保证每个操作同样会遵循`Linearizability`。

值得注意的是，`ZooKeeper`对其操作（`create`,`delete`等）提供`pipelining`特性，即`ZooKeeper`允许客户端批量地执行异步操作（比如发送了`setData`操作后可以立即调用`geData`），而不需要等到上一个操作的结果返回。毫无疑问，这降低了操作的延迟(`lantency`)，增加了客户端服务的吞吐量(`throughtout`)，也是`ZooKeeper`高性能的保证。但通常情况下，这会带来一个问题，因为所有操作都是异步的，因此这些操作可能会被重排序(`re-order`)，这肯定不是客户端希望发生的（比如对于两个写操作而言，`re-order`后会产生奇怪的行为）。因此，对于特定客户端，`ZooKeeper`还提供`client FIFO order`的保证。

## ZooKeeper 实现原理

同分布式存储系统类似，`ZooKeeper`也会对数据进行冗余备份。在客户端发送请求之前，它会连接到一个`ZooKeeper server`，并将后续的请求提交给对应的`server`，当`server`收到请求后，有做如下三个保证：其一，若请求所操作的节点被某些客户端注册了监听事件，它会向对应的客户端推送事件通知。其二，若此请求为写操作，则`server`一次性只会对一个请求做处理（不会同时处理其它的读或者写请求）。其三，写操作最终是交由`leader`来处理（若接收请求的`server`并非`leader`，其主动会对请求进行转发），`leader`会利用`Zab`（原子广播协议，`ZooKeper atomic broadcast`）对此请求进行协调，最终各节点会对请求的执行结果达成一致，并将结果 `replica`到`ensemble servers`。`ZooKeeper`将数据存储到内存中（更快），但为了保证数据存储的可靠性，在将数据写到内存数据库前，也会将数据写到磁盘等外部存储。同时，对操作做好相应的`replay log`，并且其定期会对数据库进行`snapshot`。

若请求为读操作，则接收请求的`server`直接在本地对请求进行处理（因此读操作仅仅是在`server`的本地内存数据库进行检索处理，这也是`ZooKeeper`高性能的保证）。正因为如此，同`GFS`可能向客户端返回过期数据的特点类似，`ZooKeeper`也有此问题。如果应用程序不希望得到过期数据（即只允许得到最近一次写入的数据），则可以采用`sync`操作进行读操作前的写操作同步，即如果在读操作之前集群还有`pending`的写操作，会阻塞直至写操作完成。值得注意的是，每一次的读操作都会携带一个`zxid`，它表示`ZooKeeper`最近一次执行事务的编号（关于事务，后面会介绍），因此`zxid`定义了读操作与写操作之间的偏序关系。同时，当客户端连接到`server`时，如果此`server`发现其本地存储的当前`zxid`小于客户端提供的`zxid`的大小，其会拒绝客户端的连接请求，直至其将本地数据库同步至全局最新的状态。

在`ZooKeeper`内部，它会将接收到的写操作转换为事务(`transaction`)操作。因为`ZooKeeper`可能需要同时处理若干个操作，因此其会提前计算好操作被提交后数据库所处的状态。这里给出论文中提到的一个事务转换的示例：如果客户端发送一个条件更新的命令`setData`并附带上目标节点的`version number`及数据内容，当`ZooKeeper server`收到请求后，会根据更新后的数据，版本号以及更新的时间戳，为此请求生成一个`setDataTXN`事务。当事务执行出错时（比如版本号不对应），则会产生一个`errorTXN`的事务。

值得注意的是，`ZooKeeper`内部所构建的事务操作是幂等的(`idempotent`)。这有利于`ZooKeeper`执行失效恢复过程。具体而言，为了应对节点宕机等故障，`ZooKeeper`会定期进行`snapshot`操作，`ZooKeeper`称其为`fuzzy snapshot`。但与普通的分布式系统不同的是，它在进行快照时，并不会锁定当前`ZooKeeper`集群（一旦锁定，便不能处理客户端的写操作，且快照的时间一般也相对较长，因此会降低客户端的服务性能），它会对其树形存储进行深度优先搜索，并将搜索过程中所遍历的每一个节点的元信息及数据写到磁盘。因为`ZooKeeper`快照期间并没有锁定`ZooKeeper`的状态，因此在此过程中，若有`server`在同步写操作，则写操作可能只被`replica`到部分节点，最终使得`snapshot`的结果处于不一致的状态。但正是由于`ZooKeeper`的事务操作是`idempontent`，因此，在`recover`过程应用`snapshot`时，还会重新按顺序提交从快照启动开始到结束所涉及到的事务操作。原论文给出了一个快照恢复过程示例。因此我们会发现，`fuzzy snapshot`同样是`ZooKeeper` 高性能的体现。另外，事务幂等的特性也使得`ZooKeeper`不需要保存请求消息的ID（保存的目的是为了防止对重复执行同一请求消息），因为事务的重复执行并不会导致节点数据的不一致性。由此可见，事务幂等性的大大设计简化了`ZooKeeper`的请求处理过程及日志恢复的过程。

最后，关于原论文所阐述的基于`ZooKeeper`内核来构建协调服务的相关实例部分，[参考实现代码在这里](https://github.com/qqzeng/zkprimitives)。



参考文献

[1] Hunt P, Konar M, Junqueira F P, et al. ZooKeeper: Wait-free Coordination for Internet-scale Systems[C]//USENIX annual technical conference. 2010, 8(9).
[2] Herlihy M P, Wing J M. Linearizability: A correctness condition for concurrent objects[J]. ACM Transactions on Programming Languages and Systems (TOPLAS), 1990, 12(3): 463-492.
[3] https://medium.com/databasss/on-ways-to-agree-part-2-path-to-atomic-broadcast-662cc86a4e5f
[4] https://en.wikipedia.org/wiki/Non-blocking_algorithm
[5] http://www.bailis.org/blog/linearizability-versus-serializability/