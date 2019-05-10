---
title: 理解 Paxos Made Simple
date: 2018-12-20 19:50:57
categories:
- 分布式系统
- 一致性算法
tags:
- 分布式系统
- 一致性算法
---

Paxos 算法在分布式系统领域早已是如雷贯耳般的存在，基本成为了分布式一致性协议的代名词，想必对于任何一个从事分布式领域的人来说都充满敬畏——即感叹算法的精巧，也畏惧算法的晦涩。Leslie Lamport 早在 1980s 就写作了描述 `Paxos`最原始的论文 《The Part-Time Parliament》，但因其难以理解（与论述方式相关?）而没有得到过多的关注（相反，Lamport 本人却坚持认为自己采用了一种更加形象恰当且容易理解的方式阐述，摈弃了传统学术论文的”死板“风格）。在 2001年，Lamport 对 `Paxos` 论文进行整理简化并发表了《Paxos Made Simple》，引起了广泛关注。论文的第一句话 The Paxos algorithm, when presented in plain English, is very simple 可以体会到 Leslie Lamport 似乎仍旧对众人对 `Paxos` 冠以难理解性的言行的”不屑“。

<!--More-->

最近重新阅读了《Paxo Made Simple》论文，想从论文本身出发，阐述自己对论文的一些（浅显，且可能有误）的理解，因为还未了解`Paoxs`系列其它论文（如 Fast Paxos），因此个人的理解可能存在一定的局限性。同时，个人坚持认为，反复读原始论文是理解算法的最根本途径，最好结合开源实现进行理解（开源实现一般都会对算法进行工程上的优化与"妥协"）。当然读完原论文可能会有困惑，因此，也可以尝试参考别人的理解（从不同的角度思考问题，或许会有收获），但最终还是要回归论文。如果你对本文有兴趣，你需要先阅读论文。另外，你需要先了解其应用场景。本文先简述其应用场景，然后按照原论文推理的逻辑和步骤来逐步阐述自己对这些步骤的理解。

## Paxos 应用场景

`Paxos`用于解决分布式场景的一致性问题。换言之，`Paxos`是一个一致性（共识）算法。这个说法可能比较笼统宽泛，因为你可能在很多领域了解过一致性问题（虽然这些解释背后的含义可能也存在共性）。比如对于分布式存储，典型的`Nosql`数据库领域，所谓的一致性可能是要求客户端能够读取其最新写入的数据。换言之，最近写入的数据需要对所后续的客户端的读都可见，强调的是可见性。这可以用线性一致性(`Linearizability`)来描述；再者，在数据库领域，顺序一致性(`serializability`)是事务正确性的保证，即强调正确性；而复制状态机(` replicated state machine`)是很多一致性算法的典型应用场景（包括`Paxos`），其强调的是让一组互为备份的节点执行一系列相同的命令日志来保证存储在此节点集合中的数据的一致，以达到容错目的。另外，从一致性算法的强弱角度来考虑，一致性算法包括强一致性，弱一致性以及最终一致性。而`Paxos`则属于强一致性算法。另外，我们再简单了共识算法的正确性的保证：

> 1. *Agreement* - all N (or a majority) nodes decide on the same value
> 2. *Validity* - the value that is decided upon must have been proposed by some node in N
> 3. *Termination* - all nodes eventually decide

这些都容易理解，比如，对于`Agreement`而言，若某个算法都不难最后表决出来的值是同一个，那就不能称之为共识算法，而`Validity`可能觉得是很显然的事情，可以从这样一个角度思考，如果所有节点始终回复相同的值，而不管实际提出的值是什么，那么`Agreement`能够得到保证，但却违反了`Validity`条件。最后的`Termination`保证了算法最终能够停止，即我们不仅希望你们能够做表决，也希望能够最终表决出一个结果，否则此表决过程没有意义。而`Paxos`论文提到的`safty requirement` 如下：

> 1.  Only a value that has been proposed may be chosen,
> 2.  Only a single value is chosen, and
> 3. A process never learns that a value has been chosen unless it actually has been.

