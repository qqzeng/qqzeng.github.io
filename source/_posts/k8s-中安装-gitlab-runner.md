---
title: k8s 中安装 gitlab runner
date: 2019-07-06 06:08:17
categories:
- devops
- 持续集成
tags:
- gitlab-ci
- k8s

---

最近工作的内容属于`devops`领域方向，研究的课题是基于`k8s`并集成`gitlab-ci`的持续集成部署方案。个人以前只使用过`Jenkins`来做持续集成部署(`ci/cd`)，而且，当时应该是部署在云主机上的。`gitlab`本身一个企业级代码托管平台，在`8.0`版本加入了`ci`，并且默认为每个项目开启。持续集成基本解放了软件项目的开发测试到最终的部署上线的繁琐流程，简单而言，它保证了每一次往版本库提交的代码都符合预期。我们知道`docker`解决了应用打包和发布这一运维技术难题，简单而言，`docker`所提供的极为方便的打包机制直接打包了应用运行所需要的整个操作系统，从而保证了本地环境和云端环境的高度一致。但毕竟在整个云计算领域中，`docker`只是整个容器生态的一个承载点，换言之，与开发者更为密切相关的事情是定义容器组织和管理规范的容器编排技术，这属于一个更高的层次，是一个平台级的技术。`kuberentes`正是这样一个开源平台，简而言之，`kubernetes`项目解决的问题是容器的编排、调度以及集群管理，当然，它也提供了一些高级的运维功能，如路由网关、水平扩展、监控、备份以及灾难恢复等。这也使得`kubernetes`从一诞生就备受关注。因此，将`gitlab-ci`与`k8s`进行整合是`ci/cd`实践中值得期待的方案。本系列博客会阐述个人基于`k8s`并集成`gitlab-ci`的持续集成部署方案的实现过程。实践环节包括两个部分，其一是在`k8s`中安装`gitlab runner`，其二是研究集成`gitlab-ci`和`k8s`来实现一个以`build->test->deploy`为核心的持续集成部署流程。本文的内容为第一个部分。

<!--More-->

