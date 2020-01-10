---
title: The Log-Structured File System
date: 2020-01-09 21:49:19
categories:
- 单机存储
tags:
- 单机存储
- 文件系统
- 日志文件系统
- 崩溃恢复
mathjax: true
---

前面关于文件系统的三篇文章，分别总结了简单文件系统(`vsfs`)、快速文件系统(`FFS`)和保证文件系统（以简单文件系统示例）的崩溃恢复一致性(`crash consistency`)的两种主要解决方案：`fsck`和`journaling`。但已有文件系统的文件访问效率仍然远低于磁盘的`peek bandwidth`，因此伯克利研究人员 John Ousterhout 和他的学生  Mendel Rosenblum 研发了`log-structured file system`(`LFS`)，`LFS`专注于磁盘写操作性能的提升，使其尽量接近于磁盘的`peek bandwidth`，特别是对于那些存在大量小文件写入和更新的应用场景。顾名思义，`LFS`是一种日志类型文件系统，磁盘上存储全部是日志，日志包含元数据信息和文件数据块。具体而言，当文件系统发起写操作时，`LFS`首先将更新的相关数据块（包括元数据信息）以`segment`为单位缓存在主存，然后按顺序写入磁盘的一块连续区域。`LFS`不会覆盖或删除磁盘上已有数据，相反它将更新后的数据块（包括元数据）按顺序追加写入到空闲磁盘区域。通过将文件更新带来的随机写操作转化为顺序写`segment`到磁盘的方式，最大化了写操作效率，因此显著提升了文件系统的性能。从论文中提供的具体数据来看，它将旧文件系统的磁盘访问效率仅有 5% 到 10% 的`peek bandwidth`提升到 65% 到 75%。

<!-- More-->

众所周知，`vsfs`存在严重的磁盘访问效率问题，具体原因是它将磁盘上相关数据结构（如`inode`和`data block`，以及同一目录下的文件）分开存储，导致文件访问时，累计大量寻道和旋转操作，严重降低了磁盘吞吐量。而`FFS`则正是基于文件数据结构访问的空间局部性(`space locality`)，创造性地引入了`cylinder group`(`block group`)，以将文件`inode`及其关联的`data block`，以及同一目录下的文件存放于同一`block group`，避免大量寻道和旋转延时，但考虑到访问相关文件或目录时，它们并不是完全直接相邻，换言之，仍存在一些短的寻道和旋转开销。典型地，`FFS`创建一个文件需要 5 次写操作。另外，虽然`jounraling`模式通过顺序写`circular log`在保证系统能顺利从崩溃中恢复的同时，显著提升磁盘效率，但其存在的问题是，异步的`checkpoint`操作（将文件数据块和元数据信息真正写入磁盘）仍然存在定位开销。总而言之，已有文件系统的文件访问效率仍然远低于磁盘的`peek bandwidth`。

