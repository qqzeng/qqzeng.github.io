---
title: 简单对比 Raft 及 ZAB 协议
date: 2019-01-08 14:59:48
categories:
- 分布式系统
- 一致性算法
tags: 
- 一致性算法
- 原子广播协议
---

如果你了解过`Raft`协议、`ZAB`(`ZooKeeper's Atomic Broadcast`)协议及`Paxos`算法，你会发现它们本质上都是为了解决共识问题，即属于一种一致性算法（原子广播协议通常意义上可以等同于一致性协议）。但你可能会觉得相比于`Paxos`，`ZAB`与`Raft`可能更相似。从直观感受上，`Paxos`协议（`Basic Paxos`）更像是一种广义上的一致性算法的理论版本，它泛化了很多问题，并且没有基于特定场景的（工程）设计，因此相对而言也更难理解。而`ZAB`及`Raft`则像是具化的一致性化算法，并且简化了一些问题的前提设定，这也使得它们更易理解，也更易实现。本文对`Raft`协议及`ZAB`协议进行简单理解对比，主要讨论它们的不同之处。考虑到`Raft`论文给出了关于实现的详细细节，但官方提供的`ZAB`论文并没有涉及太多实现细节（Andr´e Medeiros 于 2012 年发表了一篇理论结合实践的论文），因此关于`ZAB`的细节是针对`ZooKeeper`的实现而言的。

<!--More-->

首先，考虑一个问题，为什么需要选举出一个`leader`？我们知道，在`Basic Paxos`中并没有强调一定需要一个`leader`。但在`Raft`中包含了`leader`的强领导原则，而`ZAB`协议，正常的`Broadcast`阶段也需要一个`leader`。很自然地，若能够选举出一个`leader`节点，由其来统筹所有的客户端请求，可以方便并发控制，而且，因为`leader`是具备最新日志的节点，这使得日志同步过程也变得更简单，单向地由`leader`流向`follower`。另外，其实在日志恢复过程中，需要挑选出包含最新日志的节点，如果将它作为`leader`，那将使得失败恢复过程加快。最后，根本上而言，`Raft`及`ZAB`的对日志的应用都差不多归纳为一个二阶段过程，先收集`follower`反馈，然后，根据特定规则决定是否提交。那么收集反馈的工作若交由`leader`来处理，明显简化了协议流程。

接下来，我们简述`Raft`协议与`ZAB`协议中选举流程的对比情况。明显地，二者都是先选投票给自己，然后广播投票信息，另外它们都包含了选举轮次的概念（在`Raft`中为任期`term`，在`ZAB`中为`round`，两者的选举过程可能会涉及多轮），这确实比较类似，但需要注意的是，选举完成后，对于`Raft`而言，`term`即为`leader`所在的任期，而`ZAB`协议却额外使用了一个任期概念(`epoch`)。在具体的选举过程中，`Raft`协议规定一旦节点认为它能够为候选者投票，则在此轮投票过程中，都不会改变。而在`ZAB`协议中，集群中各节点反复交换选票信息（里面包含各自已提交的历史事务日志），以更新选票信息。二者都有`quorum`选票成功的概念。

与选举流程相关的另一个问题就是如何定义节点包含更新的事务日志。在`Raft`中，是通过依次比较`term`及`index`来确定。而`ZAB`协议是依次比较`epoch`及`counter`来决定（即通过比较`zxid`），值得注意的是选举轮次`round`也会作为比较因素。另外，在`Raft`中有一个很重要的一点为，被选举出来的`leader`只能提交本`term`的事务日志（不能显式提交之前`term`的未提交的事务日志，论文中详细阐述了原因），即在提交当前`term`的事务日志时，隐式（顺便）提交了之前`term`的未提交的（但已被复制到`quorum`节点）事务日志。在`ZAB`协议中，当`leader`选举未完成后，不会存在这样的情况，因为在`Broadcast`阶段之前，`Synchronization`阶段（`Raft`协议并未提供此阶段）会保证各节点的日志处于完全一致的状态。