明确提出了，只保证了前面两点(`Agreement`及`Validity`，只是换了一种说法，并颠倒1与2的顺序)，换言之，理论上而言，`Paxos`是存在活锁的问题，后面会详细阐述。当然`Paxos`算法只考虑节点存在` non-Byzantine `及`asynchronous`网络的条件下。

那么`Paxos`如何应用于复制状态机呢？简单而言，`Paxos`试图通过对所有的（客户端发送的）命令日志（如`SET X=1`）进行全局编号，如果能够全局编号成功，那么互为备份的节点按照此全局编号顺序来执行对应的命令日志，即能够保证数据的一致性。在一个分布式系统中，若执行命令日志序列前，系统处于一致的状态，且节点都执行了相同的命令日志序列，那么最终整个系统也处于一个一致的状态。因此为了保证每个节点都能够以相同的顺序执行命令日志，所有节点必须对于每一条命令日志达成共识（比如，有两个节点尝试提交命令日志，节点`a`尝试让`v=i`，而节点`b`尝试让`v=j`，明显这会产生冲突，因此需要协调以达成共识，即最终`v`的值要么是`i`，那么所有节点都会认为`v=a`），即每个节点看到的指令顺序是一致的。显然，问题在于不同的节点可能接收到的日志的编号的顺序是不同的，因此不能按照单个节点的意愿进行命令日志的执行（否则会出现数据一致的情况），换言之，所有节点需要相互通信协调，每个节点都对全局编号的排序进行表决。每一次表决，只能对一条命令日志（数据）进行编号，这样才能保证确定的日志执行，这也正是`Paxos`所做的，即`Paxos`的核心在于确保每次表决只产生一条命令日志（一个`value`，这里的命令日志可以表示一个操作，也可以表示一个值）。当然某一次表决成功（达成一致）并不意味着此时所有节点的本地的`value`都相同，因为可能有节点宕机，即通常而言，只要保证大多数(`quorum`)个节点存储相同的`value`即可。

## 论文理解

这里省略了协议的一些基本术语及概念。但还是再强调一下，协议对某个数据达成一致的真正含义提什么，其表示`proposer`、`acceptor`及`learner`都要认为同一个值被选定。详细而言，对于`acceptor`而言，只要其接受了某个`proposal`，则其就认定该`proposal`的`value`被选定了。而对于`proposer`而言，只要其`issue`的`proposal`被`quorum`个`acceptor`接受了，则其就认定该`proposal`对应的`value`就被选定了。最后对于`learner`而言，需要`acceptor`将最终决定的`value`发送给它，则其就认定该`value`被选定了。另外，`acceptor`是可能有多个的，因为单个`acceptor`很明显存在单点故障的问题。

我们直接一步步来观察 Lamport 论文中的推导，以达到最终只有一个值被选中的目的（确定一个值），即`Only a single value is chosen`。这句话很重要，它暗示了不能存在这样的情形，某个时刻`v`被决定为了`i`，而在另一时刻`v`又被决定成了`j`。

> P1. An acceptor must accept the ﬁrst proposal that it receives.

乍一看此条件，让人有点不知所措。论文前一句提到，在没有故障的情况，我们希望当只有一个`proposer`的时候，并且其只提出一个`value`时，能够有一个`value`被选中，然后就引出了`P1`。这是理所当然的，因为此`acceptor`之前没有收到任何的`value`，或许后面也不会收到了，那它选择此`value`就无可厚非。换言之，此时`acceptor`并没有一个合适的拒绝策略，只能先选择这个值。但很明显，这个条件远不能达到我们的目的（比如，多个`acceptor`可能会接受到不同的`proposer`提出的不同的`value`，直接导致不同的`value`被选定，因此不可能只决定一个值）。而且仔细想想，作者提出的这个条件确实比较奇怪，因为你不知道此条件与最终协议的充要条件有什么联系，而且，你可能会想，既然已经选择了第一个值，若后面又有第二个`proposal`来了应该如何处理（才能保证最终只选择一个值）。直观上我们可能会推断出，每个`acceptor`只接受一个`proposal`是行不通的，即它可能会接受多个`proposal`，那既然会接受多个`proposal`，这些`proposal`肯定是不同的（至少是不同时间点收到的），因此需要进行区分衡量，这也正是提案编号`proposal id`的作用。另外还暗示了一点，正常情况下，对于`proposer`而言，一个`proposal`不能由只被一个`acceptor`接受了就认定其`value`被选定，必须要由大多数的（即法定集合`quorum`）选定才能说这个值被选定了。