本文不会过多阐述[`docker`](https://docs.docker.com/)相关原理，也不会过多涉及到[`kubernetes`](https://kubernetes.io/docs/home/)相关原理。只会在阐述整个基于[`gitlab-ci`](https://docs.gitlab.com/ee/ci/introduction/)和`kubernetes`的持续集成部署方案的过程中，涉及到的概念原理。本文从如下几个方面来完整的阐述在`k8s`中安装[`gitlab runner`](https://docs.gitlab.com/ee/ci/runners/README.html#shared-specific-and-group-runners)的流程：其一，简述`gitlab-ci`的核心概念及基本原理；其二，简述`gitlab runner`相关知识 ；其三，详细阐述`gitlab runner`在`k8s`中的安装流程；最后，对`gitlab runner`相关的配置文件中重要的配置进行介绍，以更深入地理解`gitlab runner`集成到`k8s`的原理。依据官方文档是使用[`helm`](https://helm.sh/docs/)作为软件安装工具，以在`k8s`中安装`gitlab runner`，但本文不会过多涉及`helm`的相关知识和原理。事实上，若读者不具备相关的知识基础，也没有太大影响。若读者已经对`gitlab, gitlab runner`已经较为熟悉，可以直接跳到第3小节。

## gitlab-ci 核心概念和基本原理

所谓持续集成持续部署(`ci/cd`, `Continuous Integration, Continuous Delivery, and Continuous Deployment`)，通俗而言，即在软件开发过程中，每当涉及版本库代码变更或更迭时，通过自动化执行一些由开发人员定义的脚本，以最小化引入错误的风险。自动化执行脚本说明（几乎）不需要人为干预。具体而言，持续集成表示当开发人员提交代码到版本库时（不一定是`master`分支），都会触发一系列的关于测试、构建等步骤的脚本自动化执行，以验证版本库中当前的代码所产生的效果是符合预期的。另外，持续交付(`Continuous Delivery`)和持续部署(`Continuous Deployment`)的区别在于是否需要人为干预，以部署项目到生产环境，而后者不需要人为干预。

`gitlab-ci/cd`集成了上述功能。其基本原理是版本库每一次`push`或者`merge reqeust`操作都会触发一次`gitlab-ci`流程，即执行开发人员预先在`.gitlab-ci.yml`定义的一系列`stage`，典型的，包括`build`、`test`和`deploy`这几个核心阶段。`gitlab-ci`确实较为强大，提供了丰富的功能，以实现项目开发的快速更迭。比如，它可以在各`stage`中共享缓存，以提高各`stage`的构建效率。和`gitlab-ci/cd`相关的几个核心概念如下：

- `pipeline`，表示一次构建任务，可包含多个阶段，如依赖安装、运行测试、项目编译、服务部署。
- `stage`，表示某个具体阶段，它们会依次串行执行，前一个成功执行后下一个才会执行，相反，若前一个执行失败，下一个则默认不会执行。
- `job`，表示`stage`上所执行的具体工作，一个`stage`可包含若干个并行执行的`job`，只有所有的`job`都执行成功，整个`stage`才被标记为执行成功，否则标记为执行失败。

图1来自`gitlab`官网，阐述了`gitlab-ci`的一个典型工作流程。使用`gitlab`作为代码托管工具，你不需要额外的第三方`ci/cd`软件，并且，它提供整个流程的可视化界面。

图2同样来自[`gitlab`官网](https://gitlab.com/gitlab-examples/spring-gitlab-cf-deploy-demo)，它是依赖`spring boot`的`java`应用服务的一个`.gitlab-ci.yml`示例。没有任何复杂的内容，整个`pipeline`中包含`test`和`build`两个`stage`。在全局`before_script`所定义的脚本会在所有`stage`执行之前被执行，`artifacts`表示此`stage`会生成一个`artifact`（比如一个`war`包或者可执行文件），最后`only`表示只会在对应的分支下执行。因此，当你将此`.gitlab-ci.yml`文件放到你的项目的根目录时，则表示此项目的`gitlab-ci`的功能已经开启，当你往版本库中`push`代码时，你会看到它会起作用了——自动执行你在`.gitlab-ci.yml`中定义的脚本（前提是你已经安装好了`gitlab`和`gitlab runner`，且将`runner`注册到了`gitlab`仓库中对应的项目，这会在后面提及）。你可以在[这里](https://gitlab.com/gitlab-examples)找到更多的`.gitlab-ci.yml`示例。

```shell
image: java:8

stages:
  - build
  - deploy
  
before_script:
  - chmod +x mvnw
  
build:
  stage: build
  script: ./mvnw package
  artifacts:
    paths:
      - target/demo-0.0.1-SNAPSHOT.jar

production:
  stage: deploy
  script:
  - curl --location "https://cli.run.pivotal.io/stable?release=linux64-binary&source=github" | tar zx
  - ./cf login -u $CF_USERNAME -p $CF_PASSWORD -a api.run.pivotal.io
  - ./cf push
  only:
  - master
```

## gitlab runner 相关知识

当你读完上节内容中一个示例后，你会想你在`.gitlab-ci.yml`中定义的脚本到底是在哪里执行的，换言之，是什么提供了你执行这些`stage`的资源。是的，这就是`gitlab runner`所做的。它会同`gitlab-ci`协同工作，`gitlab runner`用于运行`stage`中定义的`job`（`job`是`runner`执行的最小单位）。在阐述`runner`在`k8s`中的安装流程之前，让我们先来了解下`gitlab runner`的基本知识。

当你[安装`gitlab runner`](https://docs.gitlab.com/runner/#install-gitlab-runner)并[将它注册到某个项目](https://docs.gitlab.com/runner/register/)后（当然你可以使用`shared runner`，在这种情况下，此`runner`就不会隶属于某个项目，而是被一组或所有的项目所共享使用），你可以使用它来执行你在`.gitlab-ci.yml`中定义的`job`，只要`runner`能够访问`gitlab server`所在的网络，则`gitlab`和`runner`就能通过`api`进行网络通信，准确而言，是`runner`会定期轮询`gitlab server`是否有等待被执行的`pipeline`。从本质上而言，`runner`只是一个使用`go`语言编写的进程，当利用它来执行`.gitlab-ci.yml`中定义的`pipeline`时，它会`clone`对应的项目，然后执行你预定义在`job`中的脚本。

前面提到，当多个项目共享同一个`runner`时，则称此`runner`为`shared runner`，且理想状况下，`runner`不应该同`gitlab server`安装在同一台机器上，这会影响`gitlab`的正常工作。且`gitlab admin`只能注册`shared runner`。具体而言，`runner`主要包括如下三种：

- `shared runner`，它主要服务于多个项目中具有类似需求的`job`，显然，使用`shared runner`可以不需要为每一个项目配置单独的`runner`，且通常来说，`shared runner`与项目是多对多的关系，类似于资源池。`shared runner`采用[`fair useage queue`](https://docs.gitlab.com/ee/ci/runners/README.html#how-shared-runners-pick-jobs)来调度`job`，这可以防止某个项目由于定义了过多的`job`而独占整个可用的`shared runner`集合。
- `specific runner`，它主要服务于具有特殊需求的项目，通常会结合`tag`来将`specific runner`与项目进行绑定，`specific runner`采用`FIFO`的方式调度`job`。值得注意的是，`specific runner`也可服务于多个项目，只是你需要显式的为每个项目`enable`它们。
- `group runner`，定义在`group runner`集合中的`runner`会服务于一组项目，与`shared runner`不同的是，它也采用的是`FIFO`的方式来调度`job`，这意味着一个定义了较多`job`的项目可能会长时间独占所有`runner`。

最后，通过一个示例来简要阐述`shared runner`是如何调度`job`的，即`fair useage queue`的原理，这些内容基本来自于[官方文档](https://docs.gitlab.com/ee/ci/runners/README.html#how-shared-runners-pick-jobs)。示例如下：若我们为`project 1`定义了3个`job`，为`project 2`定义了2个`job`，为`project 3`定义了1个`job`，则一个典型的调度流程如下：首选会调度`p1-j1(job 1 of project 1)`，因为此时它是所有不存在正运行的`job`的项目中编号最小的`job`，这句话很重要。然后调度`p2-j4`，因为此时`porject 1`有一个正运行的作业`job 1`。再调度`p3-j6`，原因是类似的。其次，调度`p1-j2`，因为它是存在正在运行`job`的项目中，包含最少运行的`job`数（每个项目都有1个）的项目的尚未运行的`job`的编号。接下来的调度依次是`p2-j5`、`p1-j3`。需要注意的是，上面描述的调度顺序的前提是每个被调度的`job`都一直处于运行状态。因为，若当我们调度`p1-j1`时，它立刻完成了，则下一个调度的`job`则仍然从`project 1`中挑选，即为`p1-j2`。因此，总结一下，当调度`job`时，首先看哪个`project`存在最少的处于运行状态的`job`数量，然后在此`project`中选择尚未运行的`job`集合中编号最小的`job`。

此小节阐述了`gitlab runner`的基本原理，以及不同类型的`runner`的适用情形，同时通过一个示例来阐述`shared runner`是如何调度`job`的。更多详细内容可参考[官方文档](https://docs.gitlab.com/ee/ci/runners/README.html)。

## k8s 中安装`gitlab runner` 的详细流程

本小节侧重实践，详细阐述在`k8s`中安装`gitlab runner`的整个过程。其中，`gitlab`的版本是`GitLab Community Edition 9.4.2`，`minikube`的版本是`v1.2.0`，`Kubernetes`的版本是`v1.15.0`，最后`Docker`的版本是`18.09.6`。具体而言，主要包括两个方面的内容：一是`minikube`安装的注意事项，其次是在`k8s`中部署`gitlab runner`的详细流程。基本都是参考官方文档。

### minikube 安装注意事项

需要说明的是，在这之前你应该有一个`kubernetes`集群，笔者的实验环境是`VMware® Workstation 15 Pro`安装`ubuntu18.04 desktop`系统，然后搭建了`minikube`（单节点）的`k8s`环境，`vm driver`采用的是`kvm2`。

> 笔者之前尝试过`virtualbox hypervisor`，并以`virtualbox`和`kvm2`作为`vm driver`，但都没有成功。简单说，`virtualbox hypervisor`不支持对硬件的虚拟化。相关的`issue`可以看[这里](https://github.com/kubernetes/minikube/issues/4348)和[这里](https://github.com/kubernetes/minikube/issues/2991)，`virtualbox`官方一个相关说明，在[这里](https://www.virtualbox.org/ticket/4032)。如果有读者在`virtualbox hypervisor`下成功安装`kvm2`或`virtual`作为`vm driver`，还请留言。

关于`minikube`的安装，直接参考[官方文档](https://kubernetes.io/docs/tasks/tools/install-minikube/)即可。但需要注意GFW，若不能上外网，可以尝试通过拉取国内镜像源来安装，参考[这里](https://yq.aliyun.com/articles/221687)。另外一个在安装前需要关注的操作是：`egrep --color 'vmx|svm' /proc/cpuinfo`，必须确保此命令的输出不为空，否则，表明你的系统不支持虚拟化。安装完之后，可以执行一个`hello world`，参考[这里](https://github.com/kubernetes/minikube)，以确认`minkube`已经成功安装。

### k8s 中安装`gitlab runner`

前述提到`gitlab runner`只是一个使用`go`编写的程序。因此，理论上在任何安装了`go`的环境都能安装`gitlab runner`，不仅仅局限于`k8s`的环境，详解可参考[这里](https://docs.gitlab.com/runner/install/)。但若将`runner`安装在`k8s`中，其原理与其它方式还是略有区别，这个在后面阐述。另外，在前一小节中提到，`runner`会周期性的轮询`gitlab server`以确认当前是否有需要执行的`pipeline`，换言之，`runner`是可以安装在你本地环境的（不需要一个外网能够访问的ip），但`gitlab server`若安装在本地环境（主机或`docker`），你要确保它能够被`runner`访问到。

官方提供的在`k8s`安装`runner`的[最新教程](https://docs.gitlab.com/runner/install/kubernetes.html)采用了[`helm`](https://helm.sh/docs/)，因此，在安装`runner`前需要提前在`k8s`集群中安装`helm`。简单而言，`helm`是一个在`k8s`环境下的软件包管理工具，类似于`ubuntu`下的`apt-get`或`centos`下的`yum`。`helm`会为我们管理一个软件包所包含的一系列配置文件，通过使用`helm`，应用发布者可以很方便地打包(`pakcage`)应用、管理应用依赖关系和应用版本，并将其发布应用到软件仓库。另外，`helm`还提供了`k8s`上的软件部署和卸载、应用回滚等高阶功能。`helm`是一个典型的`cs`架构，为了让`helm`帮助我们管理`k8s`中的软件包，它会将`tiller server`安装在`k8s`集群中，然后使用`helm client`与之通信来完成指定功能。在`helm`安装过程中，需要注意的就是`helm`的权限(`RBAC`)的配置，在笔者的实验中，为了方便测试，给予了`tiller`这个`ServiceAccount`的`role`为`cluster-admin`。图3为`helm`的相关安装配置。更多关于`helm`的中文资料可以参考[这里](https://zhaohuabing.com/2018/04/16/using-helm-to-deploy-to-kubernetes/)和[这里](https://whmzsu.github.io/helm-doc-zh-cn/quickstart/install-zh_cn.html)。

事实上，所谓的在`k8s`中安装`gitlab runner`，也就是将`gitlab runner`这个`helm chart`包安装在`k8s`中，`runner`具体是使用`kubernetes executor`执行`job`，`executor`会连接到`k8s`集群中的`kubernetes API`，并为每个`job`创建一个`pod`。`pod`是`k8s`中应用编排的最小单元（不是`container`），相当于一个逻辑/虚拟机主机，它包含了一组共享资源的`contaienr`，这些`container`共享相同的`network namespace`，可通过`localhost`通信，另外，这些`container`可声明共享同一个`volume`。通常而言，为`gitlab-ci`的每个`job`动态创建的`pod`至少包含两个`container`（也有三个的情况），分别是`build container`和`service container`，其中`build container`即用于构建`job`，而当在`.gitlab-ci.yml`中定义了[`service`标签](https://docs.gitlab.com/ce/ci/yaml/README.html#services)时，就会此`service container`来运行对应的`service`，以连接到`build container`，并协助它完成指定功能。这同`docker`中的[`link container`](https://docs.docker.com/engine/userguide/networking/default_network/dockerlinks/)原理类似。最后，当使用`docker/docker+machine/kubernetes`的`executors`时，`gitlab runner`会使用基于[`helper image`](https://docs.gitlab.com/runner/configuration/advanced-configuration.html#helper-image)的`help container`，它的使用是处理`git`、` artifacts`以及`cache`相关操作。它包含了`gitlab-runner-helper`二进制包，提供了`git`、`git-lfs`、` SSL certificates store `等命令。但当使用`kubernetes executor`时，`runner`会临时从`gitlab/gitlab-runner-helper`下载镜像而并非从本地的归档文件中加载此二进制文件。

现在可以执行正式的安装操作了。安装之前，通常我们需要配置`runner`，这通过在[`values.yaml`](https://gitlab.com/charts/gitlab-runner/blob/master/values.yaml)中自定义特定选项来实现，以覆盖默认选项值。配置过程也较为简单，唯一必须配置的选项是`gitlabUrl`和`runnerRegistrationToken`，前者即为`gitlab server`的`url`，它可以是一个完整域名（如`https://example.gitlab.com`），也可以是一个`ip`地址（记得不要漏掉端口号），而后者则为你的`gitlab`的`token`，以表明你具备向`gitlab`添加`runner`的权限。这两个值可以从`gitlab-project-settings-pipelines`下获取到（注意因为笔者的`gitlab`帐户只是普通帐户，意味着只能注册`specific runner`，它与`admin`的稍有不同）。确认了这两个最核心的配置选项后，如果你不需要覆盖其它的默认选项值，就可以开始[安装](https://docs.gitlab.com/runner/install/kubernetes.html#installing-gitlab-runner-using-the-helm-chart)了，非常简单。仅有两个步骤：

其一，将`gitlab`这个`repository`添加到`helm repository list`中。执行下面的命令即可：
`helm repo add gitlab https://charts.gitlab.io`
其二，使用`helm`来安装`gitlab runner chart`，如下：
`helm install --namespace <NAMESPACE> --name gitlab-runner -f <CONFIG_VALUES_FILE> gitlab/gitlab-runner`
其中`<NAMESPACE>`指定了你需要将`runner`安装在哪个`namespace`，因为，你很可能需要预先创建此`namespace`，这通过`kubectl create namespace <NAMESPACE>`命令来实现。而后一个参数则为你定义的`values.yml`配置文件的路径。

附带介绍下，另外两个重要的操作——`gitlab runner`的升级以及卸载操作。升级操作同安装操作非常类似，`<RELEASE-NAME>`即为`gitlab runner`，`release`是`helm`的概念，表示安装在`k8s`中的一个软件：
`helm upgrade --namespace <NAMESPACE> -f <CONFIG_VALUES_FILE> <RELEASE-NAME> gitlab/gitlab-runner`

最后的卸载操作可通过如下命令实现：
`helm delete --namespace <NAMESPACE> <RELEASE-NAME>`
值得注意的是，即使执行了此卸载操作，`helm`仍然保留已删除`release`的记录，这允许你回滚已删除的资源并重新激活它们。若要彻底删除，可以加上`--purge`选项。

至此，最简版本的`gitlab runner`已经安装完毕。当执行`helm install`命令后，它会打印出此次安装所涉及的对象资源，如下：

```
NAME:   gitlab-runner
LAST DEPLOYED: Fri Jul  5 11:06:30 2019
NAMESPACE: kube-gitlab-test
STATUS: DEPLOYED

RESOURCES:
==> v1/ConfigMap
NAME                         DATA  AGE
gitlab-runner-gitlab-runner  5     0s

==> v1/Pod(related)
NAME                                          READY  STATUS    RESTARTS  AGE
gitlab-runner-gitlab-runner-6f996b5464-8wwnz  0/1    Init:0/1  0         0s

==> v1/Secret
NAME                         TYPE    DATA  AGE
gitlab-runner-gitlab-runner  Opaque  2     0s

==> v1/ServiceAccount
NAME                         SECRETS  AGE
gitlab-runner-gitlab-runner  1        0s

==> v1beta1/Deployment
NAME                         READY  UP-TO-DATE  AVAILABLE  AGE
gitlab-runner-gitlab-runner  0/1    1           0          0s

==> v1beta1/Role
NAME                         AGE
gitlab-runner-gitlab-runner  0s

==> v1beta1/RoleBinding
NAME                         AGE
gitlab-runner-gitlab-runner  0s


NOTES:

Your GitLab Runner should now be registered against the GitLab instance reachable at: "http://*******/"
```

你也可以执行如图4中的命令，以确认是否安装成功，甚至使用`-o yaml`选项来查看各对象配置的详细内容。

在本小节的最后，我们来看一下`values.yml`文件中定义的核心配置选项。其它的配置在下一小节阐述。

```yaml
## The GitLab Server URL (with protocol) that want to register the runner against
## ref: https://docs.gitlab.com/runner/commands/README.html#gitlab-runner-register
## gitlab server 的地址
gitlabUrl: https://gitlab.example.com/

## The registration token for adding new Runners to the GitLab server. This must
## be retrieved from your GitLab instance.
## ref: https://docs.gitlab.com/ee/ci/runners/
## 向 gitlab server 添加 runner 的令牌
runnerRegistrationToken: ""

## Set the certsSecretName in order to pass custom certificates for GitLab Runner to use
## Provide resource name for a Kubernetes Secret Object in the same namespace,
## this is used to populate the /etc/gitlab-runner/certs directory
## ref: https://docs.gitlab.com/runner/configuration/tls-self-signed.html#supported-options-for-self-signed-certificates
## 当需要向 gitlab runner 提供自定义证书时，可在此附上证书对应的secret名称
##（secret 需提前安装在k8s）
#certsSecretName:

## Configure the maximum number of concurrent jobs
## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-global-section
## 使用所有注册的 runner 能并行执行的 job 数量的上限，0 表示不限制
concurrent: 10

## Defines in seconds how often to check GitLab for a new builds
## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-global-section
## runner 轮询 gitlab server 来查询是否有待执行的 pipeline 的间隔时间/s
checkInterval: 30

## For RBAC support:
## runner 的 RBAs 权限配置（RBAC是kubernetes 1.6版本默认使用的权限机制）。
## 若你想 helm 为你创建对应角色、权限及角色绑定，则设置为 true，否则若你已额外创建，则设置为false
rbac:
  create: true

  ## Run the gitlab-bastion container with the ability to deploy/manage containers of jobs
  ## cluster-wide or only within namespace
  ## false 表示创建的角色是隶属于某个 namespace,反之属于 cluster 范围内，后者权限更大
  clusterWideAccess: false

  ## If RBAC is disabled in this Helm chart, use the following Kubernetes Service Account name.
  ## 若你额外创建了 RBAC 相关配置，则在这里指定 ServiceAccount 的名称
  ## default 是每个 namespace 中自带的一个帐户，但其拥有的角色可能不具备执行某些操作的权限
  # serviceAccountName: default

## Configuration for the Pods that the runner launches for each new job
## 配置 runner 为每一个 job 动态创建的 pod
runners:
  ## Default container image to use for builds when none is specified
  ## 基础容器所使用的镜像
  image: ubuntu:18.04

  ## Run all containers with the privileged flag enabled
  ## This will allow the docker:stable-dind image to run if you need to run Docker
  ## commands. Please read the docs before turning this on:
  ## ref: https://docs.gitlab.com/runner/executors/kubernetes.html#using-docker-dind
  ## 这个选项对于 ci/cd 应用场景至关重要。简单而言，true 表示启用 pod 中容器的特权，
  ## 此时，容器几乎具有容器外运行在宿主机的进程完全相同的权限，可以访问所有的设备，存在一定风险
  ## 但是开启此选项是实现 docker-in-docker 的前提，后面会详细阐述 dind
  privileged: false

  ## Namespace to run Kubernetes jobs in (defaults to 'default')
  ## 配置 runner 为每个 job 创建的 pod 所运行的 namespace
  # namespace:

  ## Build Container specific configuration
  ## build 容器，用作 stage 中的基础容器
  builds:
    # cpuLimit: 200m
    # memoryLimit: 256Mi
    cpuRequests: 100m # 基础 cpu 占用量，表示 0.1 的cpu，m 表示 Milli 毫
    memoryRequests: 128Mi # 基础内存占用量，表示 128M 的内存

  ## Service Container specific configuration
  ## service 容器，通过 link build 容器，以协助 build 容器完成特定功能
  services:
    # cpuLimit: 200m
    # memoryLimit: 256Mi
    cpuRequests: 100m
    memoryRequests: 128Mi

  ## Helper Container specific configuration
  ## helper 容器，用于执行 git, git-lfs, SSL certificates store 等命令
  helpers:
    # cpuLimit: 200m
    # memoryLimit: 256Mi
    cpuRequests: 100m
    memoryRequests: 128Mi
```

至此，关于在`k8s`中安装`gitlab runner`的完整流程已经阐述完毕。事实上，后面的版本中使用`helm`来安装`gitlab runner`是非常便捷的。但同时，它也向我们隐藏了相关的配置细节，为了更好的理解`runner`在`k8s`中的运行原理，有必要详细了解相关的配置文件。最后，值得注意的是，`runner`使用`kubernetes executor`的原理也是值得关注的。

## gitlab runner 配置详解

为了进一步理解`gitlab ruuner`的相关原理，本小节会详细解读有关其[`value.yml`]()配置选项，在正式的生产环境中，我们可能需要自定义其中的大部分的配置选项的值。其中，核心配置选项已在上一节中详细阐述。

```yaml
## GitLab Runner Image
##
## ref: https://hub.docker.com/r/gitlab/gitlab-runner/tags/
## gitlab runner 的默认镜像
# image: gitlab/gitlab-runner:alpine-v11.6.0

## ref: http://kubernetes.io/docs/user-guide/images/#pre-pulling-images
## gitlab runner 镜像的拉取策略，Never/IfNotPresent/Always
imagePullPolicy: IfNotPresent

## ref: https://docs.gitlab.com/runner/commands/README.html#gitlab-runner-register
## gitlab server 的地址
# gitlabUrl: http://gitlab.your-domain.com/

## ref: https://docs.gitlab.com/ce/ci/runners/README.html
## 向 gitlab server 添加 runner 的令牌
# runnerRegistrationToken: ""

## The Runner Token for adding new Runners to the GitLab Server. This must
## be retrieved from your GitLab Instance. It is token of already registered runner.
## ref: (we don't yet have docs for that, but we want to use existing token)
## 已注册的 runner 的token。不是特别清楚此选项的意义，感觉同上一个选项类似
# runnerToken: ""

## ref: https://docs.gitlab.com/runner/commands/README.html#gitlab-runner-unregister
## 当 runner 被重新创建时，会导致 gitlab server 引用一个不存在的 runner，因此，开启此选项表示在
## runner 关闭时会自动从 gitlab server 取消注册
unregisterRunners: true

## ref: https://docs.gitlab.com/runner/configuration/tls-self-signed.html#supported-options-for-self-signed-certificates
## 当需要向 gitlab runner 提供自定义证书时，可在此附上证书对应的secret名称
##（secret 需提前安装在k8s）
# certsSecretName:

## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-global-section
## 使用所有注册的 runner 能并行执行的 job 数量的上限，0 表示不限制
concurrent: 10

## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-global-section
## runner 轮询 gitlab server 来查询是否有待执行的 pipeline 的间隔时间/s
checkInterval: 30

## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-global-section
## gitlab runner 的日志级别
# logLevel:

## runner 的 RBAs 权限配置（RBAC是kubernetes 1.6版本默认使用的权限机制）。
## 若你想 helm 为你创建对应角色、权限及角色绑定，则设置为 true，否则若你已额外创建，则设置为false
rbac:
  create: false

  ## false 表示创建的角色是隶属于某个 namespace,反之属于 cluster 范围内，后者权限更大
  clusterWideAccess: false

  ## 若你额外创建了 RBAC 相关配置，则在这里指定 ServiceAccount 的名称
  ## default 是每个 namespace 中自带的一个帐户，但其拥有的角色可能不具备执行某些操作的权限
  # serviceAccountName: default

## ref: https://docs.gitlab.com/runner/monitoring/#configuration-of-the-metrics-http-server
## 是否开启 metric 数据记录器，使用的是 Prometheus metrics exporter
metrics:
  enabled: true

## 配置 runner 为每一个 job 动态创建的 pod 相关选项
runners:
  ## 基础容器(build container)默认使用的镜像
  image: ubuntu:18.04

  ## ref: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
  ## 当从私有 registry 拉取镜像时，需要预先在 k8s 中创建对应的 secret，并在这里填写对应的 secret
  # imagePullSecrets: []

  ## 镜像拉取策略，Never/IfNotPresent/Always
  # imagePullPolicy: ""

  ## Defines number of concurrent requests for new job from GitLab
  ## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html#the-runners-section
  ## gitlab-ci 能够并发请求的 job 数量
  # requestConcurrency: 1

  ## 此 runner 是否与特定项目绑定
  # locked: true

  ## ref: https://docs.gitlab.com/ce/ci/runners/#using-tags
  ## runner 所运行的 pod 所关联的 tag
  # tags: ""

  ## ref: https://docs.gitlab.com/runner/executors/kubernetes.html#using-docker-dind
  ## 这个选项对于 ci/cd 应用场景至关重要。简单而言，true 表示启用 pod 中容器的特权，
  ## 此时，容器几乎具有容器外运行在宿主机的进程完全相同的权限，可以访问所有的设备，存在一定风险
  ## 但是开启此选项是实现 docker-in-docker 的前提，后面会详细阐述 dind
  privileged: false

  # gitlab runner 为 runner-token and runner-registration-token 创建的 secret 的名称
  # secret: gitlab-runner

  ## 配置 runner 为每个 job 创建的 pod 所运行的 namespace
  # namespace:

  ## ref: https://gitlab.com/gitlab-org/gitlab-runner/blob/master/docs/configuration/autoscale.md#distributed-runners-caching
  ## 分布式 runner 缓存相关的配置，这里暂且忽略
  cache: {}
    ## General settings
    # cacheType: s3
    # cachePath: "gitlab_runner"
    # cacheShared: true

    ## S3 settings
    # s3ServerAddress: s3.amazonaws.com
    # s3BucketName:
    # s3BucketLocation:
    # s3CacheInsecure: false
    # secretName: s3access

    ## GCS settings
    # gcsBucketName:
    ## Use this line for access using access-id and private-key
    # secretName: gcsaccess
    ## Use this line for access using google-application-credentials file
    # secretName: google-application-credentials

  ## build 容器，用作 stage 中的基础容器
  builds:
    # cpuLimit: 200m
    # memoryLimit: 256Mi
    cpuRequests: 100m # 基础 cpu 占用量，表示 0.1 的cpu，m 表示 Milli 毫
    memoryRequests: 128Mi # 基础内存占用量，表示 128M 的内存

  ## service 容器，通过 link build 容器，以协助 build 容器完成特定功能
  services:
    # cpuLimit: 200m
    # memoryLimit: 256Mi
    cpuRequests: 100m
    memoryRequests: 128Mi

  ## helper 容器，用于执行 git, git-lfs, SSL certificates store 等命令
  helpers:
    # cpuLimit: 200m
    # memoryLimit: 256Mi
    cpuRequests: 100m
    memoryRequests: 128Mi

  ## runner 动态创建的 pod 所关联的 ServiceAccount 的名称，它可能需要被赋予特定角色
  # serviceAccountName:

  ## If Gitlab is not reachable through $CI_SERVER_URL
  ##
  # cloneUrl:

  ## ref: https://kubernetes.io/docs/concepts/configuration/assign-pod-node/
  ## 限制 gitlab-ci 的 pod 只能被调度在指定 node 上
  # nodeSelector: {}

  ## 指定 gitlab-ci 的 pod 所包含的 labels
  # podLabels: {}

  ## 指定 gitlab-ci 的 pod 所包含的 annotations
  # podAnnotations: {}

  ## ref: https://docs.gitlab.com/runner/commands/#gitlab-runner-register
  ## 为 gitlab-ci runner 注入指定的环境变量，注意不是 runner 动态创建的 pod 的环境变量
  # env:
  #   NAME: VALUE

## ref: http://kubernetes.io/docs/user-guide/compute-resources/
## 为 runner 配置资源限制
resources: {}
  # limits:
  #   memory: 256Mi
  #   cpu: 200m
  # requests:
  #   memory: 128Mi
  #   cpu: 100m

## Ref: https://kubernetes.io/docs/concepts/configuration/assign-pod-node/#affinity-and-anti-affinity
## 配置 runner 所在 pod 的亲和性，同 label的作用类似，都用于指定 pod的调度策略，
## 但其功能更加强大，它可以设置简单的逻辑组合，不单单是 label 所局限的简单的相等匹配
affinity: {}

## Ref: https://kubernetes.io/docs/user-guide/node-selection/
## gitlab runner 的节点选择器，即指定只能运行在哪些节点上
nodeSelector: {}
  # node-role.kubernetes.io/worker: "true"

## List of node taints to tolerate (requires Kubernetes >= 1.6)
## Ref: https://kubernetes.io/docs/concepts/configuration/taint-and-toleration/
## tolerations 与 taints 相关。一个被标记为 Taints 的节点，除非 pod 也被标识为可以容忍污点节点，
## 否则该 Taints 节点不会被调度 pod。
## 典型的，在 kubernetes 集群，Master 节点通过被标记为 taints 以保留给 Kubernetes 系统组件使用
## 但若仍然希望某个 pod 调度到 taint 节点上，则必须在 Spec 中做出Toleration定义，才能调度到该节点
tolerations: []
  # Example: Regular worker nodes may have a taint, thus you need to tolerate the taint
  # when you assign the gitlab runner manager with nodeSelector or affinity to the nodes.
  # - key: "node-role.kubernetes.io/worker"
  #   operator: "Exists"

## ref: https://docs.gitlab.com/runner/configuration/advanced-configuration.html
## 环境变量，在执行 register 命令时使用，以进一步控制注册的过程和 config.toml 配置文件
# envVars:
#   - name: RUNNER_EXECUTOR
#     value: kubernetes

## 主机名与ip的映射，它们可以被注入到 runner 所在 pod 的 host 文件
hostAliases: []
  # Example:
  # - ip: "127.0.0.1"
  #   hostnames:
  #   - "foo.local"
  #   - "bar.local"
  # - ip: "10.1.2.3"
  #   hostnames:
  #   - "foo.remote"
  #   - "bar.remote"

## 附加在 runner 所在 pod 上的 annotations
podAnnotations: {}
  # Example:
  # iam.amazonaws.com/role: <my_role_arn>
```

最后强调下关于`namespace`和`ServerAccount`的权限的问题。事实上`gitlab runner`会存在于某一个`namespace`，同时它会关联一个`ServiceAccount`，此`sa`决定了其为每个`job`动态创建的`pod`操作的权限问题。典型的，若其`sa`只具备某个`namespace`下的所有权限，则它不能在集群范围内其它`namespace`中创建`pod`。且动态创建的`pod`所在的`namespace`可以与`runner`所在`namespace`不同。最后，由`runner`动态创建出来的`pod`，也会关联一个`sa`，此`sa`所绑定的`role`决定了在对应的`job`中能够执行的脚本操作，比如，在`job`中又创建一个`pod`（我们后面的`ci/cd`方案中就属于此种情况），那么，此`pod`所处的`namespace`也可以和`job`对应的`pod`所处的`namespace`不同，这取决于`job`所关联的`sa`的权限。读者若有兴趣，完全可以自己尝试一下这些配置会带来什么影响。

至此，关于`runner`的相关的配置已经讲解完毕。大部分还是容易理解的，读者可以通过实验来验证它们的功能。在生产环境中，可能需要覆盖大多默认配置选项。

简单小结，本文详细分析了在`k8s`中安装`gitlab runner`的完整流程。在阐述具体的安装操作前，先是阐述了`gitlab-ci/cd`的核心概念和基本原理，这有助于了解`gitlab-ci`到底是如何工作。其次，阐述了`gitlab runner`的相关知识，`gitlab runner`才是定义在`.gitlab-ci.yml`的脚本的执行器，但它并不特殊，只是一个使用`go`写的应用程序而已。然后，重点阐述了`k8s`中安装`gitlab runner`的详细步骤，附带阐述了`kubernetes executor`的原理和`helm`的基本作用。同时，详细解释了`gitlab runner chart`包的`values.yml`配置文件的核心配置选项。最后，为了更深入了解`gitlab runner`的运行原理，简述了`values.yml`中几乎所有的配置选项。

需要提醒读者的是，整篇文件比较长。涉及到的内容也较多，提供的参考资料也挺多。但只要耐心跟随整个流程，在`k8s`中安装`gitlab runner`是完全没有问题的。



参考文献

`minikube`
[1].https://kubernetes.io/docs/tasks/tools/install-minikube/
[2].https://github.com/kubernetes/minikube
[3].https://github.com/kubernetes/minikube/issues/2991

`gitlab-ci/cd`
[1].https://docs.gitlab.com/ee/ci/
[2].https://docs.gitlab.com/ee/ci/introduction/index.html#how-gitlab-cicd-works
[3].https://docs.gitlab.com/ee/ci/yaml/README.html
[4].https://gitlab.com/gitlab-examples

`gitlab runner`
[1].https://docs.gitlab.com/ee/ci/runners/README.html
[2].https://docs.gitlab.com/runner/
[3].https://docs.gitlab.com/ce/ci/docker/using_docker_images.html#what-is-a-service

`helm`
[1].https://helm.sh/docs/
[2].https://zhaohuabing.com/2018/04/16/using-helm-to-deploy-to-kubernetes/
[3].https://www.qikqiak.com/post/first-use-helm-on-kubernetes/

`kubernetes executor`
[1].https://docs.gitlab.com/runner/executors/kubernetes.html

`install runner in k8s`
[1].https://docs.gitlab.com/runner/install/kubernetes.html
[2].https://docs.gitlab.com/runner/configuration/advanced-configuration.html

