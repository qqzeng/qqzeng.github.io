---
title: 浅析 docker-in-docker 和 socket-binding
date: 2019-07-07 06:08:17
categories:
- devops
- docker
tags:
- docker

---

上一篇文章详细阐述在`k8s`中安装`gitlab runner`的整个流程，并且也阐明了其中涉及的原理。原计划这一篇博文紧接着叙述基于`k8s`并集成`gitlab-ci`的持续集成部署方案的第二阶段——研究集成`gitlab-ci`和`k8s`来实现一个以`build->test->deploy`为核心的持续集成部署流程。第一阶段只是搭建好了环境，显然第二阶段要更重要。但考虑到个人在第二阶段实验过程涉及到至关重要的一个问题，因此，打算单独开一篇博文总结一些看过的资料，并基于个人的理解与认识将此问题解释清楚。是的，这个问题是：若我们想在`docker`中运行`docker`应该如何实现呢？简单而言，在一个`docker`容器内能够安装`docker daemon`，以使得我们能够执行`docker build/push`等命令。这个问题在`ci/cd`中很典型，无论是采用`Jenkins`还是`gitlab-ci`同`docker`或`k8s`结合。比如，对于`gitlab-ci`而言，它的每一个`stage`都跑在一个容器中的，而若想在某个`stage`中执行`docker`命令（典型的，在服务构建阶段会涉及到`docker build`），默认是不支持的。我们将此种需求概略地称为在容器中运行容器。在本博文中主要讨论实现此需求的两种实现方式，但事实上，也可能不仅仅这两种方式。

<!--More-->