直观上理解，虽然我们允许了一个`acceptor`可以`accept`多个`proposal`，但为了保证最终只能决定一个`value`，因此很容易想到的办法是保证`acceptor`接受的多个`proposal`的`value`相同。这便引出了`P2`：

> P2. If a proposal with value v is chosen, then every higher-numbered proposal that is chosen has value v.

为了保证每次只选定一个值，`P2`规定了如果在一个`value`已经被选定的情况下，若还有的`proposer`提交`value`，那么之后（拥有更高编号`higher-numbered`）被`accept`的`value`应该与之前已经被`accept`的保持一致。这是一个比较强的约束条件。显然，如果能够保证`P2`，那么也能够够保证`Paxos`算法的正确性。

但从另一方面考虑，对比`P1`与`P2`，感觉它们有很大的不同，它们阐述的不是同一个问题。`P1`讨论的是如何选择`proposal`的问题，而`P2`则直接跳到了选出来后的问题：一旦`value`被选定了，后面的被选出来的`value`应该保持不变。从论文中后面的推断不断增强可以分析出，`P2`其实包含了`P1`，两个条件并不是相互独立的，因为`P2`其实也是一个如何选的过程，只不过它表示了一般情况下应该如何选的问题，而`P1`是针对第一个`proposal`应该如何选的问题。换言之，`P1`是任何后续的推论都需要保证的，后续作出的任何推断都不能与`P1`矛盾。

注意到，后续若有其它的`proposal`被选定，前提肯定是有`acceptor`接受了这个`proposal`。自然而然，可以转换`P2`的论述方式，于是就有了`P2a`：

> P2a . If a proposal with value v is chosen, then every higher-numbered proposal accepted by any acceptor has value v.

`P2a`其实是在对`acceptor`做限制。事实上，`P2`与`P2a`是一致的，只要满足了`P2a`就能满足`P2`。但前面提到过`P1`是后续推断所必须满足的，而仔细考量`P2a`，它似乎违反了`P1`这个约束底线。可以考虑这样一个场景：若有 2 个`proposer`和 5 个`acceptor`。首先由`proposer-1`提出了`[id1, v1]`的提案，恰好`acceptor1~3`都顺利接受了此提案，即`quorum`个节点选定了该值`v1`，于是对于`proposer-1`及`acceptor1~3`而言，它们都选定了`v1`。而`acceptor4`在`proposer-1`提出提案的时候，刚好宕机了（事实上，只要其先接受`proposer-2`的提案即可，且`proposer-2`的编号大于`proposer-1`的编号）而后有`proposer-2`提出了提案`[id2, v2]`且`id2>id1 & v1!=v2`。那么由`P1`知，`acceptor-4`在宕机恢复后，必须接受提案`[id2, v2]`，即选定`v2`。很明显这不符合`P2a`的条件。因此，我们只有对`P2a`进行加强，才能让它继续满足`P1`所设定的底线。

我们自己可以先直观思考，为了保证`acceptor`后续通过的`proposal`的值与之前已经认定的值是相同的。如果直接依据之前的简单流程：`proposer`直接将其提案发送给`acceptor`，这可能会产生冲突。所以，我们可以尝试限制后续的`proposer`发送的提案的`value`，以保证`proposer`发送的提案的``value`与之前已经通过的提案的value`相同，于是引出了`P2b`：

> P2b. If a proposal with value v is chosen, then every higher-numbered proposal issued by any proposer has value v.

`P2b`的叙述同`P2a`类似，但它强调（约束）的是`proposer`的`issue`提案的过程。因为，`issue`是发生在`accept`之前，那么`accept`的`proposal`一定已经被`issue`过的。因此，`P2a`可以由`P2b`来保证，而且，`P2b`的限制似乎更强。另外，`P1`也同时得到满足。

