---
title: nsq diskqueue 源码简析
date: 2019-05-19 12:08:17
categories:
- 消息队列
tags:
- 消息队列
- 分布式系统
---

`diskQueue`是`nsq`分布式实时消息队列的消息持久化存储组件。考虑到`nsq`为了限制消息积压所占的内存，同时也为了保证节点宕机消息尽可能丢失，因此，当内存消息队列`memoryMsgChan`的长度达到配置的阈值时，会将消息写入到持久化存储消息队列中。是的，`diskQueue`提供两个关键特性，一是持久化存储，二是队列接口。而在`nsq`系统中`diskQueue`的用法和`memoryMsgChan`（`buffered go channel`）基本上是相同的，因此，对于生产者或者消费者而言，消息的存储方式对于它们而言是透明的，它们只需要调用相应的接口投递或获取消息即可。这确实是数据存储的最佳实践。在此前的6篇文章已经将`nsq`相关模块的源码阐述完毕。本文的主题是`diskQueue`——持久化消息队列存储组件。重点阐述其实现原理，同时分析其为上层应用程序提供的接口。

<!--More-->

据官方介绍，`diskQueue`是从`nsq`项目中抽取而来，将它单独作为一个项目[`go-diskqueue`](https://github.com/nsqio/go-diskqueue)。它本身比较简单，只有一个源文件`diskqueue.go`。本文阐述的内容更完整的源码注释可在[这里](https://github.com/qqzeng/nsqio/tree/master/go-diskqueue)找到，注释源码版本为`v1.1.0`，仅供参考。

本文阐述的内容可分两个部分：其一，分析`diskQueue`的工作原理，这包括如何从文件中读取一条消息以及如何写入一条消息到文件系统中（考虑到写入或读取文件时，可能涉及到文件的切换，因为它需要保证单个文件的大小 不能过大，因此采用滚动写入的方式。另外在读取或写入文件时，也要考虑文件损坏的情况）。同时分析`diskQueue`提供给应用程序的接口，典型地，包括将消息写入到`diskQueue`中，从`diskQueue`读取一条消息，以及删除或清空`diskQueue`存储的消息。但本文的行文方式为：从`diskQueue`实例结构开始，围绕`diskQueue.ioLoop`主循环展开，阐述上述介绍的各个流程。

## diskQueue 实例结构

`diskQueue`结构所包含字段可以分为四个部分：

- 第一部分为`diskQueue`当前读写的文件的状态，如读取或写入索引`readPos/writePos`，读取或写入文件编号`readFileNum/writeFileNum`，以及`depth`表示当前可供读取或消费的消息的数量；
- 第二部分为`diskQueue`的元数据信息，如单个文件最大大小`maxBytesPerFile`，每写多少条消息需要执行刷盘操作`syncEvery`等待；
- 第三部分是读写文件句柄`readFile/wirteFile`，以及文件读取流`reader`或写入缓冲`writeBuf`；
- 最后一部分为用于传递信号的内部管道，如`writeChan`，应用程序可通过此管道向`diskQueue`间接压入消息，`emptyChan`应用程序通过此管道间接发出清空`diskQueue`的信号等。

```go
// diskQueue 实现了一个基于后端持久化的 FIFO 队列
type diskQueue struct {
	// run-time state (also persisted to disk)
	// 运行时状态，需要被持久化
	readPos      int64					// 当前的文件读取索引
	writePos     int64					// 当前的文件写入索引
	readFileNum  int64					// 当前读取的文件号
	writeFileNum int64					// 当前写入的文件号
	depth        int64					// diskQueue 中等待被读取的消息数

	sync.RWMutex

	// instantiation time metadata
	// 初始化时元数据
	name            string				// diskQueue 名称
	dataPath        string				// 数据持久化路径
	maxBytesPerFile int64 				// 目前，此此属性一旦被初始化，则不可变更
	minMsgSize      int32				// 最小消息的大小
	maxMsgSize      int32				// 最大消息的大小
	syncEvery       int64         		// 累积的消息数量，才进行一次同步刷新到磁盘操作
	syncTimeout     time.Duration 		// 两次同步之间的间隔
	exitFlag        int32				// 退出标志
	needSync        bool				// 是否需要同步刷新

	// keeps track of the position where we have read
	// (but not yet sent over readChan)
	// 之所以存在 nextReadPos & nextReadFileNum 和 readPos & readFileNum
    // 是因为虽然消费者已经发起了数据读取请求，但 diskQueue 还未将此消息发送给消费者，
	// 当发送完成后，会将 readPos 更新到 nextReadPos，readFileNum 也类似
	nextReadPos     int64				// 下一个应该被读取的索引位置
	nextReadFileNum int64				// 下一个应该被读取的文件号

	readFile  *os.File					// 当前读取文件句柄
	writeFile *os.File					// 当前写入文件句柄
	reader    *bufio.Reader				// 当前文件读取流
	writeBuf  bytes.Buffer				// 当前文件写入流

	// exposed via ReadChan()
	// 应用程序可通过此通道从 diskQueue 中读取消息，
    // 因为 readChan 是 unbuffered的，所以，读取操作是同步的
	// 另外当一个文件中的数据被读取完时，文件会被删除，同时切换到下一个被读取的文件
	readChan chan []byte

	// internal channels
    // 应用程序通过此通道往 diskQueue压入消息，写入操作也是同步的
	writeChan         chan []byte 
	writeResponseChan chan error		// 可通过此通道向应用程序返回消息写入结果
	emptyChan         chan int			// 应用程序可通过此通道发送清空 diskQueue 的消息
	emptyResponseChan chan error		// 可通过此通道向应用程序返回清空 diskQueue 的结果
	exitChan          chan int			// 退出信号
	exitSyncChan      chan int			// 保证 ioLoop 已退出的信号

	logf AppLogFunc
} // diskQueue.go
```

## diskQueue 构造方法

首先考虑`diskQueue`在`nsq`系统中什么情况下会被实例化？答案是在实例化`topic`或`channel`时候。`diskQueue`的实例过程比较简单，首先根据传入的参数构造`diskQueue`实例，然后从配置文件中加载`diskQueue`的重要的属性状态，这包括`readPos & writePos`,` readFileNum & writerFileNum`和`depth`，并初始化`nextReadFileNum`和`nextReadPos`两个重要的属性。最后异步开启消息处理的主循环`ioLoop`方法。

```go
// New 方法初始化一个 diskQueue 实例，并从持久化存储中加载元数据信息，然后开始启动
func New(name string, dataPath string, maxBytesPerFile int64,
	minMsgSize int32, maxMsgSize int32,
	syncEvery int64, syncTimeout time.Duration, logf AppLogFunc) Interface {
	// 1. 实例化 diskQueue
	d := diskQueue{
		name:              name,
		dataPath:          dataPath,
		maxBytesPerFile:   maxBytesPerFile,
		minMsgSize:        minMsgSize,
		maxMsgSize:        maxMsgSize,
		readChan:          make(chan []byte),
		writeChan:         make(chan []byte),
		writeResponseChan: make(chan error),
		emptyChan:         make(chan int),
		emptyResponseChan: make(chan error),
		exitChan:          make(chan int),
		exitSyncChan:      make(chan int),
		syncEvery:         syncEvery,
		syncTimeout:       syncTimeout,
		logf:              logf,
	}
	// 2. 从持久化存储中初始化 diskQueue 的一些属性状态： readPos, writerPos, depth 等
	err := d.retrieveMetaData()
	// ...
	// 3. 在一个单独的 goroutien 中执行主循环
	go d.ioLoop()
	return &d
} // diskQueue.go

// 从持久化存储中初始化 diskQueue 的一些属性状态
func (d *diskQueue) retrieveMetaData() error {
	var f *os.File
	var err error
	// 1. 获取元数据文件名 *.diskqueue.meta.dat，并打开文件，准备读取文件
	fileName := d.metaDataFileName()
	f, err = os.OpenFile(fileName, os.O_RDONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	// 2. 从文件中内容初始化特定状态属性信息 readPos, writerPos, depth
	var depth int64
	_, err = fmt.Fscanf(f, "%d\n%d,%d\n%d,%d\n",
		&depth,
		&d.readFileNum, &d.readPos,
		&d.writeFileNum, &d.writePos)
	if err != nil {
		return err
	}
	// 3. 初始化 nextReadFileNum 和 nextReadPos
	atomic.StoreInt64(&d.depth, depth)
	d.nextReadFileNum = d.readFileNum
	d.nextReadPos = d.readPos
	return nil
}
```

## diskQueue 消息处理主循环

`diskQueue`消息处理主循环`ioLoop`在其被实例化后就会开始执行。`diskQueue`包含的逻辑主要包括四个方面：从文件中读取一条消息，并压入到`readChan`管道中；将应用程序传入的消息，写入到文件；每隔一段时间，将写入缓冲的数据执行刷盘动作；最后是当应用程序调用清空`diskQueue`的接口时，执行删除并关闭`diskQueue`的动作。同时，笔者在阐述这些流程的实现细节的同时，将应用程序如何同`diskQueue`交互放在一起串联分析。下面的代码是`ioLoop`的大致框架，为了使框架更清晰省略了细节：

```go
// diskQueue 消息处理主循环
func (d *diskQueue) ioLoop() {
	for {
		// 1. 只有写入缓冲中的消息达到一定数量，才执行同步刷新到磁盘的操作
		// ...
		// 2. 刷新磁盘操作，重置计数信息，即将 writeFile 流刷新到磁盘，同时持久化元数据
		// ...
        // 3. 从文件中读取消息的逻辑
		// ...
		select {
		// 4. 当读取到数据时，将它压入到 r/readChan 通道，
            // 同时判断是否需要更新到下一个文件读取，同时设置 needSync
		case r <- dataRead:
			// ...
		// 5. 收到清空持久化存储 disQueue 的消息
		case <-d.emptyChan: // (当应用程序调用 diskQueue.Empty 方法时触发)
			// ...
		// 6. 收到写入消息到磁盘的消息 (当应用程序调用 diskQueue.Put 方法时触发)
		case dataWrite := <-d.writeChan:
			// ...
		// 7. 定时执行刷盘操作，在存在数据等待刷盘时，才需要执行刷盘动作
		case <-syncTicker.C:
			// ...
		// 8. 退出信号
		case <-d.exitChan:
			goto exit
		}
	}
exit:
    // ...
} // diskQueue.go	
```

### diskQueue 读取消息

从`diskQueue`读取一条消息涉及到的`ioLoop`方法中的步骤3和4，其中步骤2的核心逻辑为：若当前持久化中还有未被读取或消费的消息，则尝试从特定的文件(`readFileNum`)、特定偏移位置(`readPos`)读取一条消息。这个过程并不复杂，值得注意的一点是：程序中还使用了另外一组与读取相关的状态(`nextReadFileNum`和`nextReadPos`)。当消息未从文件中读取时，`readPos == nextReadPos && readFileNum == nextReadFileNum` ，当消息已从文件中读出但未发送给应用程序时，`readPos + totalBytes == nextReadPos && readFileNum == nextReadFileNum`（若涉及到文件切换，则`nextReadFileNum++ && nextReadPos == 0`），当消息已经发送给应用程序时，`readPos == nextReadPos && readFileNum == nextReadFileNum`。换言之，之所以存在`nextReadFileNum`和`nextReadPos`是因为虽然消费者已经发起了数据读取请求，但 `diskQueue`还未将此消息发送给消费者，当发送完成后，会将它们相应更新。好，文件读取过程已经阐述完毕。当消息从文件中读取出来后，是通过`diskQueue.readChan`发送给上层应用程序的，上层应用程序通过调用`diskQueue.ReadChan`获取到此管道实例，并一直等待从此管道接收消息。相关代码如下：

```go
// 获取 diskQueu 的读取通道，即 readChan，通过此通道从 diskQueue 中读取/消费消息
func (d *diskQueue) ReadChan() chan []byte {
	return d.readChan
}

func (d *diskQueue) ioLoop() {
	var dataRead []byte
	var err error
	var count int64
	var r chan []byte
	syncTicker := time.NewTicker(d.syncTimeout)
	for {
		// dont sync all the time :)
		// 1. 只有写入缓冲中的消息达到一定数量，才执行同步刷新到磁盘的操作
		// ...
		// 2. 刷新磁盘操作，重置计数信息，即将 writeFile 流刷新到磁盘，同时持久化元数据
		// ...
		// 3. 若当前还有数据（消息）可供消费
        // （即当前读取的文件编号 readFileNum < 目前已经写入的文件编号 writeFileNum
		// 或者 当前的读取索引 readPos < 当前的写的索引 writePos）
		// 因为初始化读每一个文件时都需要重置 readPos = 0
		if (d.readFileNum < d.writeFileNum) || (d.readPos < d.writePos) {
			// 保证当前处于可读取的状态，即 readPos + totalByte == nextReadPos，
			// 若二者相等，则需要通过 d.readOne 方法先更新 nextReadPos
			if d.nextReadPos == d.readPos {
				dataRead, err = d.readOne()
				if err != nil {
					d.logf(ERROR, "DISKQUEUE(%s) reading at %d of %s - %s",
						d.name, d.readPos, d.fileName(d.readFileNum), err)
					d.handleReadError()
					continue
				}
			}
			// 取出读取通道 readChan
			r = d.readChan
		} else {
            // 当 r == nil时，代表此时消息已经全部读取完毕，
            // 因此使用 select 不能将数据（消息）压入其中
			r = nil 
		}
		select {
		// 4. 当读取到数据时，将它压入到 r/readChan 通道，
            // 同时判断是否需要更新到下一个文件读取，同时设置 needSync
		case r <- dataRead:
			count++ // 更新当前等待刷盘的消息数量
			// 判断是否可以将磁盘中读取的上一个文件删除掉（已经读取完毕），同时需要设置 needSync
			// 值得注意的是，moveForward 方法中将 readPos 更新为了 nextReadPos，
            // 且 readFileNum 也被更新为 nextReadFileNum
			// 因为此时消息已经发送给了消费者了。
			d.moveForward()
		// 5. 收到清空持久化存储 disQueue 的消息
		case <-d.emptyChan: // (当应用程序调用 diskQueue.Empty 方法时触发)
			// ...
		// 6. 收到写入消息到磁盘的消息 (当应用程序调用 diskQueue.Put 方法时触发)
		case dataWrite := <-d.writeChan:
			// ...
		// 7. 定时执行刷盘操作，在存在数据等待刷盘时，才需要执行刷盘动作
		case <-syncTicker.C:
			// ...
		// 8. 退出信号
		case <-d.exitChan:
			goto exit
		}
	}
exit:
	syncTicker.Stop()
	d.exitSyncChan <- 1
} // diskQueue.go
```

当消息被压入到`readChan`管道后，随即更新等待刷盘的消息数量，然后调用`diskQueue.moveForward`方法判断是否可以将磁盘中读取的上一个文件删除掉（已经读取完毕），同时考虑是否需要设置`needSync`（因为即将读取一个新的文件），最后复原`readFileNum`和`readPos`并更新等待被读取的消息数量`depth`。相关源码如下：

```go
// 检查当前读取的文件和上一次读取的文件是否为同一个，即读取是否涉及到文件的更换，
// 若是，则说明可以将磁盘中上一个文件删除掉，因为上一个文件包含的消息已经读取完毕，
// 同时需要设置 needSync
func (d *diskQueue) moveForward() {
	oldReadFileNum := d.readFileNum
	d.readFileNum = d.nextReadFileNum
	d.readPos = d.nextReadPos
	depth := atomic.AddInt64(&d.depth, -1)
	if oldReadFileNum != d.nextReadFileNum {
		// 每当准备读取一个新的文件时，需要设置 needSync
		d.needSync = true
		fn := d.fileName(oldReadFileNum)
		err := os.Remove(fn) // 将老的文件删除
		// ...
	}
	// 检测文件末尾是否已经损坏
	d.checkTailCorruption(depth)
} // diskQueue.go
```

注意到在`moveForward`方法的最后，还检查了文件末尾是否损坏。它先通过元数据信息（4个变量）判断是否已经读到了最后一个文件的末尾，若未到，则返回。否则，通过`depth`与0的大小关系来判断文件损坏的类型或原因。详细可以查看源码中的注释，解释得较为清楚。

```go
// 检测文件末尾是否已经损坏
func (d *diskQueue) checkTailCorruption(depth int64) {
	// 若当前还有消息可供读取，则说明未读取到文件末尾，暂时不用检查
	if d.readFileNum < d.writeFileNum || d.readPos < d.writePos {
		return
	}
	// we've reached the end of the diskqueue
	// if depth isn't 0 something went wrong
	// 若代码能够执行，则正常情况下，说明已经读取到 diskQueue 的尾部，
	// 即读取到了最后一个文件的尾部了，因此，此时的 depth(累积等待读取或消费的消息数量)
	// 应该为0,因此若其不为0,则表明文件尾部已经损坏，报错。
	// 一方面，若其小于 0,则表明初始化加载的元数据已经损坏（depth从元数据文件中读取而来）
	// 原因是：实际上文件还有可供读取的消息，但depth指示没有了，因此 depth 计数错误。
	// 否则，说明是消息实体数据存在丢失的情况
	// 原因是：实际上还有消息可供读取 depth > 0,但是文件中已经没有消息了，因此文件被损坏。
	// 同时，强制重置 depth，并且设置 needSync
	if depth != 0 {
		if depth < 0 {
			d.logf(ERROR,
				"DISKQUEUE(%s) negative depth at tail (%d), metadata corruption," \
                   resetting 0...", d.name, depth)
		} else if depth > 0 {
			d.logf(ERROR,
				"DISKQUEUE(%s) positive depth at tail (%d), data loss, resetting 0...",
				d.name, depth)
		}
		// force set depth 0
		atomic.StoreInt64(&d.depth, 0)
		d.needSync = true
	}
	// 另外，若 depth == 0。
	// 但文件读取记录信息不合法 d.readFileNum != d.writeFileNum || d.readPos != d.writePos
	// 则跳过接下来需要被读或写的所有文件，类似于重置持久化存储的状态，格式化操作
	// 同时设置 needSync
	if d.readFileNum != d.writeFileNum || d.readPos != d.writePos {
		if d.readFileNum > d.writeFileNum {
			d.logf(ERROR,
				"DISKQUEUE(%s) readFileNum > writeFileNum (%d > %d), " \
                   "corruption, skipping to next writeFileNum and resetting 0...",
				d.name, d.readFileNum, d.writeFileNum)
		}

		if d.readPos > d.writePos {
			d.logf(ERROR,
				"DISKQUEUE(%s) readPos > writePos (%d > %d), corruption, "  \
                   "skipping to next writeFileNum and resetting 0...",
				d.name, d.readPos, d.writePos)
		}

		d.skipToNextRWFile()
		d.needSync = true
	}
} // diskQueue.go
```

当程序发现在`depth == 0`的情况下，即此时所有的消息已经被读取完毕，但若某个异常的情况下，可能会有：`readFileNum != writeFileNum || readPos != writePos`，则`diskQueue`会显式地删除掉接下来需要被读或写的所有文件，类似于重置持久化存储的状态或格式化操作。同时，`skipToNextRWFile`也可用作清空 `diskQueue`当前未读取的所有文件。具体代码如下：

```go
// 将 readFileNum 到 writeFileNum 之间的文件全部删除
// 将 readFileNum 设置为 writeFileNum
// 即将前面不正确的文件全部删除掉，重新开始读取
// 另外，其也可用作清空 diskQueue 当前未读取的所有文件的操作，重置 depth
func (d *diskQueue) skipToNextRWFile() error {
	var err error
	if d.readFile != nil {
		d.readFile.Close()
		d.readFile = nil
	}
	if d.writeFile != nil {
		d.writeFile.Close()
		d.writeFile = nil
	}
	for i := d.readFileNum; i <= d.writeFileNum; i++ {
		fn := d.fileName(i)
		innerErr := os.Remove(fn)
		// ...
	}
	d.writeFileNum++
	d.writePos = 0
	d.readFileNum = d.writeFileNum
	d.readPos = 0
	d.nextReadFileNum = d.writeFileNum
	d.nextReadPos = 0
	atomic.StoreInt64(&d.depth, 0)
	return err
} // diskQueue.go
```

至此，从`diskQueue`的文件系统中读取消息，并发送到上层应用程序的相关逻辑已经阐述完毕。除了需要清楚其读取核心逻辑外，还需要关注其对文件损坏的检测与处理。

### diskQueue 写入消息

当`topic`或`channel`所维护的内存消息队列`memoryMsgChan`满了时，会通过调用`backend.Put`方法将消息写入到`diskQueue`。消息写入持久化存储的逻辑比从文件系统中读取一条消息的逻辑要简单。其关键步骤为先定位写入索引，同样是先写临时文件缓冲再执行数据刷新操作，最后需要更新`writePos`，当发现要切换写入文件时，还要更新`writeFileNum`。相关代码如下：

```go
func (d *diskQueue) ioLoop() {
	for {
		// 1-5.
        // ...
		// 6. 收到写入消息到磁盘的消息 (当应用程序调用 diskQueue.Put 方法时触发)
		case dataWrite := <-d.writeChan:
			// 删除目前还未读取的文件，同时删除元数据文件
			d.emptyResponseChan <- d.deleteAllFiles()
			count = 0 // 重置当前等待刷盘的消息数量
		// ...
		}
	}
// ...
} // diskQueue.go
```

```go
// 将一个字节数组内容写入到持久化存储，同时更新读写位置信息，以及判断是否需要滚动文件
func (d *diskQueue) writeOne(data []byte) error {
	var err error
	// 1. 若当前写入文件句柄为空，则需要先实例化
	if d.writeFile == nil {
		curFileName := d.fileName(d.writeFileNum)
		d.writeFile, err = os.OpenFile(curFileName, os.O_RDWR|os.O_CREATE, 0600)
		// ...
		d.logf(INFO, "DISKQUEUE(%s): writeOne() opened %s", d.name, curFileName)
		// 2. 同时，若当前的写入索引大于0,则重新定位写入索引
		if d.writePos > 0 {
			_, err = d.writeFile.Seek(d.writePos, 0)
			// ...
		}
	}
	// 3. 获取写入数据长度，并检查长度合法性。然后将数据写入到写入缓冲，
    // 最后将写入缓冲的数据一次性刷新到文件
	dataLen := int32(len(data))
	if dataLen < d.minMsgSize || dataLen > d.maxMsgSize {
		return fmt.Errorf("invalid message write size (%d) maxMsgSize=%d", 
                          dataLen, d.maxMsgSize)
	}
	d.writeBuf.Reset()
	err = binary.Write(&d.writeBuf, binary.BigEndian, dataLen)
	// ...
	_, err = d.writeBuf.Write(data)
	// ...
	// only write to the file once
	_, err = d.writeFile.Write(d.writeBuf.Bytes())
	// ...
	// 更新写入索引 writePos 及 depth，且若 writePos 大于 maxBytesPerFile，
    // 则说明当前已经写入到文件的末尾。
	// 因此需要更新 writeFileNum，重置 writePos，
    // 即更换到一个新的文件执行写入操作（为了避免一直写入单个文件）
	// 且每一次更换到下一个文件，都需要将写入文件同步到磁盘
	totalBytes := int64(4 + dataLen)
	d.writePos += totalBytes
	atomic.AddInt64(&d.depth, 1)
	if d.writePos > d.maxBytesPerFile {
		d.writeFileNum++
		d.writePos = 0
		// sync every time we start writing to a new file
		err = d.sync()
		// ..
	}

	return err
} // diskQueue.go
```

### diskQueue 清空消息

当应用程序调用`diskQueue.Empty`接口时，会将持久化存储`diskQueue`中的所有消息清空，并重置了所有状态属性信息，类似于一个格式化操作。还记得上面在阐述读取消息的流程中涉及到的`diskQueue.skipToNextRWFile`方法吗，它的一个作用就是删除`diskQueue`当前未读取的所有文件。除此之外，清空消息操作还删除了元数据文件。相关代码如下：

```go
// 清空 diskQueue 中未读取的文件
func (d *diskQueue) Empty() error {
	d.RLock()
	defer d.RUnlock()
	if d.exitFlag == 1 {
		return errors.New("exiting")
	}
	d.logf(INFO, "DISKQUEUE(%s): emptying", d.name)
	d.emptyChan <- 1
	return <-d.emptyResponseChan
} // diskQueue.go

// diskQueue 消息处理主循环
func (d *diskQueue) ioLoop() {
	for {
		// 1-3.
        // ...
		select {
		// 4.
        // ...    
		// 5. 收到清空持久化存储 disQueue 的消息
		case <-d.emptyChan: // (当应用程序调用 diskQueue.Empty 方法时触发)
			// 删除目前还未读取的文件，同时删除元数据文件
			d.emptyResponseChan <- d.deleteAllFiles()
			count = 0 // 重置当前等待刷盘的消息数量
		// 6-8
        // ...    
		}
	}
// ...
} // diskQueue.go

// 调用 skipToNextRWFile 方法清空 readFileNum -> writeFileNum 之间的文件，
// 并且设置 depth 为 0。 同时删除元数据文件
func (d *diskQueue) deleteAllFiles() error {
	err := d.skipToNextRWFile()
	innerErr := os.Remove(d.metaDataFileName())
	// ...
	return err
} // diskQueue.go
```

### diskQueue 刷盘操作

同大多的存储系统类似，`diskQueue`采用批量刷新缓冲区的操作来提高消息写入文件系统的性能。其中，`diskQueue`规定触发刷盘动作的有个条件，其中任一条件成立即可。一是当缓冲区中的消息的数量达到阈值(`syncEvery`)时，二是每隔指定时间(`syncTimeout`)。需要注意的一点为在执行刷盘动作，也会重新持久化`diskQueue`的元数据信息。相关代码如下：

```go
func (d *diskQueue) ioLoop() {
	syncTicker := time.NewTicker(d.syncTimeout)
	for {
		// dont sync all the time :)
		// 1. 只有写入缓冲中的消息达到一定数量，才执行同步刷新到磁盘的操作
		if count == d.syncEvery {
			d.needSync = true
		}
		// 2. 刷新磁盘操作，重置计数信息，即将 writeFile 流刷新到磁盘，同时持久化元数据
		if d.needSync {
			err = d.sync()
			// ...
			count = 0 // 重置当前等待刷盘的消息数量
		}
		// 3.
        // ...
		select {
		// 4-6
        // ...    
		// 7. 定时执行刷盘操作，在存在数据等待刷盘时，才需要执行刷盘动作
		case <-syncTicker.C:
			if count == 0 {
				// avoid sync when there's no activity
				continue
			}
			d.needSync = true
		// 8.
        // ...    
	}
// ...
} // diskQueue.go
    
// 同步刷新 writeFile 文件流（即将操作系统缓冲区中的数据写入到磁盘），同时持久化元数据信息
func (d *diskQueue) sync() error {
	if d.writeFile != nil {
		err := d.writeFile.Sync()
		// ...
	}
	err := d.persistMetaData()
	// ...
	// 重置了刷新开关
	d.needSync = false
	return nil
}    
```

简单小结，本文详细分析了持久化消息队列存储组件——`diskQueue`，它被用作`nsq`的消息持久化存储。围绕`diskQueue`展开，通过阐述其提供给上层应用程序的功能接口来分析其工作原理，重点梳理了从`diskQueue`中读取和写消息的逻辑，同一般的队列实现类似，采用一组索引标记读写的位置，只不过`diskQueue`采用了两组读取索引。另外，在读取消息的过程检测文件是否被损坏，同时在写入过程中，通过不断切换文件来限制写入单个文件的数据量。`diskQueue`同样提供了清空存储的所有消息（删除所有文件，并重置`diskQueue`状态信息）的操作（类似于文件系统的格式化操作），最后不要忘记缓冲区的批量刷新刷盘动作助于提高文件系统的写入性能。更完整的源码注释可参考[这里](https://github.com/qqzeng/nsqio/tree/master/go-diskqueue)。





参考文献

[1].https://github.com/nsqio/go-diskqueue
