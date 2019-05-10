---
title: 理解 ZAB 协议
date: 2019-01-05 15:03:24
updated: 2019-01-06 11:22:24
categories:
- 分布式系统
- 一致性算法
tags:
- 分布式系统
- 一致性协议
- 原子广播协议
- 选举算法
---

`ZAB` 协议是应用于 `ZooKeeper` 分布式协调框架中的可靠原子广播协议(`atomic broadcast protocol`)（或者称之为全局有序的广播协议`totaly ordered broadcast protocol`，二者基本等价），这使得`ZooKeeper`实现了一个主从(`primary-backup`)模式的架构以通过主服务器接受客户端的数据变更请求，并使用`ZAB`协议将数据变更请求增量的传播(`progpagate`)到集群副本节点。在一定程度上，原子广播协议等价于一致性算法(`consensus algorithm`)，但它们的侧重点有所不同。本质上而言，`ZooKeeper`依赖于`ZAB`协议为其它分布式应用提供诸如配置管理、分布式互斥锁以及`leader`选举等协调原语服务。另一方面，`ZooKeeper`之所以能提供高可用(`highly-available`)（比如支持支持崩溃恢复`efﬁcient crash-recovery`）及高性能(`highly-performance`)（包括低延迟`low latency`、高吞吐量`good throughput`）的协调服务，部分原因是`ZAB`协议的核心设计（区别于`paxos`）及工程实现上的优化。大致地，`ZAB`协议可以分为四个阶段：leader 选举(`leader election`)、发现(`Discovery`)、同步(`Synchronization`)以及广播(`Broadcast`)，论文中将阶段一与二合并了，`ZAB`的实际工程实现耦合了阶段二与三（与论文论述并发完全一致），因此也可以称之为三个阶段。

<!--More-->