对于`P2b`这个条件，其实是难以实现。因为直观上，你不能限定各个`proposer`该`issue`什么样的`proposal`，不能`issue`什么样的`proposal`。那么又该如何保证`P2b`呢？我们同样可以先自己主观思考，为了让`proposer`之后`issue`的`proposal`的`value`与之前已经被通过的`proposal`的`value`的值保持一致，我们是不是可以尝试让`proposer`提前与`acceptor`进行沟通，以获取之前已经通过的`proposal`的`value`呢？具体如何沟通，无非是相互通信，接收消息或者主动询问，接收消息未免显得过于消极，而主动询问显然是更好的策略。如果的确存在这样的`value`，那为了保证一致，我就不再指定新的`value`了，与先前的`value`保持一致即可。而原论文给出了`P2c`:

> P2c. For any v and n, if a proposal with value v and number n is issued, then there is a set S consisting of a majority of acceptors such that either 
>
> (a) no acceptor in S has accepted any proposal numbered less than n, or 
>
> (b) v is the value of the highest-numbered proposal among all proposals numbered less than n accepted by the acceptors in S.

作者认为，`P2c`里面包含了`P2b`。`P2c`中的`(a)`容易理解，因为如果从来没有`accept`过编号小于`n`的提案，那由`P1`自然而然就可以接受。而对于`(b)`可以用法定集合的性质简单证明，即两个法定集合(`quorum`)必定存在一个公共元素。我们可以采用反证法结合归纳法来简单证明。假定编号为`m`且值为`v`的提案已经被选定，那么，存在一个法定集合`C`，`C`中每一个`acceptor`都选定了`v`。然后有编号为`n`的`proposal`被提出 ：那么，

① 当`n=m+1` 时，假设编号为`n`的提案的`value`不为`v`而为`w`。则根据`P2c`，存在一个法定集合`S`，要么`S`中的`acceptor`从来没有批准过小于`n`的提案；要么在批准的所有编号小于`n`的提案中，编号最大的提案的值为`w`。但因为`S`和`C`至少存在一个公共`acceptor`，明显两个条件都不满足。所以假设不成立。因此`n`的值为`v`。② 当编号`m`属于`m ... (n-1)`，同样假设编号为`n`的提案的`value`不为`v`，而为`w’` 。则存在一个法定集合`S’`，要么在`S’`中没有一个`acceptor`批准过编号小于`n`的提案；要么在`S’`中批准过的所有的编号小于`n`的提案中，编号最大的提案的值为`w’`。根据假设条件，编号属于`m...(n-1)`的提案的值都为`v`，并且`S’`和`C`至少有一个公共`acceptor`，所以由`S’`中的`acceptor`批准的小于`n`的提案中编号最大的那个提案也属于`m...(n-1)`。从而必然有`w’=v`。

若要满足`P2c`，其实也从侧面反映出若要使得`proposer`提交一个正确的`value`，必须同时对`proposer`和`acceptor`作出限制。我们现在回顾一下先前的推断的递推关系：`P2c=>P2b=>P2a=>P2`。因此，`P2c`最终确保了`P2`，即当一个`value`被选定之后，后续的编号更大的被选定的`proposal`都具有先前已经被选定的`value`。整个过程，先是对整个结果提出要求形成`P2`，然后转为对`acceptor`提出要求`P2a`，进行转为对`proposer`提出要求`P2b`，最后，同时对`acceptor`及`proposer`作出要求`P2c`。

## Paxos 算法步骤

最后，我们简单阐述一下`Paxos`算法的步骤。其大致可以分为两个阶段。

1. 阶段一，`prepare`阶段。
   - `proposer`选择一个新的编号`n`发送给`quorum`个`acceptor`，并等待回应。
   - 如果`acceptor`收到一个针对编号为`n`的`prepare`请求，则若此`prepare`请求的编号`n`大于它之前已经回复过的`proposal`的所有编号的值，那么它会 (1) 承诺不再接受编号小于`n`的`proposal`。(b) 向`proposer`回复之前已经接受过的`proposal`中编号最大的`proposal`（如果有的话）。否则，不予回应。或者，回复一个`error`给`proposer`以让`proposer`终止此轮决议，并重新生成编号。