另外，`ZAB`与`Raft`协议在选举阶段都使用了超时机制，以保证节点在超时时间内未收到投票信息，会自动转入下一轮的选举。具体而言，`Raft`的选举流程还可能会出现瓜分选票的情况(`split vote)`，因此，`Raft`通过随机化超时(`randomized timeout`)时间来缓解这个问题（不是解决）。而`ZAB`协议不会存在瓜分选票的情况，唯一依据是节点的选票的新旧程度。因此，理论上`Raft`可能存在活性的问题，即不会选举过程不会终止。而`ZAB`的选举时间应该会比`Raft`的选举时间更长（更频繁的交换选票信息）。

其次，在`ZAB`论文中有提到过，`follower`及`leader`由`Broadcast`阶段进入选举阶段，有各自判定依据，或者，这可以表述为，各节点如何触发`leader`选举过程。明显，在集群刚启动时，节点会先进行选举。另外，`Raft`协议通过周期性地由`leader`向`follower`发送心跳，心巩固`leader`的领导地位，一旦超时时间内，`follower`未收到心跳信息，则转为`candidate`状态、递增`term`，并触发选举流程（当`leader`发现消息回复中包含更高`term`时，便转为`follower`状态）。而在`ZAB`协议中，也是通过`leader`周期性向`follower`发送心跳，一旦`leader`未检测到`quorum`个回复，则会转为`election`状态，并进入选举流程（它会断开与`follower`的连接）。而此时`follower`一旦检测到`leader`已经卸任，同样会进入`election`状态，进入选举流程。

如果不幸`leader`发生了宕机，集群因此重新进行了选举，并生成了新的`leader`，上一个`term`并不会影响到当前的`leader`的工作。这在`Raft`及`ZAB`协议中分别可以通过`term`及`epoch`来判定决定。那上一任期遗留的事务日志如何处理？典型地，这包含是否已被`quorum`节点复制的日志。而对于之前`term`的事务日志，`Raft`的策略在前文已经叙述，不会主动提交，若已经被过半复制，则会隐式提交。而那些未过半复制的，可能会被删除。而`ZAB`协议则采取更激进的策略，对于所有过半还是未过半的日志都判定为提交，都将其应用到状态机。

最后，是关于如何让一个新的节点加入协议流程的问题。在`Raft`中，`leader`会周期性地向`follower`发送心跳信息，里面包含了`leader`信息，因此，此节点可以重构其需要的信息。在`ZAB`中会有所不同，刚启动后，它会向转入`election`状态，并向所有节点发送投票信息，因此，正常情况下它会收到集群中其它的`follower`节点发送的关于`leader`的投票信息，当然也会收到`leader`的消息，然后从这些回复中判断当前的`leader`节点的信息，然后转入`following`状态，会周期性收到`leader`的心跳消息。需要注意的一点是，对于`Raft`而言，一个节点加入协议（不是新机器）不会阻塞整个协议的运行，因为`leader`保存有节点目前已同步的信息，或者说下一个需要同步的日志的索引，因此它只需要将后续的日志通过心跳发送给`follower`即可。而`ZAB`协议中是会阻塞`leader`收到客户端的写请求。因此，`leader`向`follower`同步日志的过程，需要获取`leader`数据的读锁，然后，确定需要同步给`follower`的事务日志，确定之后才能释放锁。值得注意的是，`Raft`的日志被设计成是连续的。而`ZAB`的日志被设计成允许存在空洞。具体而言，`leader`为每个`follower`保存了一个队列，用于存放所有变更。当`follower`在与`leader`进行同步时，需要阻塞`leader`的写请求，只有等到将`follower`和`leader`之间的差异数据先放入队列完成之后，才能解除阻塞。这是为了保证所有请求的顺序性，因为在同步期间的数据需要被添加在了上述队列末尾，从而保证了队列中的数据是有序的，从而进一步保证`leader`发给`follower`的数据与其接受到客户端的请求的顺序相同，而`follower`也是一个个进行确认请求（这不同于`Raft`，后者可以批量同步事务日志），所以对于`leader`的请求回复也是严格有序的。

最后，从论文来看，二者的快照也略有不同。`Raft`的快照机制对应了某一个时刻状态机数据（即采取的是准确式快照）。而`ZooKeeper为`了保证快照的高性能，采用一种`fuzzy snapshot`机制（这在`ZooKeeper`博文中有介绍），大概地，它会记录从快照开始的事务标识，并且此时不会阻塞写请求（不锁定内存），因此，它会对部分新的事务日志应用多次（事务日志的幂等特性保证了这种做法的正确性）。

顺便提一下，`ZooKeepr`为保证读性能的线性扩展，让任何节点都能处理读请求。但这带来的代价是过期数据。（虽然可通过`sync read`来强制读取最新数据）。而`Raft`不会出现过期数据的情况（具体如何保证取决于实现，如将读请求转发到`leader`）。

本文是从协议流程的各个阶段来对比`Raft`及`ZAB`协议。[这里](https://blog.acolyer.org/2015/03/11/vive-la-difference-paxos-vs-viewstamped-replication-vs-zab/)也提供更系统、更理论、更深入的对比（加入了`Viewstamped Replication`和`Paxos`一致性协议），它简要概括了[论文](https://arxiv.org/pdf/1309.5671.pdf)。

关于`ZAB`协议与`Paxos`的区别，这里便不多阐述了。在`ZAB`文章中有简略介绍。另外，也可以在[这里](https://cwiki.apache.org/confluence/display/ZOOKEEPER/Zab+vs.+Paxos)进行了解。这篇博文主要参考了文献[1]。





参考文献

[1]. [Raft对比ZAB协议](https://my.oschina.net/pingpangkuangmo/blog/782702)
[2]. [Vive La Différence: Paxos vs Viewstamped Replication vs Zab](https://blog.acolyer.org/2015/03/11/vive-la-difference-paxos-vs-viewstamped-replication-vs-zab/)
[3]. Van Renesse R, Schiper N, Schneider F B. Vive la différence: Paxos vs. viewstamped replication vs. zab[J]. IEEE Transactions on Dependable and Secure Computing, 2015, 12(4): 472-484.