本文主要阐述自己对`ZAB`协议的理解，这源自于`ZAB`相关的三篇论文的总结，但并非对原论文的完整翻译，因此更准确、更完整且更正式的内容可以参考原论文。值得注意的是，本论文并非如原论文那般详细、正式且全面地阐述`ZAB`协议，因此读者最好先阅读原论文，可以参考本文的协议解读。另外，本文不会过多阐述`ZooKeeper`的关键原理及系统架构，读者有兴趣可以参考[文章](https://qqzeng.top/2018/12/04/%E7%90%86%E8%A7%A3%E5%88%86%E5%B8%83%E5%BC%8F%E5%8D%8F%E8%B0%83%E6%9C%8D%E5%8A%A1-ZooKeeper/)，以大致了解`ZooKeeper`协调服务，并从应用层面整体把握`ZAB`协议。本文先介绍`ZAB`协议与二阶段提交的关系及与`paxos`作简单地对比论述。然后按照`ZAB`协议的四个阶段展开论述。因为本人暂未详细阅读过 Apache `ZooKeeper/ZAB`的实现源码，因此本文基本不会涉及与实现相关的细节，最后，考虑到本人知识的局限性，如有论述不当之处，谢谢指正！

在阅读`ZAB`相关之前，本人已初步了解过`raft`和`paxos`这两个一致性算法，如果你有了解过`raft`或者`paxos`，那么`ZAB`也较容易理解。直观上理解，`paxos`和`ZAB`都可以视作改进的二阶段提交的协议，因为原始的二阶段（包括三阶段）提交协议因为至少受到网络分区影响而不能称被直接应用于分布式系统构建。实际上，`ZAB`协议本质上是一个简化的二阶段协议，从协议构成的阶段形式上看，`leader`首先提出一个请求(称之为`request`或者`proposal`)，等待`follower`对请求的投票结果返回，最后综合投票结果以提交请求。但相比原始的二阶段提交，`ZAB`中`follower`（或者称`backup`，协议不同阶段的不同称呼）不会`abort`来自`leader`的请求，具体地，它只要么接受(`acknowledge`)`leader`的`proposal`，要么放弃此`leader`，重新进入新的一轮选举。另外，避免`abort`操作也意味着在`ZAB`协议中，`leader`提交请求并不需要经集群中所有的`follower`的同意，即只要`quorum`个`follower`给`leader`返回了`ACK`，则`leader`即请求已经在集群中达成一致。简化的二阶段提交也使得`ZAB`不得不面临`leader`失败的情况，因此，`ZAB`整个协议流程中必须考虑如何从`leader`失败中恢复的问题。在二阶段提交中，如果协调者失败，可以选择`abort`事务（准确而言是三阶段，在这里我们并不作严格区分）。

那么对比于`paxos`算法，`ZAB`协议有什么优势（即利用`ZAB`可以方便、正确且高效实现或满足，但`paxos`则不能达到此要求）？这包括两个方面：其一，`ZAB`协议允许客户端并发地发送请求消息，换言之，`ZAB`（`ZAB`的`primary`）能够同时处理若干个消息请求，并能保证请求消息以客户端提出的顺序（请求消息的`FIFO`顺序）被广播到`backup`节点。事实上，`ZAB`的能够提供这样的保证的原因是，`ZAB`中所有的请求消息 （准确而言，所有的写请求消息，因为只有写请求消息才需要被广播，以保持数据的一致性）都由`ZAB`中的（唯一一个）`primary`进行广播。因此，`ZAB`需要保证协议的始终只存在一个`primary`节点。然而，`paxos`协议却不能简单直接地保证此属性。简单而言，在`paxos`协议中，若各`primary`并发地提出请求（请求之间遵循一定的依赖关系，即只能按照其提出的顺序应用到集群），那么`learner`并不能保证按照`primary`提出事务请求的顺序来学习（应用）消息请求。虽然可以一次性将多个`proposal`进行打包形成一个单独的`proposal`，即对这些请求进行批处理，但这会影响到整个算法的性能，而且单个打包的`proposal`数量也不能简单求得。

其二，`ZAB`协议被设计成能够迅速从失败（可能是由于`leader`或`follower`崩溃或者网络故障而断连）中恢复，即`efficient recovery`。`ZAB`使用事务标识机制(`trasaction identification scheme`)来全局排序事务日志，并保证准`leader`(`prospective leader`)能够容易获知需要同步或截断的日志项。详细而言，`ZAB`采用`<value, (epoch|counter)>`来唯一标识一条事务日志，其中`value`为事务日志的内容。`epoch`（也被称为是`instance`）为`leader`的任期，每一个任期内保证只存在一个`leader`，每当重新进入`leader`选举时，需要递增此任期，事实上，任期可用于保证当上一任的`leader`失败重启后不会干扰到当前任期的`leader`的广播操作（这同`raft`类似，都采用了`epoch`以在一段逻辑时间内唯一标识`leader`）。`counter`为事务消息计数器，每次重新选举时，需要清空`counter`，此值随着客户端发送的请求消息而递增。`epoch`与`counter`各占 32 位以构成事务的`zxid`，即作为事务日志的标识。这提供了一种简单且方便的方式来比较事务日志的新旧：先比较`epoch`，`epoch`越大，日志越新，当`epoch`相等时，比较`counter`，`counter`越大，日志越新。在此种事务日志标识机制下，只有具备了最新的事务日志的节点才允许将其日志项拷贝到准`leader`。换言之，准`leader`只需从各节点返回的所有的日志中选择包含最新的日志的节点，以从此节点拷贝其缺失的事务日志（若需要的话）（需要注意的是，事实上这属于`Discover`阶段中的协议内容，若把此阶段的协议归并到`leader`选举中，则选举算法阶段会直接选择包含最新的事务日志的节点作为准`leader`，因此避免了准`leader`去包含最新的日志项的节点去拷贝操作）。而`paxos`协议并未要求失败恢复的高效执行。详细地，在其恢复阶段，只凭借拥有最大的日志编号（在`paxos`中`proposer`提出的每一条日志都有一个全局唯一的编号）并不能要求其对应的值被新的`leader`接受(`accpet`)（更多可以参考`paxos`论文或者[这里](https://qqzeng.top/2018/12/20/%E7%90%86%E8%A7%A3-Paxos-Made-Simple/) ），因此，新的`leader`必须为其缺少的日志编号所对应的日志项重新执行`paxos`协议阶段一的协议内容。

另外值得注意的是，`ZAB`采用了`TCP`（可靠的）作为节点之间的通信协议，因此避免了部分网络故障问题（如消息乱序、重复及丢失），`TCP`协议能够保证消息能够按照其发出的顺序(`FIFO`)达到目标节点。但`paxos`和`raft`协议并不依赖此条件。

在介绍`ZAB`协议的各阶段前，先简要声明一些术语。在`ZAB`协议中，每个节点可能处于三种状态中的一种：`following`、`leading`及`election`。所有的`leader`和`follower`都会依次循环执行前述的三个阶段：`Discover`（发现集群中全局最新的事务）、`Synchronization`（由`leader`向`follower`同步其缺失的事务日志）及`Broadcast`（由`leader`向`follower`广播复制客户端的事务日志），且在阶段一之前，节点处于`election`状态，当它通过执行`leader`选举流程后，它会判断自己是否有资格成为`leader`（收到`quorum`张选票），否则成为`follower`，我们暂且将`leader`选举作为协议的第零个阶段。显然，正常情况下，协议只循环在`Broadcast`阶段中执行，一旦发生`follower`与`leader`断连，则节点自动切换到选举阶段。在节点进入`Broadcast`前，必须保证集群的数据处于一致的状态。另外，在本文中节点、机器或者`server`同义；请求日志、事务日志、提案及日志命令等也作同义处理（不严谨，但读者需明白它们的细微区别）。下面各阶段涉及的术语：

> − `history`: 已被节点所接收的提案日志信息
> − `acceptedEpoch`: 接收到的最后一个`NEWEPOCH`消息的`epoch`（由准`leader`生成的`epoch`）
> − `currentEpoch`: 接收到的最后一个`NEWLEADER`消息的`epoch`（旧的`leader`的`epoch`）
> − `lastZxid`: `history`中最后一个（最新的）事务提案的`Zxid`编号

## Leader Election

在`leader`选举阶段，所有节点的初始状态为`election`，当选举结束后，节点将选举的结果持久化。在此阶段，若节点`p`给节点`q`投票，则节点`q`称节点`p`的准`leader`(`prospective leader`)，直至进入阶段三`Broadcast`，准`leader`才能被称为正式的`leader`(`estabilshed leader`)，同时它也会担任`primary`的角色（这样设计有许多优点）。`ZAB`协议中，`leader`与`primary`的称呼基本表示同一个节点，只不过它们是作为同一节点不同阶段（承担不同功能）的称呼。在`leader`选举过程中，所有的节点最开始都会为自己投票，若经过若干轮的投票广播后，发现自己不够"资格"成为`leader`时，就会转入`following`的状态，否则转为`leadering`状态。`leader`选举阶段需要为后面的阶段(`Broadcast`)提供一个后置条件(`postcondition`)，以保证在进入`Broadcast`阶段前，各节点的数据处于一致的状态，所谓的`postcondition`可以表述为`leader`必须包含所有已提交(`commit`)的事务日志。

前文提到，部分`leader`选举实现会直接选择包含最新的日志的节点作为准`leader`，`FLP`(`Fast Leader Election`)正是这样一种选举算法的实现。它通过选择包含有最大的`lastZxid`（历史日志中最后一条日志记录的`zxid`）值的节点作为准`leader`（因为具有最大`lastZxid`日志的节点必定具有最全的历史日志提交记录），这可以为后阶段的事务广播提供`postcondition`保证，`FLE`由若干轮(`round`)选举组成，在每一轮选举中，状态为`election`节点之间互相交换投票信息，并根据自己获得的选票信息(发现更好的候选者)不断地更新自己手中的选票。注意，在`FLE`执行过程中，节点并不会持久化相关状态属性（因此`round`的值不会被存盘）。

> − `recvSet`: 用于收集状态为`election`、`following`及`leading`的节点的投票信息
> − `outOfElection`:  用于收集状态为`following`及`leading`的节点的投票信息（说明选举过程已完成）

具体的选举的流程大致如下（更详细的流程可以参考论文)：

一旦开始选举，节点的初始状态为`election`，初始化选举超时时间，初始化`recvSet`及`outOfElection`。每个节点先为自己投票，递增`round`值，并把投票(`vote`包含节点的`lastZxid及id`)的消息（`notification`包含`vote, id, state及round`）广播给其它节点，即将投票信息发送到各节点的消息队列，并等待节点的回复，此后节点循环从其消息队列中取出其它节点发送给它的消息：

- 若接收到的消息中的`round`小于其当前的`round`，则忽略此消息。
- 若接收到的消息中的`round`大于节点当前的`round`，则更新自己的 `round`，并清空上一轮自己获得的选票的信息集合`recvSet`。此时，如果消息中的选票的`lastZxid`比自己的要新，则在本地记录自己为此节点投票，即更新`recvSet`，否则在本地记录为自己投票。最后将投票信息广播到其它节点的消息队列中。
- 如果收到的消息的`round`与节点本地的`round`相等，即表示两个节点在进行同一轮选举。并且若此消息的`state`为`election`并且选票的`lastZxid`比自己的要新，则在本地记录自己为此节点投票，并广播记录的投票结果。若消息的提案号比自己旧或者跟自己一样，则记录这张选票。
- 整个选举过程中（节点的状态保持为`election`，即节点消息队列中的消息包含的状态），若节点检测到自己或其它某个节点得到超过集群半数的选票，自己切换为`leading/following`状态，随即进入阶段二(`Recovery`)（`FLE`选举后，`leader`具备最新的历史日志，因此，跳过了`Discovery`阶段，直接进入`Synchronization`阶段。否则进入`Discovery`阶段）。
- 另外，如果在选举过程中，从消息队列中检索出的消息的状态为`following`或者`leading`，说明此时选举过程已经完成，因此，消息中的`vote`即为`leader`的相关的信息。
  - 具体而言，如果此时消息中的`round`与节点相同，先在本地记录选票信息，然后若同时检测到消息中的状态为`leading`，则节点转为`following`状态，进入下一阶段，否则若非`leading`状态，则需检查`recvSet`来判断消息中的节点是否有资格成为`leader`。
  - 否则，如果`round`不同，此时很有可能是选举已经完成。此时节点需要判断消息被投票的节点（有可能为`leader`）是否在`recvSet`或`outOfElection`字典中具备`quorum`张选票，同时，还要检查此节点是否给自己发送给投票信息，而正式确认此节点的`leading`状态。这个额外的检查的目的是为了避免这种情况：当协议非正常运行时，如`leader`检测到与`follower`失去了心跳连接，则其会自动转入`election`状态，但此时`follower`可能并没有意识到`leader`已经失效（这需要一定的时间，因为不同于`raft`，在`ZAB`协议中，`leader`及`follower`是通过各自的方式来检测到需要重新进行选举过程）。如果在`follower`还未检测到的期间内，恰好有新的节点加入到集群，则新加入的节点可能会收到集群中`quorum`个当前处于`following`状态的节点对先前的`leader`的投票（此时它已转入`election`状态），因此，此时仍需要此新加入的节点进行额外的判断，即检查它是否会收到`leader`发给它的投票消息（如果确实存在）。
- 最后，补充一点，`ZAB`的选举过程同样加入了超时机制（且很可能并非线性超时），以应对当节点超时时间内未收到任何消息时，重新进入下一轮选举。

## Discovery

`Discovery`阶段的目的是发现全局（`quorum`个也符合条件）最新的事务日志，并从此事务日志中获取`epoch`以构建新的`epoch`，这可以使历史`epoch`的`leader`失效，即不再能提交事务日志。另外，一旦一个处于非`leadering`状态节点收到其它节点的`FOLLOWERINFO`消息时，它将拒绝此消息，并重新发起选举。简而言之，此阶段中每一个节点会与它的准`leader`进行通信，以保证准`leader`能够获取当前集群中所包含的被提交的最新的事务日志。更详细的流程阐述如下：

 首先，由`follower`向其准`leader`发送`FOLLOWERINFO`（包含节点的`accpetedEpoch`）消息。当`leader`收到`quorum`个`FOLLOWERINFO`消息后，从这些消息中选择出最大的`epoch`值，并向此`quorum`个`follower`回复`NEWEPOCH`（包含最大的`epoch`）消息。接下来，当`follower`收到`leader`的回复后，将`NEWEPOCH`中的`epoch`与其本地的`epoch`进行对比，若回复消息中的`epoch`更大，则将自己本地的`accpetedEpoch`设置为`NEWEPOCH`消息中的`epoch`值，并向`leader`回复`ACKEPOCH`（包含节点的`currentEpoch`，`history`及`lastZxid`）消息。反之，重新进入选举阶段，即进入阶段零。当`leader`从`quorum`个节点收到`follower`的`ACKEPOCH`消息后，从这些`ACKEPOCH`消息中(`history`)查找出最新的（先比较`currentEpoch`，再比较`lastZxid`）历史日志信息，并用它覆盖`leader`本地的`history`事务日志。随即进入阶段二。

## Synchronization

`Synchronization`阶段包含了失败恢复的过程，在这个阶段中，`leaer`向`follower`同步其最新的历史事务日志。简而言之，`leader`向`follower`发送其在阶段一中更新的历史事务日志，而`follower`将其与自己本地的历史事务日志进行对比，如果`follower`发现本地的日志集更旧，则会将这些日志应用追加到其本地历史日志集合中，并应答`leader`。而当`leader`收到`quorum`个回复消息后，立即发送`commit`消息，此时准`leader`(`prospective leader`)变成了正式`leader`(`established leader`)。更详细的流程阐述如下：

首先由准`leader`向`quorum`发送`NEWLEADER`（包含阶段一中的最大`epoch`及`history`），当`follower`收到`NEWLEADER`消息后，其对比消息中的`epoch`与其本地的`acceptedEpoch`，若二者相等，则更新自己的`currentEpoch`并且接收那些比自己新的事务日志，最后，将本地的`history`设置为消息中的`history`集合。之后向`leader`回复`ACKNEWLEADER`消息。若`leader`消息中的`epoch`与本地的不相等，则转为`election`状态，并进入选举阶段。当`leader`收到`quorum`个`ACKNEWLEADER`消息后，接着向它们发送`COMMIT`消息，并进入阶段三。而`follower`收到`COMMIT`消息后，将上一阶段接收的事务日志进行正式提交，同样进入阶段三。

事实上，在有些实现中，会对同步阶段进行优化，以提高效率。具体而言，`leader`实际上拥有两个与日志相关的属性（在前述中，我们只用了`history`来描述已提交的事务日志），其一为`outstandingProposals`：每当`leader`提出一个事务日志，都会将该日志存放至`outstandingProposals`字典中，一旦议案被过半认同了，就要提交该议案，则从`outstandingProposals`中删除该议案；其二为`toBeApplied`：每当准备提交一个议案，就会将该议案存放至`toBeApplied`中，一旦议案应用到`ZooKeeper`的内存树中了，就可以将该议案从`toBeApplied`集合中删除。因此，这将日志同步大致分为两个方面：

- 一方面，对于那些已应用的日志（已经从`toBeApplied`集合中移除）可以通过不同的方式来进行同步：若`follower`消息中的`lastZxid`要小于`leader`设定的某一个事务日志索引(`minCommittedLog`)，则此时采用快照会更高效。也存在这样一种情况，`follower`中包含多余的事务日志，此时其`lastZxid`会大于`leader`的最新的已提交的事务日志索引(`maxCommittedLog`)，因此，会把多余的部分删除。最后一种情况是，消息中的`lastZxid`位于二个索引之间，因此，`leader`需要把`follower`缺失的事务日志发送给`follower`。当然，也会存在二者存在日志冲突的情况，即`leader`并没有找到`lastZxid`对应的事务日志，此时需要删除掉`follower`与`leader`冲突的部分，然后再进行同步。
- 另一方面，对于那些未应用的日志的同步方式为：对于`toBeApplied`集合中的日志（已提交，但未应用到内存），则直接将大于`follower`的`lastZxid`的索引日志发送给`follower`，同时发送提交命令。对于`outstandingProposals`的事务日志，则同样依据同样的规则发送给`follower`，但不会发送提交命令。

需要注意的的，在进行日志同步时，需要先获取`leader`的内存数据的读锁（因此在释放读锁之前不能对`leader`的内存数据进行写操作）。但此同步过程仅涉及到确认需要同步的议案，即将需要被同步的议案放置到对应`follower`的队列中即可，后续会通过异步方式进行发送。但快照同步则是同步写入阻塞。

当同步完成后，`leader`会几`follower`发送`UPTODATE`命令，以表示同步完成。此时，`leader`开始进入心跳检测过程，周期性地向`follower`发送心跳，并检查是否有`quorum`节点回复心跳，一旦出现心跳断连，则转为`election`状态，进入leader选举阶段。

## Broadcast

`Broadcast`为`ZAB`正常工作所处的阶段。当进入此阶段，`leader`会调用`ready(epoch)，`以使得`ZooKeeper`应用层能够开始广播事务日志到`ZAB`协议。同时，此阶段允许动态的加入新节点(`follower`)，因此，`leader`必须在新节点加入的时候，与这些节点建立通信连接，并将最新日志同步到这些节点。更详细的流程阐述如下：

当`leader`(`primary`)收到客户端发送的消息（写）请求`value`，它将消息请求转化为事务日志`(epoch, <value,zxid>), zxid=(epoch|counter)`，广播出去。当`follower`从`leader`收到事务请求时，将此事务日志追加到本地的历史日志`history`，并向`leader`回复`ACK`。而一旦`leader`收到`quorum`个`ACK`后，随即向`quorum`节点发送`COMMIT`日志，当`follower`收到此命令后，会将未提交的日志正式进行提交。需要注意的是，当有新的节点加入时，即在`Broadcast`阶段，若`leader`收到`FOLLOWINFO`消息，则它会依次发送`NEWEPOCH`和`NEWLEADER`消息，并带上`epoch`及`history`。收到此消息的节点会将设置节点本地的`epoch`并更新本地历史日志。

根据在`Synchronization`提到的两个数据结构`outstandingProposals`及`toBeApplied`。因此，事实上，`leader`会将其提出的事务日志放至`outstandingProposals`，如果获得了`quorum`节点的回复，则会将其从`outstandingProposals`中移除，并将事务日志放入`toBeApplied`集合，然后开始提交议案，即将事务日志应用到内存中，同时更新`lastZxid`，并将事务日志保存作缓存，同时更新`maxCommittedLog`和`minCommittedLog`。

最后，讨论`ZAB`协议中两个额外的细节：

- 若`leader`宕机，`outstandingProposals`字典及`toBeApplied`集合便失效（并没有持久化），因此它们对于`leader`的恢复并不起作用，而只是在`Synchronization`阶段（该阶段实际上是`leader`向`follower`同步日志，即也可以看成是`follower`挂了，重启后的日志同步过程），且同步过程包含快照同步及日志恢复。
- 另外，在日志恢复阶段，协议会将所有最新的事务日志作为已经提交的事务来处理的，换言之，这里面可能会有部分事务日志还未真正提交，而这里全部当做已提交来处理。（这与`raft`不同，个人认为，这并不会产生太大影响，因为在日志恢复过程中，并不会恢复那些未被`quorum`节点通过的事务日志，只是在`ZAB`在提交历史任期的日志的时机与`raft`不同，`rfat`不会主动提交历史任期未提交的日志，只在新的`leader`提交当前任期内的日志时顺便提交历史的未提交但已经复制到`quorum`节点的日志项）。

需要注意的是，本文使用的一些术语与`Yahoo!`官方发表的论文[2]可能不一样（个人参照另外一篇论文[4]阐述），但它们的问题意义相同。而且，对于每个阶段，本文先是大概阐述其流程，然后从实际实现的角度进行拓展，希望不要造成读者的困扰。另外，实际工程实现可能并不完全符合这些阶段，而且`ZooKeeper`各版本的实现也可能会包含不同的工程优化细节。具体参考论文，当然，查看`ZooKeeper`源码实现可能更清晰。





参考文献

[1] Gray J N. Notes on data base operating systems[M]//Operating Systems. Springer, Berlin, Heidelberg, 1978: 393-481.
[2] Junqueira F P, Reed B C, Serafini M. Zab: High-performance broadcast for primary-backup systems[C]//Dependable Systems & Networks (DSN), 2011 IEEE/IFIP 41st International Conference on. IEEE, 2011: 245-256.
[3] Reed B, Junqueira F P. A simple totally ordered broadcast protocol[C]//proceedings of the 2nd Workshop on Large-Scale Distributed Systems and Middleware. ACM, 2008: 2.
[4] Medeiros A. ZooKeeper’s atomic broadcast protocol: Theory and practice[J]. Aalto University School of Science, 2012, 20.
[5] 倪超. 从 Paxos 到 Zookeeper: 分布式一致性原理与实践[J]. 2015.
[6]. [ZooKeeper的一致性算法赏析](https://my.oschina.net/pingpangkuangmo/blog/778927)














