---
title: go build 命令基本工作过程
date: 2020-05-19 19:46:33
categories:
- go
tags:
- go
---

Go 是一种支持原生并发、带垃圾回收同时编译速度快的语言，这一定程度上归功于其实现了语言自身的 runtime，这类似于 C 运行时 libc。正如官方文档所说，Go 是一种快速的、静态类型的编译语言，以至于让人感觉其就像一种动态类型的解释语言。本文从原理上阐述`go build`命令具体工作过程，即阐述 Go 项目如何从由语言源码构成的代码文件转换成机器码组成的可执行二进制文件。简单而言，逻辑上，build 命令编译用户指定的导入路径所对应的应用程序包及其依赖包，但并不安装编译的结果。而从执行步骤上看，build 命令执行过程包含编译（compile）和链接（link）两个步骤。

<!-- More-->

本文假设你已具备 Go 语言入门知识，比如[如何搭建 Go 开发环境](https://golang.org/doc/install)，同时[创建一个 Go 项目并顺利运行起来](https://www.digitalocean.com/community/tutorials/how-to-install-go-and-set-up-a-local-programming-environment-on-ubuntu-18-04)，在这过程中，你会了解 GOPATH、GOBIN 等重要环境变量的含义，同时也清楚 Go 项目源码的标准组织结构，具体可参考[这里](https://golang.org/doc/gopath_code.html)。另外，本文并非是语言使用或介绍教程，换言之，本文对于所阐述的内容并不会面面俱到，比如，本文不会详细介绍 build 命令各选项的含义及具体用法，因此你需要提前或同时使用 man 指令或者[官方文档](https://golang.org/cmd/go/)来详细了解相关命令。另外，本文所有实验均在 Ubuntu 18.04 x86_64，go1.12 linux/amd64 的环境下测试通过。

## 以一个实例来剖析 go build 命令执行过程

我们以一个简单测试项目 [helloworld](https://github.com/qqzeng/go-code-snippet/tree/master/helloworld) 来阐述`go build`命令的具体工作过程，项目组织结构如下所示，我们需要知道的和本文相关的代码逻辑仅仅是`main.go`引入了 uitl 包。具体地，helloworld 包含程序启动执行入口 main 包源码文件`main.go`以及 util 包下的工具类源码文件`slice_lib.go`及其对应的单元测试源码文件`slice_lib_test.go`，事实上，它们分别对应 Go 项目中所包含的命令源码、库源码、测试源码三类源代码文件。

```shell
helloworld/
├── main.go
└── util
    ├── slice_lib.go
    └── slice_lib_test.go
```

然后，我们进入到项目要目录下，执行`go build -x -work main.go`命令来构建（注意，官方并没有将 build 命令称之为构建，这里我们不准确地将编译和链接两个步骤称为构建，下文也是类似）此项目。其中，-x 选项表示打印构建过程所执行的命令，而 -work 选项表示保留在构建过程中创建的临时文件及目录，以方便我们了解构建的细节，build 命令的更多选项可参考[这里](https://golang.org/cmd/go/#hdr-Compile_packages_and_dependencies)，或者使用 man 命令。另外，build 命令后也可以跟隶属单个包的源码文件列表。同时，build 会忽略测试源码文件。最后，当编译包含单个 main 包源码文件时，它以 build 命令后附加的源码文件列表中第一个文件的名称来命名其构建生成的二进制可执行文件，并输出到当前执行命令所在的目录。注意，若 build 后未跟任何源文件或包名（或项目名），则其生成的二进制可执行文件的名称为对应的包名（或项目名）。build 命令输出结果如下所示。

```shell
ubuntu@VM-0-14-ubuntu:~/workSpaces/go/src/github.com/qqzeng/helloworld$ go build -x -work main.go
WORK=/tmp/go-build634787878
mkdir -p $WORK/b029/
cat >$WORK/b029/importcfg << 'EOF' # internal
# import config
EOF
cd /home/ubuntu/workSpaces/go/src/github.com/qqzeng/helloworld/util
/usr/local/go/pkg/tool/linux_amd64/compile -o $WORK/b029/_pkg_.a -trimpath $WORK/b029 -p \
github.com/qqzeng/helloworld/util -complete -buildid T0vxP0OAL4NQLqv8Z5hZ/T0vxP0OAL4NQLqv8Z5hZ -goversion \
go1.12 -D "" -importcfg $WORK/b029/importcfg -pack ./slice_lib.go
/usr/local/go/pkg/tool/linux_amd64/buildid -w $WORK/b029/_pkg_.a # internal
cp $WORK/b029/_pkg_.a /home/ubuntu/.cache/go-build/00/00c7955e923d12630ae21b9150bf5cd83ad34d446a411992f2818bd1953a03e2-d # internal
mkdir -p $WORK/b001/
cat >$WORK/b001/importcfg << 'EOF' # internal
# import config
packagefile fmt=/usr/local/go/pkg/linux_amd64/fmt.a
packagefile github.com/qqzeng/helloworld/util=$WORK/b029/_pkg_.a
packagefile runtime=/usr/local/go/pkg/linux_amd64/runtime.a
EOF
cd /home/ubuntu/workSpaces/go/src/github.com/qqzeng/helloworld
/usr/local/go/pkg/tool/linux_amd64/compile -o $WORK/b001/_pkg_.a -trimpath $WORK/b001 -p main -complete -  \
buildid NQfuV250impAGJ9_g3cW/NQfuV250impAGJ9_g3cW -goversion go1.12 -D  \
_/home/ubuntu/workSpaces/go/src/github.com/qqzeng/helloworld -importcfg $WORK/b001/importcfg -pack ./main.go
/usr/local/go/pkg/tool/linux_amd64/buildid -w $WORK/b001/_pkg_.a # internal
cp $WORK/b001/_pkg_.a /home/ubuntu/.cache/go-build/63/63457873f0a007f7287e97b43e05b31477c7f8d1bb0008df9ceaaf10ba9a665a-d # internal
cat >$WORK/b001/importcfg.link << 'EOF' # internal
packagefile command-line-arguments=$WORK/b001/_pkg_.a
packagefile fmt=/usr/local/go/pkg/linux_amd64/fmt.a
packagefile github.com/qqzeng/helloworld/util=$WORK/b029/_pkg_.a
packagefile runtime=/usr/local/go/pkg/linux_amd64/runtime.a
packagefile errors=/usr/local/go/pkg/linux_amd64/errors.a
packagefile internal/fmtsort=/usr/local/go/pkg/linux_amd64/internal/fmtsort.a
packagefile io=/usr/local/go/pkg/linux_amd64/io.a
packagefile math=/usr/local/go/pkg/linux_amd64/math.a
packagefile os=/usr/local/go/pkg/linux_amd64/os.a
packagefile reflect=/usr/local/go/pkg/linux_amd64/reflect.a
packagefile strconv=/usr/local/go/pkg/linux_amd64/strconv.a
packagefile sync=/usr/local/go/pkg/linux_amd64/sync.a
packagefile unicode/utf8=/usr/local/go/pkg/linux_amd64/unicode/utf8.a
packagefile internal/bytealg=/usr/local/go/pkg/linux_amd64/internal/bytealg.a
packagefile internal/cpu=/usr/local/go/pkg/linux_amd64/internal/cpu.a
packagefile runtime/internal/atomic=/usr/local/go/pkg/linux_amd64/runtime/internal/atomic.a
packagefile runtime/internal/math=/usr/local/go/pkg/linux_amd64/runtime/internal/math.a
packagefile runtime/internal/sys=/usr/local/go/pkg/linux_amd64/runtime/internal/sys.a
packagefile sort=/usr/local/go/pkg/linux_amd64/sort.a
packagefile sync/atomic=/usr/local/go/pkg/linux_amd64/sync/atomic.a
packagefile math/bits=/usr/local/go/pkg/linux_amd64/math/bits.a
packagefile internal/poll=/usr/local/go/pkg/linux_amd64/internal/poll.a
packagefile internal/syscall/unix=/usr/local/go/pkg/linux_amd64/internal/syscall/unix.a
packagefile internal/testlog=/usr/local/go/pkg/linux_amd64/internal/testlog.a
packagefile syscall=/usr/local/go/pkg/linux_amd64/syscall.a
packagefile time=/usr/local/go/pkg/linux_amd64/time.a
packagefile unicode=/usr/local/go/pkg/linux_amd64/unicode.a
packagefile internal/race=/usr/local/go/pkg/linux_amd64/internal/race.a
EOF
mkdir -p $WORK/b001/exe/
cd .
/usr/local/go/pkg/tool/linux_amd64/link -o $WORK/b001/exe/a.out -importcfg $WORK/b001/importcfg.link -buildmode=exe -buildid=vCNW2zZHTRjAfLGbu0Gw/NQfuV250impAGJ9_g3cW/WU9YqLv9eR4s95poEhRu/vCNW2zZHTRjAfLGbu0Gw -extld=gcc $WORK/b001/_pkg_.a
/usr/local/go/pkg/tool/linux_amd64/buildid -w $WORK/b001/exe/a.out # internal
mv $WORK/b001/exe/a.out main
```

下面我们逐步骤阐述 build 命令工作过程。第2-3行创建了临时工作目录 `/tmp/go-build545340510/`，同时在这个目录下创建了目录`b029`以用于存放 util 包所对应的源码文件编译后的静态链接文件（归档文件）。然后在4-6行导入编译步骤依赖的静态链接文件，即所编译的源文件引入的依赖库所对应的静态链接文件，因为 util 包没有依赖任何库源码文件，因此这里并没有任何配置内容。

```shell
WORK=/tmp/go-build634787878
mkdir -p $WORK/b029/
```

```shell
b029
├── importcfg
└── _pkg_.a
```

接下来，在第7行进入 util 包所在的目录后，第8-10行使用 compile 命令工具执行一个编译命令以编译库源码文件 `slice_util.go`，具体地，使用 -o 选项指定编译生成的静态链接文件名`_pkg_.a`，-p 选项指定编译的源码包，而  -buildid 指定此次构建的 ID，最后 -pack 选项表示编译过程中绕过中间对象文件（后缀为 .o 的文件），而直接生成一个存档文件（静态链接文件），若不指定此选项，则会首先生成以 .o 为后缀的中间对象文件，然后将各对象文件打包到一个存档文件，compile 命令及其详细选项可参考[这里](https://golang.org/cmd/compile/)。使得一提的是，使用`go tool compile -N -l -S main.go`可以得到程序的汇编代码。最后，将生成的静态链接文件重命名后拷贝到一个临时的 cache 目录`/home/ubuntu/.cache/go-build/00/...`。

```shell
cd /home/ubuntu/workSpaces/go/src/github.com/qqzeng/helloworld/util
/usr/local/go/pkg/tool/linux_amd64/compile -o $WORK/b029/_pkg_.a -trimpath $WORK/b029 -p \
github.com/qqzeng/helloworld/util -complete -buildid T0vxP0OAL4NQLqv8Z5hZ/T0vxP0OAL4NQLqv8Z5hZ -goversion \
go1.12 -D "" -importcfg $WORK/b029/importcfg -pack ./slice_lib.go
/usr/local/go/pkg/tool/linux_amd64/buildid -w $WORK/b029/_pkg_.a # internal
cp $WORK/b029/_pkg_.a /home/ubuntu/.cache/go-build/00/00c7955e923d12630ae21b9150bf5cd83ad34d446a411992f2818bd1953a03e2-d # internal
```

第13-25行则针对`main.go`执行上述类似的步骤。首先它创建`b001`来存储中间文件，同时在编译`main.go`命令源码文件之前，导入了其所依赖的三个静态链接文件，即 fmt、util 和 runtime。最后同样将生成的静态链接文件重命名后拷贝到相应的临时的 cache 目录`/home/ubuntu/.cache/go-build/63/...`。

```shell
b001
├── exe
├── importcfg
├── importcfg.link
└── _pkg_.a
```

```shell
cat >$WORK/b029/importcfg << 'EOF' # internal
# import config
EOF
cd /home/ubuntu/workSpaces/go/src/github.com/qqzeng/helloworld/util
/usr/local/go/pkg/tool/linux_amd64/compile -o $WORK/b029/_pkg_.a -trimpath $WORK/b029 -p \
github.com/qqzeng/helloworld/util -complete -buildid T0vxP0OAL4NQLqv8Z5hZ/T0vxP0OAL4NQLqv8Z5hZ -goversion \
go1.12 -D "" -importcfg $WORK/b029/importcfg -pack ./slice_lib.go
/usr/local/go/pkg/tool/linux_amd64/buildid -w $WORK/b029/_pkg_.a # internal
cp $WORK/b029/_pkg_.a /home/ubuntu/.cache/go-build/00/00c7955e923d12630ae21b9150bf5cd83ad34d446a411992f2818bd1953a03e2-d # internal
```

然后，在26-55行导入了链接阶段所链接的静态链接文件列表。值得注意的是，一方面其自动为命令源码文件生成一个虚拟包 command-line-arguments，另外，还导入了标准库的一些其它静态链接文件。

```shell
cat >$WORK/b001/importcfg.link << 'EOF' # internal
packagefile command-line-arguments=$WORK/b001/_pkg_.a
packagefile fmt=/usr/local/go/pkg/linux_amd64/fmt.a
packagefile github.com/qqzeng/helloworld/util=$WORK/b029/_pkg_.a
packagefile runtime=/usr/local/go/pkg/linux_amd64/runtime.a
# ...
packagefile internal/race=/usr/local/go/pkg/linux_amd64/internal/race.a
EOF
```

最后，第56行在`b001`目录下创建了目录`exe`用于存放链接后的二进制可执行文件，然后在此目录下使用 link 工具执行链接命令，同时通过选项 -extld=external linker（默认为 gcc 或 clang） 来链接 main 包及其依赖的静态链接文件。Go 语言可采用 static linking 或者 external linking 两种链接方式，关于链接的更多内容不在本文的介绍范围。最后将可执行的二进制文件重命名并移动到执行 build 命令的目录。关于 link 命令及其详细选项可参考[这里](https://golang.org/cmd/link/)。

```shell
mkdir -p $WORK/b001/exe/
cd .
/usr/local/go/pkg/tool/linux_amd64/link -o $WORK/b001/exe/a.out -importcfg $WORK/b001/importcfg.link -buildmode=exe -buildid=vCNW2zZHTRjAfLGbu0Gw/NQfuV250impAGJ9_g3cW/WU9YqLv9eR4s95poEhRu/vCNW2zZHTRjAfLGbu0Gw -extld=gcc $WORK/b001/_pkg_.a
/usr/local/go/pkg/tool/linux_amd64/buildid -w $WORK/b001/exe/a.out # internal
mv $WORK/b001/exe/a.out main
```

至此，整个 build 过程已经分析完毕。

## go build 的更多细节

关于 go build 命令，最后再补充几点。

- `go build`命令在执行时，通常会先递归寻找 `main.go` 所依赖的包，及其依赖的依赖，直至底顶层的包，同时如果发现有循环依赖，则直接退出。因此，若机器包含有多个逻辑核，则编译代码包的顺序可能会存在一些不确定性，但其会保证被依赖代码包 A 要先于当前包 B（B依赖A）被编译[1]；

- 前面提到在编译各个包后，compile 命令工具会将编译后的静态链接文件缓存到目录`/home/ubuntu/.cache/go-build/..`，因此，当我们再次执行 build 命令时（前提是删除之前生成的二进制文件），会发现 build 过程省略了 compile 步骤（若未删除之前生成的二进制文件，则还会省略 link 步骤，即 build 没有任何影响）。具体而言，对于那些被缓存的包所对应的静态链接文件，其在临时目录`/tmp/go-build*/`下不会生成对应的目录和文件；

- build 命令执行过程中同缓存相关的还有一个选项 -i，若开启此设置，则会将库源码文件编译生成的链接文件按源码文件中目录组织结构存放到`$GOPATH/pkg/${GOOS}_${GOARCH}/`目录。因此，当再次执行 build 命令时，同样不会再次编译对应的库源码包文件；

- 这篇文章没有涉及`go install`和`go run`两个命令，因为它们都基于`go build`命令，因此相对简单。其中 install 命令在 build 的基础上，还会安装编译后的结果文件到指定目录，准确而言是将结果文件（静态链接文件或者可执行文件）存放到相应的目录，这包括两个部分：其一是将各库源码包文件所对应的静态链接文件存放到`$GOPATH/pkg/${GOOS}_${GOARCH}/`目录，同时将生成的可执行二进制文件存放到`$GOPATH/bin/`目录（若设置了`$GOBIN`，则安装到`$GOBIN`目录）。一般而言，build 命令生成的可执行文件对于应用程序的分发、部署和测试很有帮助，而 install 命令则可以方便你在系统任意地方访问你构建的应用程序。而 run 命令则是在 build 命令的基础上执行二进制文件，并输出运行结果。

本文以一个简单是项目实例阐述`go build`命令的基本工作流程，并没有涉及过多原理性的知识点。换言之，本文的作用更多地在于使用一个实例来串联其中所涉及的 go tool 命令工具的介绍和使用。因此，读者亲自了解更多的内容并实践才能理解并掌握它们。『参考文献』部分给出了一些详细资料，文中给出的链接基本是官方文档内容[2]。

文中实践源码在[这里](https://github.com/qqzeng/go-code-snippet/tree/master/helloworld)。

## 参考文献

[1]. https://github.com/hyper0x/go_command_tutorial
[2]. https://golang.org/cmd/go/