---
title: The Fast File System
date: 2020-01-06 19:26:36
categories:
- 单机存储
tags:
- 单机存储
- 文件系统
---

上一篇文章从文件系统所使用的数据结构和典型文件访问操作流程两个方面，简要介绍一个简单文件系统(`vsfs`)原型。其目的主要在于理解一个最基本的文件系统的核心，并且如何理解和学习一个文件系统，是一篇总结和启发性的文章。本文从简单文件系统或早期 unix 系统所使用的文件系统存在的典型问题出发，引出更优秀的文件系统——`The Fast File System`，它在兼容已有文件系统接口规范的前提下，对已有文件系统存在的问题，针对性进行优化以提升文件系统的访问和存储效率，同时进一步提升系统的易用性。

<!-- More-->

同上一篇文章类似，本文也是一篇总结和启发性的文章。其来源于书籍 operating systems three easy pieces，以及相应的原始论文 The Fast File System。若读者对其中的细节感兴趣，推荐阅读原文。`The Fast File System (FFS)`是对早期 Unix 所使用的文件系统的重实现，它通过使用更灵活的数据块分配策略(`allocation policies`)以增强数据块访问的本地性(`locality`)，最终显著提升磁盘访问的吞吐率，另外它提供多个数据块大小作为选择，以适应不同文件大小的情形，同时也提升了文件的存储利用率，最后它还提出了一系列的能够提升系统易用性的功能。本文先简单介绍早期文件系统存在的典型的问题，然后再从上述几个方面介绍`FFS`。

# 早期文件系统存在的问题

早期文件系统性能很糟糕，通常只能达到磁盘总带宽的 2%。造成磁盘低访问效率的根本原因是：将磁盘当成一块支持随机访问的内存来使用，导致每次磁盘访问操作的定位开销非常大。换言之，文件系统的设计没有充分考虑磁盘的顺序访问的效率比随机访问的效率高出接近两个数量级这一本质特性。

具体而言，磁盘访问效率较低包括几个典型的原因：一方面，文件所对应的`inode`和其索引的`data blocks`跨越多个磁道，因此，当由`inode`索引对应的`data blocks`时存在较大的寻道延时；其次，早期文件系统采用链表实现，即使用链表将空闲块链接起来，此种实现方式较为简单，但其存在的问题是：当文件被反复删除和创建时，原本存储于磁盘上一段连续区域的文件，被其它文件分割成多个离散片段，即访问逻辑上连续的文件的操作，最终映射到了物理磁盘上碎片化的随机访问，这严重降低了文件访问效率（很多磁盘整理小工具的基本原理即为磁盘碎片整理）。另外一个则是关于数据块大小的问题，早期文件系统所使用的数据块大小为 512b，一个较小的取值，小数据块大小导致大文件包含过多的元数据信息，并且也会导致数据块的传输速率下降（频繁累计寻道和旋转延时）。但小数据块大小有利于存储效率的提升，因为它减少了内部碎片。数据块大小的设计是个典型的`trade-off`。

# The Fast File System

`FFS`是 Berkeley 研究实现的一个文件系统。它的一个核心设计原则是`disk aware`。所谓`disk aware`指的是文件系统的设计考虑到了底层磁盘的结构，通过最优化数据的存储布局，以提升磁盘的访问效率。同时，值得提倡的是，它很好地遵循已有文件系统的接口规范，只更改增强了接口内部的实现，因此，能够很方便将`FFS`嵌入到已有系统中以替换原有文件系统，这也使得很多现代优秀的文件系统的设计一直延续这一准则。

## 优化数据结构布局

根据磁盘自身的构造特点，`FFS`首先将整个磁盘划分成一组`cylinder group`，其中`cylinder group`是由若干个相邻的`cylinder`构成。下面是一个示意图。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578451856/blog/32-The-Fast-File-System/ffs-cylinder-group_jbeomr.png" alt="磁盘的 cylinder group 结构" style="zoom:50%;" />

但考虑到现代磁盘并没有将磁盘本身构造细节暴露给上层文件系统，因此文件系统也无法利用这些细节。但类似地，现代的一些文件系统（包括`ext2`、`ext3`和`ext4`）将整个磁盘抽象后的大数组划分为若干个`block group`，其中每个`block group`包含若干个连续数据块。换言之，文件系统将`cylinder group`抽象成`block group`，它是`FFS`提升文件访问效率的一个核心设计。而且，`FFS`将每个`block group`作为一个独立的区域，即其中包含了所存储文件相关的所有信息（同`vsfs`设计类似，包括`data blocks`、`inodes`、`i-bmap`、`d-bmap`和一个`superblock`）。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578451856/blog/32-The-Fast-File-System/ffs-block-group_ioiafd.png" alt="文件系统使用的 block grouop 结构" style="zoom:67%;" />

`FFS`引入`block group`的设计结构是为了优化数据块的布局方式。`FFS`对数据块的组织布局的核心原则是：`keep related stuff together`，即将相关的数据结构存储在一起。这主要包含两个方面：一对于同一文件其所涉及的数据结构存储在同一`block group`；另外，对于同一目录下的文件和目录项所涉及的数据结构存储在同一`block group`。以一个实例来阐述。比如存在四个文件`/a/c`、`/a/d`、`/a/e`和`/b/f`，那么`FFS`会将`a`、`c`、`d`和`e`存储到同一`block group`，而将`b`和`f`共同存储到另一个`block group`，示意图如下。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578451856/blog/32-The-Fast-File-System/ffs-layout-related_sozltf.png" alt="FFS 所改进的数据块布局方式" style="zoom:50%;" />

