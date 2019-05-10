---
title: 理解 The Google File System
date: 2018-11-11 18:36:36
categories:
- 分布式系统
- 分布式文件系统
tags:
- 分布式系统
- 分布式文件系统
- GFS
---

分布式文件系统是构建整个分布式系统的基石，为分布式计算提供底层数据存储。谷歌早在 2013 年就发表了论文 `The Google File System`，它在谷歌内部是配合其分布式计算框架`MapReduce`使用，共同为谷歌搜索等业务提供技术栈支撑。虽然数据量激增以及技术革新使得`GFS`不断演进，但理解其最初的设计理念、运行原理以及关键实现技术同样让人受益匪浅，并指导着我们实际的学习和工程实践。这篇博文阐述个人对原论文的一些理解与心得，并不是对原论文的完整翻译，因此你需要提前阅读论文。

<!--More-->

## 设计动机与目标

设计一个通用的分布式文件系统是不现实的，它不仅在实现上异常困难（因为不得不考虑所有应用场景），而且实际使用也难以满足要求（往往存在显而易见的性能或容错瓶颈）。[GFS](https://static.googleusercontent.com/media/research.google.com/en//archive/gfs-sosp2003.pdf) 设计初衷是利用数以千计的廉价机器为`MapReduce`提供底层**可靠且高性能**的分布式数据存储，以应对海量离线数据存储与处理的应用场景，比如存储应用程序持续产生的日志流以提供离线日志分析。由此，其设计目标为容错可靠(`fault tolerance`)、高性能读写(`high-performance read&write`)以及节约网络带宽(`save bandwidth`)。

一致性(`consistency`)是分布式系统不可回避的问题。对于分布式文件系统而言，为了提供容错，必须维持数据副本(`replica`），那如何保证各副本间一致显得至关重要，特别是在应用并发访问场合。一致性是个极其宽泛的术语，你可以实现数据的强一致性(`strong consistency`)以保证用户始终读到的是最新的数据，这对于用户（客户端）而言是个极佳选择，但它提高了系统的实现难度，因为你必须设计复杂的一致性协议（如`Paxos`或`Raft`）来实现强一致性，它也会损害系统性能，典型的它需要机器之间通信以对副本状态达成一致。而弱一致性(`weak consistency`)则几乎相反。因此，必须根据特定的应用场景，在保证系统逻辑正确的提前下，放宽一致性要求，设计具备良好性能且能提供**足够的一致性**(`sufficient consistency`)的系统。对于`GFS`而言，它针对`MapReduce`应用程序进行了特定优化，比如，对**大文件高性能读取**、允许出现**文件空洞**(`hole`)、数据**记录重复**(`record duplicate`)以及偶尔**读取不一致**(`inconsistent reads`)。具体在数据读写方面，其侧重于大规模一次性写入和追加写入，而并非覆盖写和随机写；读取同样倾向于顺序读取，并不关心随机读取。

## Trade-off 理念哲学

`GFS`在设计上存在大量的`trade-off`。正如前文所述，你不能企图设计出一个完美的系统，而只能针对具体应用场景作出各方面的权衡考量，以达到工程最佳实践目的。

`chunk`大小设计。`GFS`针对大文件存储（数百上千兆）设计，因此若存储大量小文件则不能体现其性能。其默认块大小为 64MB。选择大文件作为存储目标原因如下：首先它减少了`client`与`master`的交互次数（即使`client`并不需要整个数据块，但实际上往往存在“就近原则”）；另外，这也直接减少了网络带宽；最后，它减少了存储在`master`内存中的元数据(`metadata`)的大小。但凡事总利弊相随。较大的块大小设定使得小文件也不得不占用整个块，浪费空间。

集群元数据‘存储。在`master`的内存中存放着三种类型的元数据：文件和`chunk`的名称空间(`namespace`)、文件到`chunk`的映射信息以及`chunk`副本的位置信息。且前两种元数据会定期通过`operation log`持久化到磁盘以及副本冗余。为什么将这些元信息存储到内存？一方面，缓存在内存无疑会提高性能，另外它也不会造成内存吃紧，因为每个64MB 的`chunk`只会占用到 64B 的内存空间（粗略估算普通 2G 内存的机器可以容纳 2PB 数据），而且为机器增加内存的代价也很小。那为什么`chunk`位置信息没有持久化？首先`master`在启动的时候可以通过`heartbeat`从各`chunk server`获取。另一方面，`chunk`的位置信息有时会变动频繁，比如进行`chunk garbage collection`、`chunk re-replication`以及`chunk migration`，因此，若`master`也定期持久化`chunk`位置信息，则`master`可能会成为集群性能`bottleneck`。从另一个角度来看，`chunck`是由`chunk server`保存，而且随时可能发生`disk failure`而导致`chunk`暂时不可被访问，因此其位置信息也应该由`chunk server`负责提供。

`chunk`副本（默认3个）存放策略。`chunk`副本选择目标机器的原则包括两个方面：一是最大化数据可靠性(`reliability`)及可用性(`availability`)，这就要求不能把所有的副本存放在一台机器上，如果此机器的发生`disk failure`，则数据的所有副本全部不可用。放在同一个机架也类似，因为机架之间的交换机或其它网络设计也可能出现故障。另外一个原则是，最大化网络带宽，如果两个副本的位置相隔太远，跨机架甚至跨数据中心，那么副本的写复制代价是巨大的。因此一般的存放位置包括本机器、同一机架不同机器以及不同机架机器。

垃圾回收。当一个文件被删除，`GFS`不会真正回收对应的`chunk`，而只是在`log operation`记录删除日志后，将对应的文件名设置为隐藏。在一定期限内（默认3天），用户可以执行撤销删除操作。否则，`master`会通过其后台进程定期扫描其文件系统，回收那些隐藏的文件，并且对应的元数据信息也会从内存中擦除。另外，`master`的后台进程同时还会扫描孤儿块(`orphaned chunk`)，即那些不能链接到任何文件的`chunk`，并将这些`chunk`的元信息删除，这样在后续的`heartbeat`中让`chunk server`将对应的`chunk`删除。这种垃圾回收机制的优点如下：其一，很明显允许用户作出撤销删除操作。其二，统一管理的垃圾回收机制对于故障频繁的分布式系统而言是便捷且可靠的（系统中很容易出现孤儿块）；最后，也有利于提升系统性能。垃圾回收发生在后台进程定期扫描活动中，此时`masetr`相对空闲，它不会一次性将大量文件从系统移除，从而导致 IO 瓶颈，换言之，其`chunk`回收成本被**均摊**(`amortized`）。但其同样有缺点：如果系统中一段时间内频繁出现文件删除与创建操作时，可能使得系统的存储空间紧张（原论文中也提供了解决方案）。

## 一致性模型 和 原子 Record Append

前文提到`GFS`并没有采用复杂的一致性协议来保证副本数据的一致性，而是通过定义了三种不同的文件状态，并保证在这三种文件状态下，能够使得客户端看到一致的副本。三种状态描述如下：`GFS`将文件处于`consistent`状态定义为：当`chunk`被并发执行了操作后，不同的客户端看到的并发执行后的副本内容是一致的。而`defined`状态被定义为：在文件处于`consistent`状态的基础上，还要保证所有客户端能够看到在此期间对文件执行的所有并发操作，换言之，当文件操作并发执行时，如果它们是全局有序执行的（执行过程中没有被打断），则由此产生的文件状态为`defined`（当然也是`consistent`）。换言之，如果某一操作在执行过程中被打断，但所有的并发操作仍然成功执行，只是对文件并发操作的结果不能反映出任一并发操作，因为此时文件的内容包含的是各个并发操作的结果的混合交叉，但无论如何，所有客户端看到的副本的内容还是一致的，在这种情况下就被称为`consistent`。自然而然，如果并发操作文件失败，此时各客户端看到的文件内容不一致，则称文件处于`undefined`状态，当然也处于`inconsistent`状态。

我们先区分几种不同的文件写类型：`write`指的是由应用程序在写入文件时指定写入的`offset`；而`append`同样也是由应用程序来指定写入文件时的`offeset`，只是此时的`offset`默认为文件末尾；而`record append`则指的是应用程序在写入文件时，只提供文件内容，而写入的`offset`则由`GFS`来指定，并在写成功后，返回给应用程序，而`record append`操作正是`GFS`提供一致性模型的关键，因为它能够保证所有的`record append`都是原子的(`atomic`)，并且是`at least once atomically`。这一点并非我们想像的简单，其所谓的`at least once atomic`，并不表示采用了`atomic record append`后，即使在客户端并发操作的情况，也能保证所有的副本完全相同(`bytewise idetical`)，它只保证数据是以原子的形式写入的，即一次完整的从`start chunk offset`到`end chunk offset`的写入，中间不会被其它操作打断。且所有副本被数据写入的` chunk offset`是相同的。但存在这种情况，`GFS`对某一副本的执行结果可能会出现`record duplicate `或者`inset padding`，这两种情况的写入所占居的文件区域被称为是`inconsistent`。而最后为了保证应用程序能够从所有副本看到一致的状态，需要由应用程序协同处理。

如果文件的并发操作成功，那么根据其定义的一致性模型，文件结果状态为`defined`。这通过两点来保证：其一，对文件的副本应用相同的客户端操作顺序。其二，使用`chunk version number`来检测过期(`stale`)副本。

`record append`操作流程如下：客户端首先去请求`master`以获取`chunk`位置信息，之后当客户端完成将数据 push 到所有`replica`的最后一个`chunk`后，它会发送请求给`primiary chuck server`准备执行`record append`。`primary`首先为每一个客户端操作分配`sequence number`，然后立即检查此次的`record append`操作是否会使得`chunk`大小超过`chunk `预设定的值（64MB），若超过了则必须先执行`insert padding`，并将此操作命令同步给所有副本`chunk server`，然后回复客户端重新请求一个`chunk`并重试`record append`。如果未超过`chunk`阈值，`primary`会选择一个`offset`，然后先在本地执行`record append`操作，然后同样将命令发送给所有副本`chunk server`，最后回复写入成功给客户端。如果副本`chunk server`在执行`record append`的过程中宕机了，则`primary`会回复客户端此次操作失败，要求进行重试。客户端会请求`master`，然后重复上述流程。此时，毫无疑问会造成副本节点在相同的`chunk offset`存储不同的数据，因为有些副本`chunk server`可能上一次已经执行成功写入了所有数据(`duplicate record`)，或者写了部分数据(`record segment`)，因此，必须先进行`inset padding`，使得各副本能够有一个相同且可用的`offset`，然后才执行`record append`。`GFS`将这种包含`paddings & record segments`的操作结果交由应用程序来处理。

应用程序的`writer`会为每个合法的`record`在其起始位置附加此`record`的`checksum`或者一个`predictable magic number`以检验其合法性，因此能检测出`paddings & record segments`。如果应用程序不支持`record duplicate`（比如非幂等`idempotent`操作），则它会为每一个`record`赋予一个`unique ID`，一旦发现两个`record`具有相同的`ID`它便认为出现了`duplicate record`。由`GFS`为应用程序提供处理这些异常情况的库。

除此之外，`GFS`对`namespace`的操作也是原子的（具体通过文件与目录锁实现）。

我们再来理解为什么`GFS`的`record append`提供的是`at least once atomically`语义。这种一致性语义模型较为简单（简单意味着正确性易保证，且有利于工程实践落地，还能在一定程度上提升系统性能），因为如果客户端写入`record`失败，它只需要重试此过程直至收到操作成功的回复，而`server`也只需要正常对等待每一个请求，不用额外记录请求执行状态（但不表示不用执行额外的检查）。除此之外，若采用`Exactly-once`语义模型，那将使整个实现变得复杂：`primary`需要对请求执行的状态进行保存以实现`duplicate detection`，关键是这些状态信息必须进行冗余备份，以防`primary`宕机。事实上，`Exactly-once`的语义模型几乎不可能得到保证。另外，如果采用`at most once`语义模型，则因为`primary`可能收到相同的请求，因此它必须执行请求`duplicate detection`，而且还需缓存请求执行结果（而且需要处理缓存失效问题），一旦检测到重复的请求，对客户端直接回复上一次的请求执行结果。最后，数据库会采用`Zero or once`的事务语义(`transactional semantics`)模型，但严格的事务语义模型在分布式场景会严重影响系统性能。

## 延迟 Copy On Write

快照(`snapshot`)是存储系统常见的功能。对于分布式系统而言，一个关键挑战是如何尽可能地降低`snapshot`对成百上千的客户端并发访的性能影响。`GFS`同样采用的是`copy on write`技术。事实上，它延迟了`snapshot`的真正执行时间点，因为在分布式系统中，副本是必须的，大多数情况下，快照涉及的副本可能不会被修改，这样可以不用对那些副本进行 copy，以最大程度提升系统性能。换言之，只有收到客户端对快照的副本执行`mutations`才对副本进行 copy，然后，将客户端的`mutations`应用到新的副本。具体的操作流程如下：当`master`收到客户端的`snapshot`指令时，首先会从`primary`节点`revoke`相应`chunk`的`lease`（或者等待`lease expire`），以确保客户端后续对涉及`snapshot`的`chunk`的`mutations`必须先与`master`进行交互，并对这些操作执行`log operation`，然后会对涉及到的`chunk`的`metadata`执行`duplicate`操作，并且会对`chunk`的`reference count`进行累加（换言之，那些`chunk reference count`大于1的`chunk`即表示执行了`snapshot`）。如此一来，当客户端发现对已经快照的`chunk`的操作请求时，`master`发现请求的`chunk`的`reference count`大于1。因此，它会先`defer`客户端的操作请求，然后选择对应`chunk`的`handler`并将其发送给对应的`chunk server`，让`chunk server`真正执行`copy`操作，最后将`chunk handler`等信息返回给客户端。这种`delay snapshot`措施能够改善系统的性能。

最后，值得注意的是，虽然客户端并不缓存实际的数据文件（为什么？），但它缓存了`chunk`位置信息，因此若对应的`chunk server`因宕机而`miss`了部分`chunk mutations`，那客户端是有可能从这些`stale`的`replica`中读取到`premature`数据，这种读取数据不一致的时间取决于`chunk locations`的过期时间以及对应的文件下一次被`open`的时间（因为一旦触发这两个操作之一，客户端的`cache`信息会被`purge`）。



参考文献：

[1] Ghemawat S, Gobioff H, Leung S T. The Google file system[M]. ACM, 2003.
[2].[MIT 6.824 Lecture](https://pdos.csail.mit.edu/6.824/)