2. 阶段二，`accept`阶段。
   - 如果`proposer`收到了`quorum`个`acceptor`对其编号为`n`的`prepare`请求的回复，那么它就发送一个针对`[n, v]`的`proposal`给`quorum`个`acceptor`（此`quorum`与`prepare`阶段的`quorum`不必相同）。其中，`v`是收到的`prepare`请求的响应的`proposal`集合中具有最大编号的`proposal`的`value`。如果收到的响应集合中不包含任何`proposal`，则由此`proposer`自己决定`v`的值。
   - 如果`acceptor`收到一个针对编号为`n`的`accept`请求，则若其没有对编号大于`n`的`prepare`请求做出过响应，就接受该`proposal`。

## Paxos 算法活性

前面提到，理论上`Paxos`可能永远不会终止（即永远无法达成一致），即使是在没有故障发生的情况。考虑这样一个场景，`proposer-1`发起了`prepare`阶段并获得了大多数`acceptor`的支持，然后`proposer-2`立刻带着更高的编号来了，发起了`prepare`阶段，同样获得了大多数的`acceptor`的支持（因为`proposer-2`的编号更高，`acceptor`只能对`prepare`请求回复成功）。紧接着`proposer-a`进入了`accept`阶段，从`acceptor`的回复中得知大家又都接受了一个更高的编程，因此不得不选择更大的编号并重新发起一轮`prepare`阶段。同样，`proposer-2`也会面临`proposer-1`同样的问题。于是，它们轮流更新编号，始终无法通过。这也就是所谓的活锁问题。`FLP`定理早就证明过即使允许一个进程失败，在异步环境下任何一致性算法都存在永不终止的可能性。论文后面提出为了避免活锁的问题，可以引入了一个`proposer leader`，由此`leader`来提出`proposal`。但事实上，`leader`的选举本身也是一个共识问题。而在工程实现上，存在一些手段可以用来减少两个提案冲突的概率（在`raft`中采用了随机定时器超时的方式来减小选票瓜分的可能性）。

最后，为了更好地理解`Paxos`算法时，补充（明确）以下几点。

- `Paxos`算法的目的是确定一个值，一轮完整的`paxos`交互过程值用于确定一个值。且为了确定一个值，各节点需要协同互助，不能"各自为政"。且一旦接受提案，提案的`value`就被选定。
- `Paxos`算法的强调的是值`value`，而不是提案`proposal`，更加不是编号。提案和编号都是为了确定一个值所采用的辅助手段。显然，当一个值被确定时，`acceptor`接受的提案可能是多个，编号当然也就不同，但是这些提案所对应的值一定是一样的。
- `Paxos`流程保证最终对选定的值达到一致，这需要一个投票决议过程，需要一定时间。

- 上面描述的大多流程都是正常情况，但毫无疑问，`acceptor`收到的消息有可能错位，比如 (1) `acceptor`还没收到`prepare`请求就直接收到了`accept`请求，此时要直接写入日志。(2) `acceptor`还未返回对`prepare`请求的确认，就收到了`accept`请求，此时直接写入日志，并拒绝后续的`prepare`请求。

- 因为节点任何时候都可能宕机，因此必须保证节点具备可靠的存储。具体而言，(1) 对于`proposer`需要持久化已提交的最大`proposal`编号、决议编号(`instance id`)（表示一轮`Paxos`的选举过程）。(2) 对于`acceptor`需要持久化已经`promise`的最大编号、已`accept`的最大编号和`value`以及决议编号。





参考资料

[1]. Lamport L. Paxos made simple[J]. ACM Sigact News, 2001, 32(4): 18-25.
[2]. https://blog.csdn.net/chen77716/article/details/6166675
[3]. [如何浅显易懂地解说 Paxos 的算法](https://www.zhihu.com/question/19787937)