作为一个错误的设计示例。原有的旧的文件系统为了提升磁盘的利用空间，会尽量保证数据块的均匀分布，因此它更倾向于将不同的文件分散存储在不同的`block group`中。在这种情况下，当访问同一目录下的文件，会引发较多寻道操作，降低了访问效率。

<img src="https://res.cloudinary.com/turalyon/image/upload/v1578451856/blog/32-The-Fast-File-System/ffs-layout-mess.png_gjk3iz.png" alt="一种糟糕的数据块布局方式" style="zoom:50%;" />

事实上，`FFS`所遵循的这两种数据块存放策略存在相应依据。换言之，文件系统的使用中存在大量的对应使用场景。一方面，将文件的`inode`及其对应`data blocks`存放在同一`block group`这是显然的。其次，同一目录下的文件通常会被同时访问，比如使用`gcc`编译项目目录下的源文件。本质上是因为同一目录下的文件或目录其相关性较大。

最后，此种数据块的布局方式对于大文件而言却是一个例外。可以预料到，大文件可能会填满整个`block group`，这导致其它同它相关的文件不得不存放到其它的`block group`。对此，`FFS`的改进后的布局策略是：将一个大文件分成若干个大的`chunk`，每个`chunk`存放在一个`block group`上，这样后续同其有关联的文件，就能够同样存放到同一`block group`。但这有一个明显的弊端，将大文件分成多个`chunk`分开存放将导致访问大文件本身的开销显著增大（寻道操作增加）。但事实上增加的开销取决于每个`chunk`的大小，换言之，理论上只要`chunk`够大，那么传输单个`chunk`所包含数据的时间将基本抵消对相邻`chunk`的寻道开销，这是一种典型的`amortization`策略。简单计算，如果磁盘的`peek bandwidth`是 50kb/s，那么若想达到 50% 的`peek bandwidth`（即一半时间开销用于数据传输，一半用于寻道和旋转操作），只需要将`chunk`的大小设置成 409.6 kb 即可。同样，当取得 90% 的`peek bandwidth`时，相应的`chunk`大小为 3.69mb。但事实上，`FFS`并非通过增加大文件的`chunk`的大小，而是采用一种更符合实际情况的解决方案，将大文件所包含的`direct pointer`(12个) 存放到第一个`block group`中，而将后续的每一个`indirect pointer`及其数据块分别存放到不同的`block group`中。显然，这是考虑在到绝大部分情况下，文件都只由直接指针构成。

## 数据块大小设置

数据块大小的设置面临的问题是：过小的取值会影响数据传输效率（因为这将导致过多的寻道操作），而过大的取值会造成过多的内部碎片，降低了磁盘的利用率。`FFS`通过引入`sub-block`来解决这个问题。具体而言，当应对小文件的存储时，它会分若干个`sub-block`，当随着文件大小的增长超过 4kb 时，会将已分配的数据进一步拷贝到以 4kb 为单位的数据块，同时释放文件原来占用的`sub-block`。但这也存在一个问题，即连续不断的拷贝也会降低性能。`FFS`针对性地修改`lib`库通过缓存对文件的写入，并尽量以 4kb 为大小写入磁盘，来缓解这一问题。

另外，论文中还介绍了`FFS`引入的一种`parameterization`策略，详情可参考原论文。

## 功能性增强

所谓的功能性增强(`Functional Enhancements`)指的是：通过增强已有文件系统的功能，来改善系统的可用性。`FFS`做了较多的改进，包括

- 支持`long file names`，改进旧的文件系统只能支持固定长度的较短的文件名称的缺陷；
- 引入`symbolic link`，旧的文件系统只支持`hard link`，硬链接有较大限制，比如不能跨分区链接，且禁止链接到目录以避免循环链接；
- 引入`rename`系统调用以原子性地重命名文件；
- 引入了`advisory shared/exclusive locks`以方便地构建并发程序；
- 引入了`Quotas`机制，让管理员能更合理地对每个用户实施配额限制，包括具体到`inode`和`data block`数目的限制。

简单小节。本文简单介绍了`Fast File System`，它对旧的 unix 文件进行了改进。具体而言，以`disk aware`为设计准则，通过优化磁盘数据结构的存储布局，提升了文件的访问效率；同时引入一种`sub-block`的策略，来尽可能适应不同的文件存储情形，以提高系统的存储和访问效率；最后在遵循已有文件系统接口规范的前提下，增强已有功能的内部实现，以提升系统的易用性。总而言之，`FFS`有许多优秀的设计理念和方法值得学习和借鉴，这有助于学习和改进其它更加先进的文件系统。





参考资料
[1]. Arpaci-Dusseau R H, Arpaci-Dusseau A C. Operating systems: Three easy pieces[M]. Arpaci-Dusseau Books LLC, 2018.
[2]. McKusick M K, Joy W N, Leffler S J, et al. A fast file system for UNIX[J]. ACM Transactions on Computer Systems (TOCS), 1984, 2(3): 181-197.