`FFS`的研发存在几个前提或动机：一方面，在文件系统[第一篇文章](https://qtozeng.top/2020/01/05/%E7%AE%80%E5%8D%95%E6%96%87%E4%BB%B6%E7%B3%BB%E7%BB%9F-vsfs/)中强调过，磁盘随机写操作速度比顺序写的速度慢大约两个数量级，而且随着技术不断发展，磁盘传输效率越来越高，但其旋转和寻道开销并没有相应地减少，因此二者之间的差距越拉越大；另一方面，同样随着技术成熟，系统主存也不断增长，换言之，原本因不能放入内存而带来的额外磁盘开销的情况已不复存在，主存通过缓存磁盘内容能提供较高的文件读取效率，在这种情况下，文件访问操作由文件的写操作主导；第三，如上所述，已有文件系统在很多应用场景下的性能表现糟糕。这三个前提或动机催生`LFS`的诞生。

本篇文章同样隶属于总结或启发性的文章，文章内容来源于书本 Operating Systems Three Easy Pieces [1]、`LFS`原论文[2]，以及一些课程参考资料[3]。因此读者若有兴趣，建议阅读原论文。后文从三个方面来详细阐述`LFS`，即`LFS`主要包含的三个部分：一是设计恰当数据结构，以保证高效地检索写入到磁盘的日志；第二，磁盘无用块的回收以备重复用，即垃圾回收(`garbage collection`)，这一部分相对更为复杂。最后是`lfs`实现的崩溃恢复(`crash recovery`)策略。总而言之，`LFS`思想是简单的，且容易理解，但仅仅了解这些并不够，更需要了解其成为一个完善的文件系统所必须具备的功能——`crash recovery`，这也是`LFS`的相当重要的一部分贡献。

# 从日志中高效检索数据

这一部分主题为如何构建日志位于磁盘的详细布局，从而允许我们获得高效的文件检索速率。我们以一种解决抛出问题的方式来阐述（希望这种方式能够让读者不仅能够知道日志构造细节，也能够理解日志如此设计的原因，因为这能帮助我们更多）。

## 一个简单磁盘日志结构设计

首先，既然是将对文件的更新或写入操作转化为日志条目，再顺序写入到磁盘的一段连续空闲区域。那么，这个转化过程具体又是如何进行的？简单地，从一个实例入手，对于创建一个新文件，我们可以在磁盘上顺序写入类似于下图的日志块：它同时将文件的数据块 $D$ 写入到磁盘的$A_{0}$地址处，并将索引数据块$D$的 `inode`写入到紧跟着$D$后面的位置（注意实际上 `inode`会比`data block`小很多）。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578646154/blog/34-Log-Structured-File-System/lfs-seq-inode_g0mw1j.png" alt="简单磁盘日志结构" style="zoom:50%;" />

## 如何设计 segment 的大小？

但能想象得到，仅仅将日志数据顺序写入磁盘并不能完全保证文件更新操作非常高效，这还取决于你每次顺序写入磁盘的日志大小，换言之，必须一次性写入较大块数据到磁盘才能最大程度均摊磁盘的定位开销。为了实现这一目的，我们引入`segment`的概念（实际上，`segment`的概念同样有利于`crash recovery`的实现，后文会详述）。具体而言，文件系统先将文件更新相关的数据块转化成日志条目并以`segment`为单位缓存于主存，通过设置合适的`segment`大小（几 $MB$，论文中是 512$KB$或1$1MB$），能够使得写操作非常高效。我们可以简单进行如下计算。其中$D$表示写入数据块大小，$R_{effective}$表示磁盘实际写速率，$T_{position}$表示一次写操作带来的定位开销（寻道延时和旋转延时），$R_{peak}$表示磁盘的`peek bandwidth`，最后$F$为预计的磁盘实际写速率和磁盘`peek bandwidth`的比值。
$$
R_{effective} = \frac{D}{T_{position}+D/R_{peak}} = F * R_{peak} \\
D = F * R_{peak} * (T_{position} + D/R_{peak}) \\
D = (F * R_{peak} * T_{position}) + (F * R_{peak} * D/R_{peak}) \\
D = \frac{F}{1-F} * R_{peak} * T_{position}
$$
从以上公式可知，假设定位开销为 10 ms，`peek bandwidth`为 100 $MB/s$，预计的 $F=90\%$， 那么可计算得，$D=9MB$。同样可计算出当实际的写速率达到`peek bandwidth`的 $95\%$甚至$99\%$，$D$的理论大小。由此可见，通过设置合适的$D$的大小取值，可使得磁盘实际写速率达到预计值。

## Inode Map

回到日志结构设计问题，我们在第一小节中按要求设计了最简单的日志结构原型。在`vsfs`中，`inode`以数组形式组织并且被写入到磁盘固定位置，如此一来，通过`inode`编号和`inode`区域首地址来检索指定`inode`容易计算得到。类似地，在`FFS`中，也可通过近似方法计算（仅仅是引入`block group`）。但这种通过简单计算方式获取`inode`在`LFS`却不起作用，考虑到`LFS`将所有文件的`inode`和`data block`分散存储在磁盘上，且无法简单确定最新版本`inode`地址。

`LFS`引入`inode map`来解决此问题。`inode map (imap)`的作用即作为`inode`和`inode number`的中转结构。顾名思义，它大体是一个字典数据结构，其通过`inode number`来索引对应最新版本的`inode`地址。但毫无疑问，`imap`必须持久化以应对系统崩溃情况，因此`LFS`选择将`imap`同样作为元信息存储在紧跟着`inode`的位置，换言之，每一次`inode`的更新，也会写入一个相应更新后的`imap`块（可以理解，之所以如此设计是为了尽可能避免磁盘的定位开销）。因此，当写入一个文件时，其写入磁盘日志的内容大概如下图所示。另外，需要强调的是，为了保证检索效率，`imap`会被缓存到主存，因此当通过一个`inode number`检索`inode`时，会先从内存的`imap`中检索对应`inode`地址，此后操作的开销同其它文件系统的检索开销相同。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578650908/blog/34-Log-Structured-File-System/lfs-seq-imap_nws50m.png" alt="lfs 加入 imap 后的日志结构" style="zoom:50%;" />

## Checkpoint Region

虽然通过`imap`可以方便索引到`inode`，但问题是如何方便且快速索引到`imap`呢（可以发现`imap`并没有固定地址）？因此，我们不得不引入一个具备固定地址的数据结构，通过此数据结构来索引`imap`，是的，`LFS`由此设计了`Checkpoint Region (CR)`。具体而言，`CR`包含直接索引最新版本的`imap`指针（其实还存储其它内容，后文阐述），且论文中将`CR`被设置成以 30s 的时间间隔更新到磁盘，换言之，因更新`CR`所造成的写操作开销可以接受。因此引入`CR`后，整个磁盘日志布局相应更新如下图。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578646154/blog/34-Log-Structured-File-System/lfs-seq-cr_i8jjrb.png" alt="lfs 加入 checkpoint region 后的日志结构" style="zoom:50%;" />

事实上，为了应对崩溃恢复，`CR`设计得更为复杂。但为了逻辑阐述清晰，将相关内容放到后文再阐述。

## 目录如何处理？

众所周知，在所有文件系统中，目录都被当成一种特殊的文件来对待，在`LFS`中也不例外，一个包含目录更新的简单日志结构如下图。因为目录仅仅是类似于`(name, inode number)`简单列表。换言之，目录也是通过`imap`来间接索引，和文件的`inode`索引没有区别。但正是因为引入了`imap`才避免了文件更新所存在的`recursive update problem`[4]，此问题存在于那些不对文件数据块就地更新的文件系统。简单而言，当我们更新一个文件时，事实上文件所在的目录（具体是目录所关联的`data block`）也需要被更新，类似地，一旦文件所在目录被更新，其父目录同样需要被更新，如此循环，直至根目录。`imap`的引入可避免此问题，因为此时只需要更新对应的`imap`即可，文件所在目录只包含了文件的`inode number`，并不会被级联更新，真正需要更新的只有`imap`，因此规避了`recursive update problem`。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578646156/blog/34-Log-Structured-File-System/lfs-seq-dir_kahgwz.png" alt="lfs 对目录的存储" style="zoom:50%;" />

至此，关于`LFS`为保证能高效地从日志中检索数据所做的工作（设计相应数据结构）已阐述完毕。事实上，还有其它用于`garbage collection`和`crash recovery`的数据结构未阐述，具体可见如下表（出自原论文）。

![lfs 中日志所包含的数据结构](https://res.cloudinary.com/turalyon/image/upload/v1578646154/blog/34-Log-Structured-File-System/lfs-datastructures_xz6k6t.png)

最后，阐述`LFS`从磁盘上读取指定文件的过程以小结此部分内容。首先我们必须从磁盘指定位置读取`CR`的内容，然后通过`CR`存储的关联`imap`指针以读取整个最新版本的`imap`到内存中。至此，预备工作已经完毕。此时若需根据`inode number`从磁盘检索相应的`inode`，`LFS`首先从缓存的`imap`中根据`inode number`查找对应的最新版本的`inode`地址，以`inode`地址读取`data block`的过程同其它文件系统的索引过程类似，即通过`direct pointer`或者`indirect pointer`等结构来读取。因此，`LFS`保证了文件访问操作的主导开销集中在文件写入操作，因为文件读取可通过缓存命中，对比其它文件系统，读操作开销并未加剧。

# 垃圾回收

读者可以注意到，`LFS`将每次文件更新后相关的数据块以日志形式顺序写入磁盘，这意味着磁盘上可能存放着一个文件的多个历史更新版本数据，但大部分情况下，仅有文件最新版本数据有价值。因此，如何有效清理文件历史版本数据是`LFS`重点考虑的问题（有些`version file system`[5]，相反选择保留旧版本文件数据，即通过引入文件历史版本这一功能特性来巧妙解决此问题）。

对于`LFS`而言，其选择周期性地清理那些旧的无用的文件数据，这包括元信息和数据块等。注意到，`LFS`使用`segment`来组织内存中的日志数据，这也使得其能够以`segment`的形式将日志存储在磁盘上，因此，在周期性清理无用日志数据时，可以以`segment`为单位清理，以便能够为后续日志顺序写入提供足够大的连续空闲区域（相反，如果以单个`data chunk`为单位进行回收，会导致有数据区域和无数据区域交叉布局在磁盘空间，因此难以提供连续的大的空闲段）。这就是引入`segment`的第二个目的。总而言之，`LFS`的清理过程大致如下：`LFS`首先从磁盘读入$M$个`segment`，然后确定其中那些活的(`live`)`block`，并将它们压缩成$N(N<M)$个新`segment`，然后写入磁盘上另外一段连续地址空间，最后将原来$M$个`segment`直接释放掉，以备后续日志写入。

## Segment Summary Block

虽然总的垃圾回收的步骤并不复杂，但有几个需要重点考虑的问题：其一，如何确定`segment`中哪些`block`是存活的（类似地，哪些是无用的）；另外，也需要标记哪些块隶属于哪些文件，以及其在文件中的偏移量（这些信息是必要的，因为在垃圾回收阶段，你需要更新文件的`inode`让它指向新的数据块位置）；

`LFS`引入`segment summary block`来解决这两个问题，`segment summary block`位于每条`segment`的开始位置。`sumarry block`标记了每条写入`segment`的信息。具体而言，对于每一个数据块，`summary block`为它记录了`inode number`和`offset`，一个`segment summary block`可包含多条`summary block`以应对`segment`存储多条日志的情况。值得注意的是，`segment summary block`也被用于`crash recovery`。

`segment summary block`也被用于识别那些存活块。简单而言，对于位于地址为$A$的数据块$D$，`LFS`首先从`segment summary block`中检索出其`inode number`$N$和`offset`$T$，然后再去`imap`中查找$N$所对应的`inode`的地址，然后读取`inode`，并通过文件偏移量$T$计算对应的数据块地址是否为$A$，若是，则表示此数据块仍然存活，否则为无用数据块。此过程的一个示例如下图。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578646154/blog/34-Log-Structured-File-System/lfs-data-isalive_arjoe2.png" alt="判断 segment block 是否存活" style="zoom:50%;" />

其也可用如下伪码表示。

```python
(N, T) = SegmentSummary[A]
inode = Read(imap[N])
if inode[T] == A:
    # block D is alive
else:
    # block D is garbage
```

另外，`LFS`使用`version number`来优化这个标记过程（避免了不必要的读操作）。具体而言，它在每个`imap`项中为每个文件保存一个版本号，当文件被删除或清空时，版本号会递增。版本号和`inode number`共同构成文件内容的标识符。因此，`segment summary block`为每个块记录了对应标识符，若一个块的标识符和当前存储在`imap`中的标识符不同，则表明此块是无用的。

关于`LFS`的清理策略，论文中提到有四个方面的问题需要被解决：
- 何时清理`segment`。这个问题较简单，可等到磁盘剩余空间低于某一阈值时清理，或者周期性清理；
- 单次清理`segment`的数量。显然一次性清理越多`segment`，空闲磁盘空间越大，但同时也带来更多开销；
- 哪些`segment`应该被清理。是否应该选择对碎片化(`fragmented`)最严重的`segment`进行清理？
- 那些存活的块应该如何被分组以写入到新的`segment`。一种方案是基于读的`space locality`，即同一目录下的块被组织到同一`segment`，另一种方案是基于读的`time locality`，即上一次修改时间接近的块被安排到同一`segment`。

`LFS`并没有详细考虑第一和第二个问题的解决方案，而是采取直接且简单的解决办法。具体地，当`LFS`发现空闲的`segment`的数量低于某一阈值（数十个），则开始启动清理程序。而且，它选择每次清理数十个`segment`直至空闲的`segment`的数量超过预设阈值（50 到 100 个）。之所以将阈值作为清理条件，是因为这些变量的具体取值和`LFS`的整体性能并不非常相关。相反，第三和第四个问题则和`LFS`的性能密切相关。

`LFS`通过引入`write cost`来度量清理策略的代价，`write cost`表示每写一个`byte`数据而带来的磁盘平均繁忙时间。若`write cost`取值为 1.0，则表示代价最小，此时没有任何垃圾清理开销，磁盘带宽全部用于写存活块。类似地，若`write cost`取值为 10.0，则表示只有 1/10 的磁盘带宽用于数据块写入。论文中给出了`write cost`的计算公式如下，其中$N$表示读入到内存的`segment`数量，$u$表示`block`的存活率。
$$
\begin{align*}
\text{write cost} &= \frac{\text{total bytes read and write}}{\text{new data written}}
= \frac{\text{read segs + wirte live + write new}}{\text{new data written}} \\
&= \frac{N+N*u+N*(1-u)}{N*(1-u)} = \frac{2}{1-u}
\end{align*}
$$
从公式中，可发现`write cost`和$u$密切相关，论文中给出具体模拟实验结果[2]。

## Segment Usage Table

`LFS`采取一种`cost-benefit`作为选择被清理的`segment`的策略，即选择那些具备最大`benefit-to-cost`比值的`segment`作为清理对象。其中的清理所带来的`benefit`包含两个部分，回收空闲空间大小$1-u$和此段回收空间能够维持空闲的时间$age$，且`LFS`使用`segment`中`block`最近修改时间（即最年轻的块）作为此段回收空间维持空闲时间的估计值。而`cost`同样包含两部分，整个`segment`读操作的开销$1$和写存活块到空闲区域的开销$u$。综上，`benefit-to-cost`的计算公式为：
$$
\frac{\text{benefit}}{\text{cost}} = \frac{\text{free space generated * age of data}}{\text{cost}} = \frac{(1-u)*\text{age}}{1+u}
$$
`LFS`为了实现`cost-benefit`策略，引入`segment usage table`的概念。具体地，对于每一个`segment`，`segment usage table`记录了`segment`中存活块的大小以及每个块的最近修改时间。且`segment usage table`本身同样被写入到每个`segment`，其地址同样被记录在`CR`中。为了计算每个`segment`的`cost-to-benefit`的值，只需按照每个存活块的$age$进行排序（因为$u$可以通过存活块大小比上整个`segment`的大小获得）即可（注意，论文中提到，`LFS`记录的是整个文件最近被更新的时间，而不是单个块）。

至此，关于`LFS`日志中无用块的回收策略相关部分已经阐述完毕。总而言之，`LFS`总的清理过程比较简单，但为了提高清理效率或者提高整个`LFS`的效率，需要重点考虑两个问题，第一个是如何判断某个`segment`需要被清理，`LFS`给出了两种解决办法，其中一种引入了`segment summary block`，另一种优化措施则采用版本号机制；第二个问题是如何选择哪些`segment`作为此次清理对象，`LFS`通过计算每个`segment`的`benefit-to-cost`的值来获取最合适的清理对象。

# 崩溃恢复

那么`LFS`如何处理崩溃恢复呢？崩溃恢复是为了维持磁盘相关数据结构的一致性。旧文件系统必须扫描整个文件系统才能确定在系统崩溃时哪些数据结构发生了哪些变更。上一节的[崩溃一致性和日志](https://qtozeng.top/2020/01/07/%E7%AE%80%E5%8D%95%E6%96%87%E4%BB%B6%E7%B3%BB%E7%BB%9F%E7%9A%84%E5%B4%A9%E6%BA%83%E4%B8%80%E8%87%B4%E6%80%A7%E5%92%8C%E6%97%A5%E5%BF%97/)的主题为提高崩溃恢复效率。而对于`LFS`而言，无论系统何时崩溃，其导致的数据结构变更只能位于日志末尾位置，因此，崩溃恢复过程的执行更为迅速（这一特性也被应用于数据库管理系统和其它文件系统）。

具体而言，我们知道，大体上，写入磁盘的日志包括两个部分：`CR`和`segment`。换言之，我们只需要考虑这两个结构写入磁盘的过程中发生系统崩溃时，应该分别如何处理。`LFS`使用`checkpoint`和`roll-forward`来分别解决这两个问题。前者定义了磁盘某一时刻的一致性状态，而后者用于恢复最后一次`checkpoint`后又执行的更新操作所带来的变更。

在`LFS`的`checkpoint`操作包括两个阶段：首先将更新的数据写入磁盘（包括`data block`、`inode`、`imap`、`segment summary block`和`segment usage table`）；其次，将`CR`写入到磁盘固定位置（以 30s 为周期写入），`CR`中包含了`imap`、`segment usage table`和指向最后一个`segment`的指针的地址，以及写入时间戳。

## Checkpoint

为保证`CR`写入磁盘的原子性，`LFS`采取两个方法，一个是`CR`实际上会被交替写入到磁盘两端，当需要读取`CR`时，选择具有最新完整时间戳的版本；另外，在`CR`包含区域的首尾加入写入时间戳，因此一旦写入`CR`时系统崩溃，则读取此`CR`记录时，不可能获得两个相同的写入时间戳。因此正常情况下，在系统重启后，通过读取`CR`的内容，可以获得最后一次`checkpoint`操作时的`imap`等数据结构的地址信息，因此可顺利重构出最后一次`checkpoint`操作时的全局日志结构。

## Roll-Forward

理论上，若用户只需粗糙地恢复磁盘数据，则通过`checkpoint`来恢复即可满足要求。但其不足之处在于，它忽略了最后一次`checkpoint`操作后对磁盘执行的变更，这在某些情况下是不能接受的，因此，`LFS`采用`roll-forward`的方式来进行细粒度的崩溃恢复。`roll-forward`会利用保存在`segment summary block`中的信息来恢复最近的更新操作。具体地，若`segment summary block`中保存的信息表明一个新的`inode`的存在，`LFS`则更新`imap`以指向最新的`inode`。另外，`roll-forward`也会调整`segment usage table`记录的`segment`的利用率$u$。`roll-forward`所解决的最后一个问题是目录中目录项和对应`inode`的一致性问题，因为在更新`inode`的`reference count`和写入数据这两个操作之间可能发生系统崩溃。为了顺利恢复目录和`inode`的一致性，`LFS`在每条日志中额外增加了一条被称为`directory operation log`的记录，且`LFS`确保在每条日志中的`directory opearation log`会出现在对应的目录数据块或`inode`块之前。具体细节读者可参考原论文[2]。

至此，关于`LFS`如何提供崩溃恢复功能的内容已经阐述完毕。简单而言，`LFS`通过两种手段以从粗粒度和细粒度双管齐下地执行崩溃恢复。具体而言，通过巧妙设计`CR`的数据结构，崩溃恢复过程中的简单`checkpoint`操作即能保证系统恢复到崩溃前的最后一次`checkpoint`时刻的一致性状态；然后再通过`roll-forward`从最后一条`segment`开始实施文件级别的恢复操作。

简单小结。本文从三个方面简单介绍了`LFS`。`LFS`的核心思想容易理解，将对于磁盘上文件更新所带来的随机写入操作转化为批量的按顺序以`segment`为单位写入磁盘的操作，以尽可能接近磁盘带宽来执行写入操作（这种技术在数据库领域被称为是`shadow paging`，而在文件系统领域则被称为是`copy-on-write`）。关于`LFS`，我们首先需要清楚`LFS`诞生的前提或实现的动机；其次，对于一个文件系统，需要保证能够高效地检索文件数据内容。因此理解`LFS`如何组织文件相关的元数据和数据块信息至关重要；另外，考虑到`LFS`并未直接更新磁盘上的数据块，而采用将更新转化成日志的形式顺序写入磁盘的方式，因此，必须解决由此产生的无用的历史版本文件数据的问题。最后，崩溃恢复是一个文件系统必备的功能，`LFS`从粗粒度和细粒度两个角度分别使用`checkpoint`和`roll-forward`来解决崩溃恢复的问题。





参考文献
[1]. Arpaci-Dusseau R H, Arpaci-Dusseau A C. Operating systems: Three easy pieces[M]. Arpaci-Dusseau Books LLC, 2018.
[2]. Rosenblum M, Ousterhout J K. The design and implementation of a log-structured file system[J]. ACM Transactions on Computer Systems (TOCS), 1992, 10(1): 26-52.
[3]. http://www.eecs.harvard.edu/~cs161/notes/lfs.pdf
[4]. Zhang Y, Arulraj L P, Arpaci-Dusseau A C, et al. De-indirection for flash-based SSDs with nameless writes[C]//FAST. 2012: 1.
[5]. Hitz D, Lau J, Malcolm M A. File System Design for an NFS File Server Appliance[C]//USENIX winter. 1994, 94.





