本文不会过多阐述[`docker`](https://docs.docker.com/)基本原理，但这两种实现方式确实会涉及到`docker`的一些知识。因此，你需要具备`docker`基本原理的基础。若要在一个容器中安装另外一个容器，从技术上而言，这是可以实现的。似乎在`Docker 0.6`版就添加了这个新特性，且从使用上而言，也较为简单，我们暂且称之`docker-in-docker(dind)`。但它涉及到一些安全问题，也可能会引起一些奇怪的问题。具体你可以参考[这里](http://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/)。因此，自然而然就诞生了其它更为合理的方式——`socket-binding`，它实际上并非严格意义上的`docker-in-docker`，但它可以实现类似在容器中执行容器相关命令的效果。并且它还具备其它的优势，典型的，可以让子容器，孙子容器等等共享镜像缓存，这在某些情况下是非常合适的。下面详细介绍这两种实现方式，都遵循从实践到理论的阐述思路。

## docker-in-docker

`docker-in-docker`这种模式从最初作为新特性被引入`docker`，到当前的版本，功能确实日趋完善。但在这里仍旧只涉及其核心部分的实践及原理。

### docker-in-docker 初步实践

在`0.6`版的`Docker`在执行`docker run`命令时，增加了一项新特性——`privileged`选项参数，可以说就是此参数真正实现了在容器中运行容器的功能。如图1，当你执行如下命令：

`docker run --privileged -it jpetazzo/dind`

![run-jpetazzo/dind-with-privileged](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/practice-privileged-1.png)

它会从[`docker hub`](https://hub.docker.com/r/jpetazzo/dind/)下载一个特殊的`docker image`，此镜像包含了`docker client`和`docker daemon`，并且指明以特权模式来执行它，然后它启动一个本地`docker daemon`，并进入容器交互式`shell`。在此特殊容器中，你可以继续执行`docker run`启动容器：

`docker run -it ubuntu bash`

![run-in-dind](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/practice-previliged.png)

仔细观察你的容器`ID`，你的`hostname`发生了变化，说明你已经从外层容器进入到了内层容器了！值得注意的是，此时，内层容器与外层容器依然是隔离的。我们可以简单验证一下。

![dind-islotation](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/practice-privileged-3.png)

### docker-in-docker-in-docker?

有读者可能会思考，既然我可以在容器中启动容器，即`docker-in-docker`，那么我是否可以做到`docker-in-docker-in-docker`呢？是的，这完全可以实现，甚至，理论上你可以无限递归下去，只要你在启动下一层容器时，开启特权选项即可。你可以实践下图的操作内容，观察容器`ID`，说明你确实做到了容器递归嵌套容器。而且你会发现每次执行`docker run`命令时，它都会去下载`jpetazzo/dind`这个镜像，这说明了各个层级的容器不会共享`image`，这也间接证明了各层级的容器确实处于隔离状态。

![docker-in-docker-docker](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/docker-in-docker-in-docker.png)

### 关于 privileged 特权模式

关于`privileged`特权模式。我们知道`linux`进程包括`priviledged process`，即`root`用户（或者说`pid=0`的用户）创建的进程，和`unpriviledged process`，即普通用户创建的进程。`--privileged`选项实际上就是创建`priviledged container`进程。考虑到默认情况下`docker`容器运行模式为`unprivileged`，这使得在一个`docker`容器中跑另外一个`docker daemon`不被允许，因为容器不能访问宿主机的任何`device`。但一个具备`privileged`特权的容器则允许访问所有`device`[`(cgroup device)`](https://www.kernel.org/doc/Documentation/cgroup-v1/devices.txt)，即可以访问`/dev`下所有的目录。换言之，当容器被配置成`privileged`模式时，容器对宿主机的所有`device`具有完全控制权，同时通过修改`AppArmor`及`SELinux`相关的配置，使得容器几乎相当于运行在宿主机上的进程一样，具有完全访问宿主机的权限。

虽然，在`Docker 0.6`版，纯粹只添加了`--privileged`选项。但当前的版本(`18.09.6`)其实限制容器对宿主机设备的访问权限的粒度已经控制得比较精确了。换言之，如果只想让容器访问部分设备，可以使用`--device`选项，这使得默认情况下，容器对这些设备具有`read`、`write`、和`mknod`权限，但可使用`:rwm`作出限制。

除了使用`privileged`选项，也可使用`--cap-add`和`--cap-drop`选项以更细粒度的控制容器对宿主机访问的某些方面的权限。更多可参考`docker`[官方文档](https://docs.docker.com/engine/reference/run/#runtime-privilege-and-linux-capabilities)。

### jpetazzo-dind 基本原理

现在，我们来讨论一下`jpetazzo/dind`这个镜像的特殊之处。主要参考的是[这篇文章](https://blog.docker.com/2013/09/docker-can-now-run-within-docker/)。事实上，这个镜像也没有什么太大不同，也是由`Dockerfile`构建，下面是它的`Dockerfile`内容：

```dockerfile
FROM ubuntu:14.04
MAINTAINER jerome.petazzoni@docker.com

# Let's start with some basic stuff.
RUN apt-get update -qq && apt-get install -qqy \
    apt-transport-https \
    ca-certificates \
    curl \
    lxc \
    iptables
    
# Install Docker from Docker Inc. repositories.
RUN curl -sSL https://get.docker.com/ | sh

# Install the magic wrapper.
ADD ./wrapdocker /usr/local/bin/wrapdocker
RUN chmod +x /usr/local/bin/wrapdocker

# Define additional metadata for our image.
VOLUME /var/lib/docker
CMD ["wrapdocker"]
```

`Dockerfile`所包含的内容并不复杂，主要做了如下四几件事情：

- 安装一些`docker daemon`依赖软件包，包括`lxc`和`iptables`。另外，当`docker daemon`同`docker index/registry`通信时，需要校验其`SSL`认证，因此需安装`ca-certificates`和`apt-transport-https`等。
- 挂载`/var/lib/docker volume`。因为容器文件系统是基于`AUFS`的挂载点(`mountpoint`)，而构成`AUFS`的分层文件系统应为正常的文件系统。 换言之，`/var/lib/docker`这个用于存储它创建的容器的目录不能是`AUFS`文件系统。因此，将此目录以`volume`的形式挂载到宿主机。这使得后面在容器中创建的内层容器的数据真正存储宿主机的`/var/lib/docker/volumns`目录下。
- 通过脚本快速安装一个最新的[`docker`](https://github.com/docker/docker-install)二进制镜像文件。
- 执行一个[`helper`](https://github.com/jpetazzo/dind/blob/master/wrapdocker)脚本。脚本主要操作包括如下三个方面：
  - 确保`cgroup`伪文件系统已经被正确挂载，若没有挂载，则依据宿主机中`cgroup`层级文件系统的形式对它进行挂载，因为`docker(lxc-start)`需要它。
  - 关闭宿主机上多余的文件描述符。否则可能会造成文件描述符资源泄露。虽然这不是严格必需，但目前我们关闭它可以避免一些奇怪的行为（副作用）。
  - 检测你是否在命令行中通过` -e PORT=...`指定了一个`PORT`环境变量。如果你确实指定了，`docker daemon`将会在前台启动，并在指定`TCP`端口监听`API`请求。反之，它会在后台启动`docker daemon`进程，并且为你提供一个交互式的`shell`。

### docker-as-a-service

最后，需要补充的一点是，若你想使用`docker-in-docker`来作为一个服务（上述已提到`helper`脚本中最后一个操作，即判定`docker deamon`是监听指定端口，还是提供一个临时`shell`），即计划提供一个`Docker-as-a-Service`，注意不是`Containers-as-a-Service`，这两者在概念上是有区别的。因为我们提供的服务是一个`docker`实例。我们可以通过如下命令，通过让容器运行于后台模式，并对外暴露一个端口来实现：

`docker run --privileged -d -p 1234 -e PORT=1234 jpetazzo/dind`

![docker-as-a-service](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/dokcer-as-as-service.png)

如上的命令可以获取到容器的`ip`和`port`，如此便可为第三方提供`docker`实例的服务。简单而言，它们可直接连接到`docker`实例(`docker daemon`)执行与容器相关的操作。我们简单运行一个只安装了`docker clinet`的容器，然后设置其`DOCKER_HOST`为此提供`docker daemon`的容器的地址，然后简单实验一下是否成功连接，并使用作为服务的`docker daemon`。当然，你也可以参考[这里](https://hub.docker.com/_/docker)，使用`docker link`来做实验完成类似的效果。同样，考虑到此`docker`实例服务是以`priviliged`模式运行的，因此，它可能会因为获取了特权而造成不可预料的风险。

![dind-host](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/docker-as-a-servce-1.png)

![dind-docker](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/docker-as-a-service-2.png)

## socket-binding

`docker-in-docker`的方式可以实现在容器中启动另一个容器，但它确实存在安全风险，而且，也存在潜在的棘手问题，具体可以参考这篇[博文](http://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/)。值得一提的是，使用`dind`的方式，无法让各内层容器之间或容器与主机之间共享缓存，这在基于`k8s`集成`gitlab`实现持续集成部署方案的用例中是一个比较严重的问题。因此，笔者考虑使用`socket-binding`的方式（`socket-binding`称呼源自`gitlab`[官方文档](https://docs.gitlab.com/runner/executors/kubernetes.html#exposing-varrundockersock)，也可称之为[`bind-mount`](https://docs.docker.com/storage/bind-mounts/)）。

### socket-binding 实践

事实上，很多情况下，我们并不真正需要在一个容器中运行另外一个容器（或许存在特例）。我们需要的可能只是想在`docker`容器中能够继续执行`docker`相关操作（如`docker build/pull/push`等），至少在笔者的使用案例中是这样的。因此，使用`dind`的方式是否显得小题大做了？事实上若要达到我们的目的（在容器中执行`docker`相关命令操作）是很简单的——在启动容器时使用`-v`选项以绑定挂载的方式(`binding mount`)将宿主机的`docker socket`挂载到容器，即执行如下命令：

`docker run -it -v /var/run/docker.sock:/var/run/docker.sock some-docker-image /bin/bash`

且此`docker run`命令中的使用的`some-docker-image`镜像则不必为`jpetazzo/dind`，它没有任何特殊之处。当然，此镜像必须包含`docker client`，而可以不用包含`docker engine`。因为，当我们以`socket-binding`的形式来`run`一个容器时，它实际上是将宿主机的`/var/run/docker.sock`挂载到了容器中`/var/run/docker.sock`，这使得在容器中执行`docker build/push/pull`命令真正使用的是宿主机的`docker daemon`，换言之，我们使用容器中的`docker client`和容器外的宿主机的`docker daemon`进行通信。这不同于`dind`，它并非真正实现了在容器中运行容器的功能。当使用`socket-binding`的方式时，所创建的容器和执行`docker`命令的当前容器处于同一层级（不是父子关系，而是兄弟关系），都是直接隶属于宿主机下的一层。因此，你可以推理得到，正因为所有的"内层"容器实际上都使用的是宿主机的`docker daemon`，这使得宿主机和所有有的容器可以共享镜像缓存！最后，同`docker-in-docker-in-docker...`类似，`socket-binding`的方式理论上也可以无限递归。我们简单通过如下的操作过程简单实践：

先使用下面的`Dockerfile`构建我们的实验镜像，注意，我们在容器中只安装了`docker client`。

![sc-dockerfile](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/socket-binding-1.png)

然后，构建一个名为`dind-sc`的镜像。

![sc-image-build](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/socket-binding-2.png)

使用`run`命令启动容器，并进入到容器中，执行`docker version`命令，可以同时输出了`docker client`和`docker engine`的信息！另外，执行`docker image`命令，发现输出一堆`image`，是的，这是宿主机上的镜像。

![sc-docker-run](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/socket-binding-3.png)

我们再一次在当前容器中基于此`Dockerfile`构建（有没有发现这次构建非常快，是的，使用了上一次的镜像缓存），然后运行此容器……，重复上述的操作。可以发现，所启动的容器的地位其实是一样的，它们都在同一个层级。

![sc-dind-build](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/socket-binding-4.png)

![sc-docker-2](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/socket-binding-5.png)

最后，实验验证宿主机同各容器共享镜像`cache`。可以看到，我们在宿主机中构建的镜像可以在容器中看到，而在容器中拉到的`nginx`镜像，也能在宿主机中看到。

![sc-docker-cache](https://github.com/qqzeng/qqzeng.github.io/raw/hexo/static/dind%26socket-binding/socket-binding-6.png)

### 关于 docker volume

基于`socket-binding`来实现在容器中执行容器相关操作的命令的原理其实就是`docker volume`。`docker`为了能够保存（持久化）数据以及共享容器间的数据，引入了`volume`机制。简单而言，`volume`就是目录或者文件，它可以绕过默认的由多个只读层及一个读写层叠加而成的联合文件系统(`union file system`)，而以正常的文件或者目录的形式存在于宿主机上。`volume`机制隔离了容器自身与数据，这是为了保证数据对于容器的生命周期来说是持久化的，换言之，即使你删除了停止的容器数据也还在（除非显式加上`-v`选项）。

`volume`可以通过两种方式来创建：其一是在`Dockerfile`中指定`VOLUME /some/dir`；其二是执行`docker run -v /some/dir`命令来指定。这两种方式都是让`Docker`在主机上创建一个目录，注意默认情况下是在`/var/lib/docker`下的。并将其挂载到我们指定的路径(`/some/dir`)，当此路径在容器中不存在时，默认会自动创建它。值得注意的是，我们也可以显式指定将宿主机的某个目录或文件挂载到容器的指定位置（在上述实践环节正是这样操作的，这种方式也被称为是`bind-mount`）。最后强调一点，当删除使用`volume`的容器时，`volume`本身不受影响。

更多关于`volume`的操作请查看[官方文档](https://docs.docker.com/storage/volumes/)。

简单小结，本文阐述了两种实现在容器中运行容器的方法——`docker-in-docker`和`socket-binding`。对于`docker-in-docker`这种方式，虽然它存在不少问题，但它确实实现了在容器中运行容器。围绕`docker-in-docker`，先简单演示了其基本用法，然后进一步推广出`docker-in-docker-in-docker...`模式，这在理论上都是可行的。紧接从`privileged`选项切入阐述`dind`的相关原理，重点解释了`jpetazzo/dind`此特殊镜像的构建过程，最后描述了生产环境中`dind`的实践方式，即以`docker-as-a-service`的模式以将`docker`实例通过端口暴露给外部使用。另一种巧妙实现在容器中执行容器命令的方法是`socket-binding`。可以说，`dind`能够实现的，它基本都能实现，而且，它解决了各内层容器同宿主机共享镜像缓存的问题。且`socket-binding`的用法也较为简单，其原理简单而言，就是采用`bind-mount`通过`-v`选项将宿主机的`docker daemon`挂载到容器中，使得只需在容器中安装`docker client`（事实上，也可不安装`docker client`，而直接将宿主机的`/usr/bin/docker`挂载到容器中，同时安装`docker`执行所需的依赖文件即可）即可执行`docker pull/push/build`命令。





参考文献

`docker-in-docker`
[1].https://hub.docker.com/_/docker
[2].https://github.com/jpetazzo/dind/
[3].https://blog.docker.com/2013/09/docker-can-now-run-within-docker/
[4].https://docs.docker.com/engine/reference/run/#runtime-privilege-and-linux-capabilities

`socket-binding`
[1].https://docs.docker.com/storage/volumes/
[2].http://dockone.io/article/128