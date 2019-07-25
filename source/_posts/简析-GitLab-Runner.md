---
title: 简析 GitLab Runner
date: 2019-07-25 22:34:02
categories:
- devops
- 持续集成
tags:
- gitlab-ci
---

原计划本文是作为此系列文章的最后一篇，即整合`Kubernetes`和`GitLab CI`并构建持续集成流程。但由于后面对`GitLab Runner`作了进一步的了解，因此，在此作下记录，同时方便有需要的同学。上两篇文章的主题分别是在`Kubernetes`中安装`GitLab Runner`以及`Docker-in-Docker & Socket-Binding`这两种可以实现在容器中执行容器命令的方法。本文侧重于对`GitLab Runner`相关内容作一个补充。本文内容主要来源于两个地方：一部分是来提炼于官方文档，另一部分是通过查阅源码，归纳总结出来的核心操作的逻辑。因此，如果大家对`GitLab Runner`有兴趣或者学习/工作有需要，可以仔细查阅[官方文档](https://docs.gitlab.com/runner/)，和追踪它的[源码](https://gitlab.com/gitlab-org/gitlab-ce/tree/master)。这篇文章主要阐述三个方面的内容，一是关于`GitLab Runner`的知识，其二是强调和细化一下`Executors`这个概念，最后，通过阅读源码，概要阐述`GitLab Runner`和`GitLab Server`二者的基本交互逻辑。

<!--More-->

不是不说，有些概念官方也没有说地特别清楚（个人观点，至少对于新手而言不太友好），需要自己去实践才能彻底明白其中的原理或用法。`GitLab Runner`的源代码是用`Golang`写的，总体而言，各模块代码组织结构比较清晰，而且也不会难以读懂，强烈建议有兴趣的读者可以翻看下。下面对这三方面一一展开介绍。

## 关于 GitLab Runner

有一个最基本的概念需要清楚——`GitLab Runner`到底是做什么的？事实上，`GitLab Runner(Runner)`并不负责最终执行我们在`.gitlab-ci.yml`中定义的各个`stage`中的脚本（真奇怪，明明都被称为是`Runner`了）。意识到这一点很重要。因此，对于`Job`的构建效率与`Runner`本身的配置没有直接关联（但是`Runner`确实会影响到`CI`流程的构建效率，这在后面阐述）。

另外，需要提醒的是，`GitLab Runner`允许以`rpm`包、`debian`包（`yum`源、`apt-get`）安装在 `Linux`,、`macOS`或`FreeBSD`上，甚至可以通过二进制文件安装在` Windows`上，当然也可以通过拉取镜像安装在`Docker`或 `Kubernetes `中。`Runner`本身没有任何特殊之处，它也只是一个使用`Golang`编写的程序而已，因此，理论上它可以安装在任何具有`Golang`环境的机器上。

另外一个问题是，很多时候如果你的`GitLab CI`工作流程跑得比较慢（这很常见），或者说构建效率较低。此时，一般而言，可以从三个方面来调整解决：

- 调整你的`.gitlab-ci.yml`文件内容（确保自己熟悉[`.gitlab-ci.yml`](https://docs.gitlab.com/ce/ci/yaml/)各选项），实施一些优化操作。典型地，让各`stage`之间共享缓存。
- 优化你的`GitLab Runner`的配置和`Job`调度策略。这包括两个方面，其一是`Runner`的配置，比如，`concurrent`参数决定了你的项目中同时可以构建的`Job`的数量，另外还有其它的几个相关的选项。其二是`Runner`调度`Job`的策略，不同的调度策略会影响到你提交的`Job`的构建情况。典型地，若某个`Project`包含很多个`Job`，那么它很有可能会占居大量的`Runner`资源，而`Shared Runner`采用的`Fair Usage Queue`调度策略就可以缓解此问题。`Runner`的调度策略与[`Runner`的类型](https://docs.gitlab.com/ee/ci/runners/#shared-specific-and-group-runners)相关，其中`Specific/Group Runner`使用的是`FIFO`，注意，此`FIFO`针对的是`Job`，而不是`Project`。而`Shared Runner`使用的是`Fair Usage Queue`这种调度策略，官方文档给了[两个例子](https://docs.gitlab.com/ee/ci/runners/#how-shared-runners-pick-jobs)来解释。在后面，我有一张`PPT`有阐述`Fair Usage Queue`策略具体是怎样，另外有两张`GIF`分别对应官方文档的两个示例。
- 最后，当然，你也可以升级`Runner`的物理硬件资源配置，这种方法就不多阐述了。

关于`GitLab Runner`的最佳实践，这是`GitLab`官方论坛的[讨论贴](https://forum.gitlab.com/t/best-practices-for-ci-with-gitlab/5169)。这是网上的一个关于[`GitLab Best Practices`的建议](https://www.digitalocean.com/community/tutorials/an-introduction-to-ci-cd-best-practices)。若有需要，大家可以参考下。

【此处有一张PPT】

【此处有两张GIF】

最后，通过阅读官方文档，本文整理一些关于`Runner`一些`tips`：

- 关于`Runner`
  1. 你可以为多个`Project`注册同一个`Specific Runner`，与使用`Shared Runner`注册给多个`Project`的区别是：你需要显式地在每个`Project`下 enable 这个`Specific Runner`；
  2. 注意`Specific Runner`不会为会`forked project`自动开启，因此，你需要显式注册绑定；
  3. GitLab admin 只能注册`Shared Runner`，当然你也可以在`Shared Runner`被注册后，主动为某个`Project`取消注册此 `Shared Runner`；
  4. `Specific Runner`可以被 lock 到某个`Project`。这样其它项目不能使用此`Runner`；
  5. 注册`Specific Runner`有两种方法：
     a.  一是直接通过`gitlabUrl`和 `registerToken`。注意此 `registerToken` 是同`Project`绑定的！
     b.  另一种是将`Shared Runner`转换成`Specific Runner`。此操作是一次性的，且只有 admin 才能操作。
  6. 你可以通过使用`protected branches`或`protected tags`来关联拥有这些信息的`protected project`和 `protected Runner`。因为考虑到实际生产环境有些 Runner 可能包含私密信息；
  7. 实践建议：尝试给`Runner`使用`tag`，同时给`Project`打上 `tag`； 为`Runner`设置执行`Job`的超时时间。

- 注册`Runner`是否与`Project`有关，例如`registerUrl` 和 `token` 跟项目是相关的？
  注册`Specific Runner`与`Project`相关。必须使用`gitlabUrl`以及此项目下的`registerToken`才能将此 `Runner`注册到此`project`下。若没有提供正确的`registerToken`（但这个`registerToken`确实合法的，比如选择了其它 `Project`的`registerToken`），则也可以显式地在这些`Project`下手动 enable 此 `Runner`，前提是你是这些项目的`maintainer`。

  **TODO**: 你可以实践一个错误的`registerToken`，即它不与任何`Project`关联（`Kubernetes Executor`）。
  **实践结果**：`Runner`所在的`Pod`启动失败，容器就绪探针有问题。因此，验证了前述逻辑。

- 关于`Runner Token`的问题？
  有两种类型的`Token`。一个是`Registration Token`，用于`Runner`注册时使用。另一个是`Authentication Token`，用于`Runner`向`GitLab`提供认证。这个`Token`可以在使用`Registration Token`注册到`GitLab`时自动获取到（由 `GitLab Server`返回）；然后，`Runner`会将它放在`Runner`的配置文件中。 或者是手动在`Runner `配置文件 的`[[runners]] section`下设置`token="<authentication_token>"`。之后，`GitLab Server` 和 `Runner`就能正常建立连接。

## 关于 Executor

既然`Runner`不是`Job`的执行体，那究竟是谁负责执行`Job`呢？事实上，这与`Executor`密切相关。总而言之，`Runner`是借助`Executor`来创建具体的执行我们`Job`的资源实体，官方文档把它称为`Runner`，有点尴尬，但是读者必须清楚二者的区别。那[`Executor`](https://docs.gitlab.com/runner/executors/)又是什么呢？我个人的理解是，所谓的`Executor`是一个抽象的概念，它为`GitLab CI`构建过程提供资源环境。引入`Executor`这个概念，可以使得`Runner`使用不同的 `Executor`（`SSH`、`Shell`和`Kubernetes`等）来执行`Job`构建过程。典型地，在具体某个环境中，比如在`Kubernets`中，就由 [`Kuberentes Executor`](https://docs.gitlab.com/runner/executors/kubernetes.html)来请求`Kubernetes API Server`动态创建`Pod`，动态创建出来的`Pod`才负责`Job`的执行（关于`Pod`的含义读者可以参考`Kubernetes`文档）。

最后，`Runner`所安装的地方并不会与最终`Job`的执行体绑定，我们姑且称这个执行体为`Executor`吧，可能不是很准确。比如，如果我们使用`Kubernetes Executor`，则我们可以将`Runner`安装在`Windows`上，但却将它远程连接到`Kubernetes`集群，并通过`Kubernetes Executor`来为`Job`的构建动态创建`Pod`，但这种方式不是最简便或最合理的，个人是将`Runner`同样安装在`Kubernetes`中，这是官方的推荐做法，一方面，因为最终的应用是部署在`Kubernetes`中，因此，这会带来便利；另外，也会省去`Runner`连接集群的一些认证等过程。当然，如果选择将`Runner`安装在`Windows`中，这是最简单朴素的方式，此时`Runnre`会直接在本地为每一个`Job`动态启动一个进程，是的，这就是`Shell Executor`。更准确而言，应该是`PowerShell Executor`。下面是个人翻译整理官方文档的一些关于各种`Executor`的基本情况：

- [`SSH`](https://docs.gitlab.com/runner/executors/ssh.html)
  - 通过`ssh`连接到远程主机，然后在远程主机上启动一个进程来执行`GitLab CI`构建过程。连接时需指定`url、port、user、password/identity_file`等参数；
  - 若想要上传`artificate`，需要将`Runner`安装在`ssh` 连接到的远程主机上。
- [`Shell`](https://docs.gitlab.com/runner/executors/shell.html)
  - 使用安装`Runner`的同一台主机启动一个进程来执行`GitLab CI`构建过程。凡是支持安装`Runner`的机器类型，都可以用使用`shell`的方式。这意味着`Windows PowerShell`、`Bash`、`Sh`和`CMD`都是可以的。
- [`VirtualBox/Parallel`](https://docs.gitlab.com/runner/executors/virtualbox.html)
  - 通过`ssh`远程连接到虚拟机，在虚拟机中执行`GitLab CI`构建过程，可能会创建虚拟机快照以加速下一次构建。类似地，需指定`user、password/identity_file`；
  - 同`SSH`方式类似，若想要上传`artificate`，需要将`Runner`安装在`VirtualBox`的虚拟机中；
  - 正式开启`CI`流程前，需提前在`VirtualBox`中创建或导入一个`Base Virtual Machine`，并在其中安装 `OpenSSH Server`以及依赖等。
- [`Docker`](https://docs.gitlab.com/runner/executors/docker.html)
  - 将`Executor`连接到`Docker Daemon`，并在一个单独容器中跑每一次的构建过程，并使用在`.gitlab-ci.yml`文件中定义的镜像，`Docker Executor`具体是通过`config.toml`文件来配置的。
- [`Kuberentes`](https://docs.gitlab.com/runner/executors/kubernetes.html)
  - 让`Runner`连接到连`Kubernetes API Server`，为每一个`Job`动态创建一个`Pod`来执行`GitLab CI`构建过程。
  - 且此`Pod`除了包含固有的`Infra Container`外，还一定会包含`Build Container`和`Help Container`，另外，可能包含`Service Container`。简单而言，`Build Container`用于执行`.gitlab-ci.yml`文件中在`stage`标签中定义的脚本。`Help Container`则用于辅助`Build Container`的执行构建工作，具体是负责`git`和`certificate store`相关的操作。最后`Service Container`的用途则对应着`.gitlab-ci.yml`文件中定义的`service`标签，即一个辅助容器，为`Build Container`提供服务，其基本实现原理是`Docker Link`。
  - 最后，每一个`Job`都会包含四个阶段（`Job`构建过程的生命周期）：`Prepare`、`Pre-Build`、`Build`和`Post-Build`。这几个阶段的具体作用，我在这里就不阐述了，比较简单，可以阅读[这里](https://docs.gitlab.com/runner/executors/kubernetes.html#workflow)，也可以在源码中找到。

关于`Executor`就阐述到这里，`Executor`的概念非常重要，也比较抽象。

## 关于 GitLab Server 同 GitLab Runner 的交互

这一小节简要阐述下`GitLab Server`同`GitLab Runner`的交互过程，基本是通过阅读源码总结而来，但并未详细阅读源码，只是大概理清整个交互逻辑。因此，如果读者没有跟随源码，下面的描述中涉及到源码的部分可能会有点不模糊，不过没有关系，若读者只想了解二者交互的大概过程，只需要把下面的二者的交互图搞清楚即可。但若读者有兴趣，个人还是建议，可以翻看下源码，会更清楚一些。

下面从四个重要操作展开叙述，分别是：
- **`Register Runner`**，`Runner`注册过程，即将`Runner`绑定到`GitLab Server`实例的过程；
- **`Polling Job`**，`Runner`轮询`Job`的过程，当`Runner`从`GitLab Server`获取到`Authetication Token`后，它会定期去向`GitLab Server`轮询是否有等待构建的`Job`；
- **`Handle Job`**，`Runner`一旦轮询到`Job`后，它会启动构建过程，即开始上述四个阶段：`Prepare、Pre-Build、Build和Post-Build`。（对于`Kubernetes Executor`而言）。
- **`Patch Job`**，在构建`Job`的过程中，会定期将`Job Trace`日志信息发送给`GitLab Server`；

### Register Runner

**`Register Runner`**。当执行客户端执行`register`命令(`gitlab-runner register ...`)并提供一些配置信息时，如`gitlabUrl、executors、token`和`tag`等，会触发对应的`Runner`注册过程。源码中对应的方法是 `commands/register.go#Execute`，然后会继续调用`register.askRunner`方法来配置`Runner`，在构造所需参数后，将调用`network/gitlab.RegisterRunner`方法来注册`Runner`。在此方法中，最终通过`http POST /runners`来完成向`GitLab Server`发送注册请求，同时处理注册请求的返回结果。其中，注册请求的重要参数包括 `registrationToken`，`locked`，`maximum_timeout`，`tag_list`等（这需要在配置时填写的）。而注册请求的响应内容包含一个`token`，正如前文所述，在此之后，当`Runner`向`GitLab Server`请求`Job`信息时，需携带此 `token`。最后，需要提醒的是，[此接口]( https://gitlab.example.com/api/v4/runners)是公开的，换言之，你可以使用程序调用此接口。

### Polling Job

**`Polling Job`**。当`Runner`注册成功后，其会定期（默认是`3`秒，可配置）向`GitLab`请求`Job`信息。这在源码中对应的是`commands/multi.go#processRunner`方法，然后调`multi.requestJob`法，进一步调用 `network.RequestJob`（即`GitLabClient.RequestJob`）请求`Job`。最终通过`http POST /jobs/request`接口 来完成轮询`Job`请求。此请求的重要参数包括`token`和`RunnerInfo`等 。而响应内容包括`jobInfo、gitInfo`等。当然，若没有没有等待构建的`Job`信息，则返回`204 StatusNoContent`。最后，此接口似乎没有公开。

关于`Polling Job`的具体源码体现。在`commands/multi.go#Run`方法中，异步开启一个`goroutine`，执行 `multi.feedRunners(runners)`方法，此方法会判断是否在可用的`runners`，若存在，则遍历所有可用的 `runner`，并周期性地（默认，每隔`CheckInterval=3s`）往`runners` 通道中压入`runner`。需要注意的是，若有多个`runners`，则实际的周期是`CheckInterval / len(runners)`。接着会调用方法链： `multi.startWorkers -> multi.processRunners`，在此方法中通过`select case`结构从`runners`取前面压入的`runner`实例，一旦取出成功，则调用`multi.processRunner`方法，随后的步骤如前所述。

需要注意的是，在正式调用`multi.requestJob`方法前，会先通过`common.GetExecutor`获取`executor`，同时还要为`runner`申请足够资源 `(multi.acquireRunnerResources)`。

另外，最终构建`Job`是通过方法链完成的：`common/build.go#build.Run(mr.config, trace) -> build.run(context, executor) -> build.executeScript(runContext, executor)`。关于构建的四个阶段，对应的源码内容也比较清楚，在`build.executeScript`方法中存在如下代码调用：

```go
prepare -> build.executeStage(ctx, BuildStagePrepare, executor)
```

```go
pre-build -> build.attemptExecuteStage(ctx, 
BuildStageGetSources|BuildStageRestoreCache|BuildStageDownloadArtifacts, executor, 
b.GetGetSourcesAttempts()
```

```go
build -> build.executeStage(ctx, BuildStageUserScript, 
executor) 和 build.executeStage(timeoutContext, 
BuildStageAfterScript, executor)
```

```go
post-build -> build.executeStage(ctx, BuildStageArchiveCache, 
executor) 和 b.executeUploadArtifacts(ctx, err, executor
```

### Handle Job

**`Handle Job`**。当成功获取`Job`息后，`Runner`就开始处理`Job`的构建过程。这在源码中对应的是 `commands/multi.go#requestJob`方法，然后调用`network.ProcessJob`方法。在这之前会构造 `jobCredentials{ID, Token}`，接着通过`trace.newJobTrace`创建`Job Trace`即`Job`处理日志，在构造函数中指定了`Job Trace`更新的周期，默认是`UpdateInterval=3s`，然后调用`trace.start`方法开启 Job Trace 输出。

### Patch Job

**`Patch Job`**。在`Job`被正式构建时，是通过调用`trace.start`方法来调用`trace.watch`以周期性地`patch Job trace`。在源码中是通过`trace.incrementalUpdate -> trace.sendPatch -> network.PatchTrace`方法链来完成调用的，最终通过`http PATCH /jobs/{JobId}/trace`来完成`patch Job trace`请求。其中重要参数即为`job trace content`，且为增量输出，在请求的`headers`中需要设置`Job token`。若请求发送成功，则返回 `StatusAccepted 202`响应码。同时，每隔`forceSendInterval`（默认`30s`） 的时间还要更新`Job`执行状态信息（`pending、running、failed`和`success`），在源码中是通过方法链`trace.touchJob -> network.UpdateJob`来完成，最后通过`http  PUT /jobs/{JobId}`完成请求的发送，其中重要参数包括`runnerInfo、JobToken、JobState` 等。但需要注意的是，若`Job`执行失败，则会附带上失败原因`FailureReason`，若`Job Status`更新成功，则返回`UpdateSucceeded 200`响应码。

下面是一张完整的`GitLab Server`同`GitLab Runner`的交互图。其中，最左边的表示客户端执行的`Runner`的命令（注册，启动和取消注册）。中间用红色标示的表示各个详细的阶段。右边中绿色标注的表示`Runner`同`GitLab Server`的`Http`通信细节，这个是最重要的。右边的黑色和蓝色标示的表示`Runner`自身内部执行的一些操作。

【此处有图】

简单小结，本文主要阐述了三个方面的内容：一是阐述`Runner`相关的知识，特别要清楚`Runner`的本质是什么，以及提高`GitLab CI`构建效率的三个方面的知识，最后补充了`Runner`相关的细节知识点；二是阐述`Executor`相关的知识，包括`Executor`的本质，与`Runner`的关系，并且简要阐述了各种`Executor`，需要重点关注`Kubernetes Executor`。最后，阐述`GitLab Server`同`GitLab Runner`基本交互逻辑，主要是包括四个阶段（没包括最后的取消注册），这几个阶段都挺重要，读者可以借助二者的交互图来理解，重点关注二者之间的`Http`交互的各阶段。这有助于理解`Runner`的执行原理。





参考文献

[1].https://docs.gitlab.com/runner/
[2].https://forum.gitlab.com/t/best-practices-for-ci-with-gitlab/5169
[3].https://docs.gitlab.com/runner/executors/
[4].https://docs.gitlab.com/runner/executors/kubernetes.html
[5].https://docs.gitlab.com/ee/api/
[6].https://gitlab.com/gitlab-org/gitlab-ce/tree/master