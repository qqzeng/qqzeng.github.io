---
title: MapReduce 原型实现
date: 2018-11-16 22:53:42
categories:
- 分布式系统
- 分布式计算框架
tags:
- 分布式系统
- 分布式计算框架
- MapReduce
---

`MapReduce` 最早是由谷歌于 2004 年在操作系统顶会 OSDI 上发表的一篇面向大规模数据处理的分布式计算框架（并行计算模型）论文中提出。`MapReduce`使用 `Google File System` 作为数据存储，支撑起了谷歌全网搜索等大规模数据存储与处理业务。`MapReduce` 对于大规模数据的高效处理体现在三个方面：其一，大规模数据并行处理，分而治之；其二，`MapReduce`编程模型；最后，`MapReduce`运行时环境（失败恢复、任务调度以及负载均衡等）。它简化了并行编程，使得开发人员很容易编写出高效且具备容错能力的并行化程序。

<!--More-->

博客基于 MIT 6.824 (2018) 的课程 Lab1。整个实验实现了`MapReduce`原型，并且对其关键特性进行测试，主要包括`MapReduce`编程模型，集中在 `Map`与`Reduce`两个阶段，以及任务失败处理。在阅读原论文 [MapReduce](https://pdos.csail.mit.edu/6.824/papers/mapreduce.pdf) 的基础，Lab1 能够让我们对 `MapReduce`原理有更为深刻的理解，也能够提高我们实现分布式系统的实践能力，这包括节点通信模型、系统构建框架以及诸如失败恢复机制等。而且，仔细阅读整个 Lab 的代码可以学习到很多原理及设计知识，而不仅仅是完成其 Lab 任务。下文会简单介绍整个 Lab1 框架，然后阐述几个关键点（模块）。

## Sequential 及 Distributed 运行模式

Lab1 实现了两种不同运行模式的`MapReduce`原型框架：一种是`Sequential`运行模式，它顺序编程实现`MapReduce`过程，也不具备容错功能，因此并非真正意义上的实现。具体地，基于此种运行模式，所有`task`串行执行且`Map`与`Reduce`两个阶段也是串行执行，且未提供任务执行失败的恢复机制。大概地，它首先创建输入文件并读取`Map`输入，同时创建对应数量的`Map task`（即循环调用`Map`函数来处理输入文件），并顺序调度执行，将中间结果写到磁盘上，当所有`Map task`执行完成后，启动一定数量的`Reduce task`，并让`Reduce task`从本地磁盘相应位置读取`Map task`输出，同样被顺序调度执行，最后，将`Reduce task`输出写到本地磁盘，最终`merge`所有输出文件，以合并写到本地输出文件。

另一种是 `Distributed`运行模式，它更接近真实的`MapReduce`原型框架实现。客户端会依次启动一个`master`节点及多个`slave`节点(go 的`goroutine`)，并将输入文件信息传给`master`节点，此后客户端会阻塞等待`master`返回 。`master`启动后开始监听`slave`的连接(`one client one goroutine`），`slave`启动后会主动往`master`节点注册，并等待`master`分配任务。所有节点通过`go rpc`实现对等通信。一旦有`slave/worker`注册成功，`master`开始实施任务调度，通过`rpc`将任务信息（任务类型、任务输入文件位置等）发送给`worker`，而`worker`在注册成功后，就不断监听`master`的连接并调用`worker`的任务执行`handler`(`doTask`)， `doTask`会调用应用程序的`Map`或`Reduce`执行`MapReduce`任务，所有的`worker`在本节点执行任务的过程同`Sequential`运行模式下类似，只是各个`worker`并行执行，互不干扰。值得注意的是，在整个`MapReduce Job`调度执行过程中，`worker`允许动态加入，`master`一旦发现`worker`注册加入，若此时有未完成的任务等待调度，就会将此任务让新加入的`worker`调度执行。只有所有的`Map task`调度完成后，`Reduce task`才会被调度。当所有`Reduce task`执行完成后，同样会进行`merge`的过程，然后从`MapReduce`框架返回。

## Map 及 Reduce 工作流程

这里简要阐述 `Map & Reduce`阶段执行流程。当`worker`执行`map task`时，包括以下几个步骤：首先从本地磁盘读取其负责处理的原始输入文件；然后，通过将文件名及文件内容作为参数传递给`MapFun`来执行用户自定义逻辑；最后，对于每一个`Reduce task`，通过迭代`MapFunc`返回的执行结果，并按记录(`record`)的`key`进行`partition`以将分配给对应的`Reducer`的中间输出结果写到本地磁盘对应文件。

`Reduce task`的执行过程大致如下：首先读取本`Reduce task`负责的输入文件，并使用`JSON`来`decode`文件内容，并将`decode`后的`kev/value`存储到`map`中，同一个`key`对应一个`value list`，然后将整个`map`的`key`进行排序，并对每一个`key/value list`通过调用`ReduceFunc`来执行用户名自定义逻辑，同时，将其返回的结果，经`JSON encode`后写入输出文件。这些由`Reduce task`输出的文件内容，会被`merge`到最终的输出文件。

## 再谈失败恢复

容错（失败恢复）是`MapReduce`运行时的一个关键特性。且 Lab1 也模拟实现了任务执行失败后所采取的措施。任务执行失败，典型的包括两种情况：网络分区（网络故障）及节点宕机，且事实上无法很好地区分这两种情形（在两种情形下，`master`都会发现不能成功`ping`通 `worker`）。而实验则是采用阻止`worker`与`master`的`rpc`连接来模拟实现。具体地，所有`worker`在执行若干个`rpc`连接请求后（一个`rpc`连接请相当于一次任务分配），关闭其`rpc`连接，如此`master`不能连接`worker`而导致任务分配执行失败。个人认为，一般情况下会让	`master`缓存`worker`的连接`handler`，并不会在每次发送`rpc`请求时，都需要执行`Dial/DialHttp`，若是如此，便不能以原实验的方式来模拟任务执行失败（虽然这可能并不影响）。另外 Lab1 显式禁止了`worker`同时被分配两个任务的情况，这是显而易见的。

关于失败恢复（节点容错），下面讨论更多细节。容错是`MapReduce`的一个重要特性，因为节点失效在大数据处理工作中过于频繁，而且当发生节点宕机或者网络不可达时，整个`MapReduce job`会执行失败，此时`MapReduce`并不是重启整个`job`，那样会导致重新提交执行一个庞大的`job`而耗时（资源）过多，因此它只会重启对应`worker`所负责执行的`task`。值得注意的是，正是因为`worker`并不维护`task`相关信息，它们只是从磁盘读取输入文件或者将输出写到磁盘，也不存在与其它`worker`进行通信协调，因此`task`的执行是幂等的，两次执行会产生相同的执行结果，这也可以说是`MapReduce`并行执行任务的约束条件之一，也是`MapReduce`同其它的并行执行框架的不同之处，但无论如何，这样设计使得`MapReduce`执行任务更为简单。因为`Map task`会为`Reduce task`产生输入文件，因此若`Reduce task`已经从`Map task`获得了其所需要的所有输入，此时`Map`的失败，并不会导致其被重新执行。另外关键的是，`GFS`的`atomic rename`机制确保即使`Map/Reduce task`在已经溢写了部分内容到磁盘后失败了，此时重新执行也是安全的，因为`GFS`会保证直到所有输出写磁盘完成，才使得其输出文件可见，这种情况也会发生在两个`Reduce task`执行同一个任务，`GFS atomic rename`机制同样会保证其安全性。那么，若两个`Map`执行同一个`task`结果会如何？这种情况发生在，`master`错误地认为`Map task`宕机（可能只是发生了网络拥塞或者磁IO过慢，事实上，`MapReduce`的`stragger worker`正描述的是磁盘IO过慢的情况），此时即便两个`Map task`都执行成功（它们不会输出到相同的中间文件，因此不会有写冲突），`MapReduce`运行时也保证只告诉`Reduce task`从其中之一获取其输入。最后，注意`MapReduce`的失败恢复机制所针对的错误是`fail-stop`故障类型，即要么正常运行，要么宕机，不会产生不正确的输出。

[参考代码在这里](https://github.com/qqzeng/6.824/tree/master/src/mapreduce)。



参考文献

[1] Dean J, Ghemawat S. MapReduce: simplified data processing on large clusters[J]. Communications of the ACM, 2008, 51(1): 107-113.
[2].[MIT 6.824](https://pdos.csail.mit.edu/6.824/index.html)

