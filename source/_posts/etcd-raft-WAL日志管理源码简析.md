---
title: etcd-raft WAL日志管理源码简析
date: 2019-01-11 10:58:11
categories:
- 分布式系统
- 分布式协调服务
tags:
- 分布式系统
- WAL 日志
---

上一篇文章简单分析了`etcd-raft` 网络传输组件相关的源码。本文会简要分析`etcd-raft WAL`日志管理部分的源码。`WAL`(`Write-Ahead Logging`)即为预写式日志，即在真正执行写操作之前先写日志，这在数据库系统和分布式系统领域很常见。它是为了保证数据的可靠写。日志对于利用一致性协议构建高可用的分布式系统而言至关重要，在`etcd raft`中，日志也会在各节点之间同步。并且`etcd`提供了一个`WAL`的日志库，它暴露日志管理相关的接口以方便应用程序具体操作日志的逻辑。本文从应用调用 `WAL`库执行日志追加逻辑切入，重点分析`etcd`提供的`WAL`日志库的相关接口实现逻辑细则，包括`WAL`日志的设计、日志创建追加等。

<!--More-->

## 数据结构

同之前的文章类似，希望读者能够主动查看源码（主要涉及目录`/etcd/wal`），文章作为参考。按惯例，先来观察与`WAL`相关的重要数据结构的设计。从最核心的数据结构切入`WAL`：

```go
// WAL 是持久化存在的逻辑表示。并且要么处于读模式要么处于追加模式。
// 新创建的 WAL 处于追加模式，可用于记录追加。
// 刚打开的 WAL 处于读模式，可用于记录读取。
// 当读完之前所有的 WAL 记录后，WAL 才可用于记录追加。
type WAL struct {
	lg *zap.Logger

	// 日志存储目录
	dir string // the living directory of the underlay files

	// dirFile is a fd for the wal directory for syncing on Rename
	// 文件描述符，用于 WAL 目录同步重命名操作
	dirFile *os.File

	// 元数据，在创建日志文件时，在写在文件头位置
	metadata []byte           // metadata recorded at the head of each WAL
	state    raftpb.HardState // hardstate recorded at the head of WAL

	start     walpb.Snapshot // snapshot to start reading
	decoder   *decoder       // decoder to decode records
	readClose func() error   // closer for decode reader

	mu      sync.Mutex
    // WAL 中保存的最后一条日志的索引
	enti    uint64   // index of the last entry saved to the wal
	encoder *encoder // encoder to encode records

	// LockedFile 封装了 os.File 的结构，具备文件锁定功能
	locks []*fileutil.LockedFile // the locked files the WAL holds (the name is increasing)
	fp    *filePipeline
} // wal.go
```

简单的字段在代码中作了注释。下面了解下几个重点的结构：

- `state`: `HardState{Term,Vote,Commit}`类型，它表示节点在回复消息时，必须先进行持久化保持的状态。
- `start`: `walpb.Snapshot{Index, Term}`类型，即表示`WAL`日志中的快照，当读`WAL`日志时需从此索引后一个开始，如应用在重放日志逻辑中，需要打开`WAL`日志，则其只需要对`Snapshot`索引后的日志作重放。
- `decoder`: `decoder`封装了`Reader`，并且使用`crc`来校验读取的记录，一个文件对应一个`decoder`。
- `encoder`: `encoder`封装了`PageWriter`，同样使用`crc`来检验写入记录，`encoder`实例同样对应一个文件。

- `fp`: `filePipeline `类型，它管理文件创建时的磁盘空间分配操作逻辑。若文件以写模式打开，它会开启一个单独的`go routine`为文件创建预分配空间，以提高文件创建的效率。此逻辑封装在`file_pipeline.go`。

我们不妨简单看看`encoder`的结构（比`decoder`结构稍复杂），它包含了一个执行具体写操作的`PageWriter`，以及一个`crc`字段，另外，还包含两个预分配的缓冲区，其中`buf`(1MB)用于写入实际数据，而`uint64buf`(8B)用于写入长度相关字段。其代码如下：

```go
type encoder struct {
	mu sync.Mutex
	bw *ioutil.PageWriter

	crc       hash.Hash32
	buf       []byte // 用于写入实际记录数据
	uint64buf []byte // 用于写入长度相关字段
} // encoder.go

func newEncoder(w io.Writer, prevCrc uint32, pageOffset int) *encoder {
	return &encoder{
		bw:  ioutil.NewPageWriter(w, walPageBytes, pageOffset),
		crc: crc.New(prevCrc, crcTable),
		// 1MB buffer
		buf:       make([]byte, 1024*1024),
		uint64buf: make([]byte, 8),
	}
} // encoder.go
```

另外，存储在`WAL`日志的记录包括两种，一种以`Record`形式保存，它是一种普通的记录格式，另一种以`Snapshot`形式保存，它专门用于快照记录的存储，但快照类型的记录最终还是作为`Record`类型记录存储：

```go
type Record struct {
	Type             int64  `protobuf:"varint,1,opt,name=type" json:"type"`
	Crc              uint32 `protobuf:"varint,2,opt,name=crc" json:"crc"`
	Data             []byte `protobuf:"bytes,3,opt,name=data" json:"data,omitempty"`
	XXX_unrecognized []byte `json:"-"`
} // record.pb.go

type Snapshot struct {
	Index            uint64 `protobuf:"varint,1,opt,name=index" json:"index"`
	Term             uint64 `protobuf:"varint,2,opt,name=term" json:"term"`
	XXX_unrecognized []byte `json:"-"`
} // record.pb.go
```

对于普通记录`Record`类型结构（即`WAL`日志类型），它的`Type`字段表示日志类型，包括如下几种日志类型：

```go
const (
    // 元数据类型日志项，被写在每个日志文件的头部，具体内容可以任意，包括空值
	metadataType int64 = iota + 1
    // 实际的数据，即日志存储中的关键数据
	entryType
    // 表示保存的为 HardState 类型的数据
	stateType
    // 前一个 WAL 日志记录数据的 crc 值
	crcType
    // 表示快照类型的日志记录，它表示当前 Snapshot 位于哪个日志记录，保存的是索引(Term,Index)数据
	snapshotType

	// warnSyncDuration is the amount of time allotted to an fsync before
	// logging a warning
	warnSyncDuration = time.Second
) // wal.go
```

而它的`crc`字段表示校验和数据，需要注意的是它并非直接保存的是当前日志记录的校验数据，而保存的是当前文件该日志项之前的所有日志项的校验和，这似乎是采用类似一种`rolling crc`，以保证`WAL`日志的连续性，因为写日志的时候可能会涉及到`cut`操作，它会将日志内容存储到不止一个文件。`data`字段会根据不同的类型来具体确定，若为`stateType`，则存储`HardState`类型的数据，若为`entryType`，则存储`Entry`类型的数据，若为`snapshotType`，则存储`Snapshot`类型的数据（只是索引数据），若为`metadataType`，则似乎可以由应用决定（目前来看在`raftNode`结构中，使用了此类型的日志，但传过来的数据为空），若为`crcType`，则存储`Crc`类型(`unit32`)的数据。

最后的`padding`字段，则是为了保持日志项数据 8 字节对其的策略，而进行填充的内容。这个我们可以从任一一处编码`Record`记录的代码中观察得知，如从`wal.go`中`w.encoder.encode(...)`代码往下追溯具体的`encode()`的逻辑，在`encode()`函数中会调用`encodeFrameSize(len(data))`，其函数具体的代码如下：

```go
func encodeFrameSize(dataBytes int) (lenField uint64, padBytes int) {
	lenField = uint64(dataBytes)
	// force 8 byte alignment so length never gets a torn write
	padBytes = (8 - (dataBytes % 8)) % 8 // 先得出 padding 的 bytes 的大小，一定小于 8
	if padBytes != 0 {
		lenField |= uint64(0x80|padBytes) << 56 
        // 将 0x80 与 padBytes 进行或操作，得到 4 个二进制位的内容，然后再左移 56 位。最后得到的记录的存储二进制结构为：
        // {|-(1位标记位)| |---(3位表示 Padding bytes Size)|}{...(56位于表示实际的 Record bytes Size)}
	}
	return lenField, padBytes
} // encoder.go
```

至此相关的重要的数据结构项已经查看完毕，主要是围绕`WAL`结构展开。文章为了节约篇幅并没有将所有的数据项结构的代码帖出，读者可以自己深入源码查看，较为简单。

## 关键流程

在此部分分析中，简要分析阐述`WAL`库提供的各个接口实现的逻辑，主要包括`WAL`创建、`WAL`初始化（打开）、`WAL`日志项读取及`WAL`追加日志项等流程。另外，关于`raft`协议核心库如何操作日志的逻辑暂不涉及。

###  WAL 创建

在`raftexample`示例代码中，应用在启动时，对`WAL`日志执行重放操作（`raft.go`，在`startRaft()`中的`rc.replayWAL()`），而在重放日志函数的逻辑中，它先加载`snapshot`数据，然后，将其作为参数传递给`rc.openWAL(snapshot)`函数，以对打开文件，如果文件不存在，则会先创建日志文件。关键代码如下所示：

```go
// replayWAL replays WAL entries into the raft instance.
func (rc *raftNode) replayWAL() *wal.WAL {
	log.Printf("replaying WAL of member %d", rc.id)
	snapshot := rc.loadSnapshot() // 加载 snapshot 数据
	w := rc.openWAL(snapshot) // 打开 WAL 日志文件，以读取 snaptshot 位置后的日志
	_, st, ents, err := w.ReadAll() // 读取 WAL 日志文件，相关逻辑后面详述
	// ...
	return w
} // raft.go

// openWAL returns a WAL ready for reading.
func (rc *raftNode) openWAL(snapshot *raftpb.Snapshot) *wal.WAL {
	if !wal.Exist(rc.waldir) {
		if err := os.Mkdir(rc.waldir, 0750); err != nil {
			log.Fatalf("raftexample: cannot create dir for wal (%v)", err)
		}
        // 1. 创建日志文件，注意在这里 metaData 参数为 nil
		w, err := wal.Create(zap.NewExample(), rc.waldir, nil)
		w.Close()
	}
    // 2. 创建 snapshotType 类型的日志项，以用于记录当前快照的索引情况(Term, Index)
	walsnap := walpb.Snapshot{}
	if snapshot != nil {
		walsnap.Index, walsnap.Term = snapshot.Metadata.Index, snapshot.Metadata.Term
	}
	log.Printf("loading WAL at term %d and index %d", walsnap.Term, walsnap.Index)
    // 3. 打开从 snapshot 位置打开日志，其相关的逻辑在后面详述
	w, err := wal.Open(zap.NewExample(), rc.waldir, walsnap) 
	if err != nil {
		log.Fatalf("raftexample: error loading wal (%v)", err)
	}
	return w
} // raft.go
```

阐明了应用`WAL`日志库的入口后，我们先来查看`WAL`创建函数相关的逻辑。

```go
// Create creates a WAL ready for appending records. The given metadata is
// recorded at the head of each WAL file, and can be retrieved with ReadAll.
// 创建一个 WAL 文件用于日志记录追加。元数据存放在文件头部，可以通过 ReadAll 检索到
func Create(lg *zap.Logger, dirpath string, metadata []byte) (*WAL, error) {
	if Exist(dirpath) {
		return nil, os.ErrExist
	}

	// keep temporary wal directory so WAL initialization appears atomic
	// 1. 先创建一个临时文件，然后对此文件进行重命名，以使得文件被原子创建
	tmpdirpath := filepath.Clean(dirpath) + ".tmp"
	if fileutil.Exist(tmpdirpath) {
		if err := os.RemoveAll(tmpdirpath); err != nil {
			return nil, err
		}
	}
	if err := fileutil.CreateDirAll(tmpdirpath); err != nil {
		return nil, err
	}
	// 2. 构造文件名，即构建 dir/filename, 其中 filename 伤脑筋 walName函数来获取，文件名构建规则为：seq-index.wal
	p := filepath.Join(tmpdirpath, walName(0, 0))
	// 3. WAL 对文件的操作都是通过 LockFile 来执行的
	f, err := fileutil.LockFile(p, os.O_WRONLY|os.O_CREATE, fileutil.PrivateFileMode)
	if err != nil {
		return nil, err
	}
	// 4. 定位到文件末尾
	if _, err = f.Seek(0, io.SeekEnd); err != nil {
		return nil, err
	}
	// 5. 预分配文件，默认 SegmentSizeBytes 大小为 64MB
	if err = fileutil.Preallocate(f.File, SegmentSizeBytes, true); err != nil {
		return nil, err
	}
	// 6. 初始化 WAL 数据结构
	w := &WAL{
		lg:       lg,
		dir:      dirpath,
		metadata: metadata,
	}
	// 7. 针对此文件构建 WAL 结构的 encoder 字段，并且将 preCrc 字段赋值为0
	w.encoder, err = newFileEncoder(f.File, 0)
	// 8. 将此（具备锁定性质的）文件添加到 WAL 结构的 locks 数组字段
	w.locks = append(w.locks, f)
	// 9. 保存类型为 crcType 的 crc 记录项，具体的 crc 数据为 preCrc=0
	if err = w.saveCrc(0); err != nil {
		return nil, err
	}
	// 10. 利用 encoder 编码类型为 metadataType 的 metaData 记录项
	if err = w.encoder.encode(&walpb.Record{Type: metadataType, Data: metadata}); err != nil {
		return nil, err
	}
	// 11. 保存类型为 snapshotType 的空的 Snapshot 记录
	if err = w.SaveSnapshot(walpb.Snapshot{}); err != nil {
		return nil, err
	}
	// 12. 重命名操作，之前以.tmp结尾的文件，初始化完成之后进行重命名，类似原子操作
	if w, err = w.renameWAL(tmpdirpath); err != nil {
		return nil, err
	}

	// directory was renamed; sync parent dir to persist rename
	pdir, perr := fileutil.OpenDir(filepath.Dir(w.dir))
	// 13. 将上述涉及到对文件的操作进行同步处理
	if perr = fileutil.Fsync(pdir); perr != nil {
		return nil, perr
	}
	if perr = pdir.Close(); err != nil {
		return nil, perr
	}
	return w, nil
} // wal.go
```

上述代码片段中的注释对整个创建过程进行了详细阐述，这是总结一下，它主要涉及到几个操作：

- 创建`WAL`目录，用于存储`WAL`日志文件及索引，同时使用临时文件及重命名的方式来原子操作。
- 对日志文件的创建，会预分配空间，以提高创建的效率。
- 在日志文件创建时，会初始化 `WAL`结构实例，同时写入`crcType`、`metadataType`记录项，并且保存一个空的`snapshotType`记录项。对于各种类型记录项，上文中数据结构小节已经详细阐述。

我们来看下它是如何保存`snapshotType`类型的`Snapshot`数据的，相关逻辑在函数`SaveSnapShot(Snapshot)`:

```go
// 持久化 walpb.Snapshot 数据
func (w *WAL) SaveSnapshot(e walpb.Snapshot) error {
	b := pbutil.MustMarshal(&e) // 1. 先执行序列化操作
	w.mu.Lock()
	defer w.mu.Unlock()
	// 2. 构建 snaptshotType 类型的记录结构，并以序列化的数据作为参数
	rec := &walpb.Record{Type: snapshotType, Data: b}
	// 3. 利用 encoder 编码写入
	if err := w.encoder.encode(rec); err != nil {
		return err
	}
	// update enti only when snapshot is ahead of last index
	// 4. w.enti 表示的是 WAL 中最后一条日志的索引，因此只有当其小于快照的索引时，才进行替换
	if w.enti < e.Index {
		w.enti = e.Index
	}
	return w.sync()
} // wal.go
```

我们不妨深入`encoder.encode()`函数中查看一下编码的细节：

```go
// 编码一条数据记录项
func (e *encoder) encode(rec *walpb.Record) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	// 1. 生成校验和数据
	e.crc.Write(rec.Data)
	rec.Crc = e.crc.Sum32()
	var (
		data []byte
		err  error
		n    int
	)
	// 2. 如果记录的大小超过预分配的 1MB 的 buffer（与文件的预分配可能类似），则重新分配空间
	if rec.Size() > len(e.buf) {
		data, err = rec.Marshal()
		if err != nil {
			return err
		}
	} else { // 否则直接使用预分配的空间
		n, err = rec.MarshalTo(e.buf)
		if err != nil {
			return err
		}
		data = e.buf[:n]
	}
	// 3. 调用 encodeFrameSize 函数来构建 lenField 以及判断对齐的位数
	lenField, padBytes := encodeFrameSize(len(data))
	// 4. 先写记录编码后的长度字段
	if err = writeUint64(e.bw, lenField, e.uint64buf); err != nil {
		return err
	}
	// 5. 然后，若需要对齐，则追加对齐填充数据
	if padBytes != 0 {
		data = append(data, make([]byte, padBytes)...)
	}
	// 6. 最后正式写入记录的所包含的所有数据内容
	_, err = e.bw.Write(data)
	return err
} // encoder.go
```

关于`WAL`文件创建相关逻辑已经阐述完毕，下一小节阐述与创建类似的操作即初始化操作。

### WAL 初始化



`WAL`初始化，我将表示它表示为打开文件逻辑，即在应用程序里面中的代码`wal.Open()`函数中的流程。具体而言，打开`WAL`文件的目的是为了从里面读取日志文件（读取的目的一般是重放日志）。因此，更准确而言，是从指定索引处打开，此索引即表示之前的已经执行的快照的索引，从那之后开始进行读操作，而且只有当把快照索引之后的日志全部读取完毕才能进行追加操作。另外，打开操作必须保证快照之前已经被存储，否则读取操作`ReadlAll`会执行失败。打开操作的相关的代码如下：

```go
func Open(lg *zap.Logger, dirpath string, snap walpb.Snapshot) (*WAL, error) {
	// 只打开最后一个 seq 小于 snap 中的 index 之后的所有 wal 文件，并且以写的方式打开
	w, err := openAtIndex(lg, dirpath, snap, true)
	if w.dirFile, err = fileutil.OpenDir(w.dir); err != nil {
		return nil, err
	}
	return w, nil
} // wal.go

// 打开指定索引后的日志文件
func openAtIndex(lg *zap.Logger, dirpath string, snap walpb.Snapshot, write bool) (*WAL, error) {
	// 1. 读取所有 WAL 日志文件名称
	names, err := readWALNames(lg, dirpath)
	if err != nil {
		return nil, err
	}
	// 2. 返回名称集合中最后一个小于或者等于 snap.Index 的名称索引（在文件名称集合中的索引）
	nameIndex, ok := searchIndex(lg, names, snap.Index)
	// 3. 检查 nameIndex 之后的文件名的 seq 是否有序递增的
	if !ok || !isValidSeq(lg, names[nameIndex:]) {
		return nil, ErrFileNotFound
	}

	// open the wal files
	rcs := make([]io.ReadCloser, 0)
	rs := make([]io.Reader, 0)
	ls := make([]*fileutil.LockedFile, 0)
	// 3. 对返回的索引之后的文件进行遍历，同时构造 rcs、rs、ls 数组
	for _, name := range names[nameIndex:] {
		// 4. 构建文件路径
		p := filepath.Join(dirpath, name)
		// 5. 如果是写模式打开，则进行如下操作
		if write {
			l, err := fileutil.TryLockFile(p, os.O_RDWR, fileutil.PrivateFileMode)
			if err != nil {
				closeAll(rcs...)
				return nil, err
			}
			ls = append(ls, l) // 写模式似乎有锁定文件属性
			rcs = append(rcs, l) // 追加文件读取与关闭接口
		} else { // 6. 如果是读模式打开，则进行如下操作
			rf, err := os.OpenFile(p, os.O_RDONLY, fileutil.PrivateFileMode)
			if err != nil {
				closeAll(rcs...)
				return nil, err
			}
			ls = append(ls, nil) // 读模式并没有锁定文件属性
			rcs = append(rcs, rf) // 同样追加文件读取与关闭接口
		}
		rs = append(rs, rcs[len(rcs)-1])
	}

	// 7. 构建用于文件读取与关闭的句柄集合
	closer := func() error { return closeAll(rcs...) }

	// create a WAL ready for reading
	// 8. 利用以上信息构造 WAL 实例
	w := &WAL{
		lg:        lg,
		dir:       dirpath,
		start:     snap, // 初始化快照数据，实际上表示可以从哪一个索引位置处开始读
		decoder:   newDecoder(rs...), // decoder 又以上述打开文件的句柄集合为参数
		readClose: closer, // 文件关闭句柄集合
		locks:     ls, // 具备锁定属性的文件集合
	}

	// 9. 若为写打开，则会重用读的文件描述符，因此不需要关闭 WAL 文件（需要释放锁）以直接执行追加操作
	if write {
		// write reuses the file descriptors from read; don't close so
		// WAL can append without dropping the file lock
		w.readClose = nil
		if _, _, err := parseWALName(filepath.Base(w.tail().Name())); err != nil {
			closer()
			return nil, err
		}
		// 10. 创建 FilePipeline 进行创建文件操作的空间预分配操作，具体是在 go routine 中循环执行空间分配操作，
		// 并将分配好的文件放到通道中，等待后面正式创建的时候使用
		w.fp = newFilePipeline(w.lg, w.dir, SegmentSizeBytes)
	}

	return w, nil
} // wal.go
```

`WAL`文件打开以进行后续的读取与追加操作的相关逻辑已经阐述完毕。下面阐述日志项的读取相关逻辑。

### WAL 日志项读取

同样，在应用`raftexample`中启动初始化应用时(`startRaft()`)中可能会涉及到日志的读取操作(`w.ReadAll()`)。因此，我们来详细了解读取逻辑。大概地，它会读取`WAL`所有日志记录，当读取完毕后，就可以执行操作：

```go
// ReadAll reads out records of the current WAL.
// If opened in write mode, it must read out all records until EOF. Or an error
// will be returned.
// If opened in read mode, it will try to read all records if possible.
// If it cannot read out the expected snap, it will return ErrSnapshotNotFound.
// If loaded snap doesn't match with the expected one, it will return
// all the records and error ErrSnapshotMismatch.
// TODO: detect not-last-snap error.
// TODO: maybe loose the checking of match.
// After ReadAll, the WAL will be ready for appending new records.
func (w *WAL) ReadAll() (metadata []byte, state raftpb.HardState, ents []raftpb.Entry, err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	// 1. 初始化一个空的记录项
	rec := &walpb.Record{}
	decoder := w.decoder

	// 2. 根据记录不同的类型（在数据结构部分已经详述），来执行不同操作
	var match bool
	for err = decoder.decode(rec); err == nil; err = decoder.decode(rec) {
		switch rec.Type {
		// 2.1. 如果为 entryType 类型
		case entryType:
			e := mustUnmarshalEntry(rec.Data)
			// 若读取到的日志的日志项的索引大于快照的索引，则将其追加到日志面集合，
			// 并且更新 WAL 的最后一条日志的日志索引
			if e.Index > w.start.Index {
				ents = append(ents[:e.Index-w.start.Index-1], e)
			}
			w.enti = e.Index
		// 2.2. 如果为 stateType 类型
		case stateType:
			state = mustUnmarshalState(rec.Data)
		// 2.3 如果为 metadataType 类型，从此处来看 metadata 还可以用作检验
		case metadataType:
			if metadata != nil && !bytes.Equal(metadata, rec.Data) {
				state.Reset()
				return nil, state, nil, ErrMetadataConflict
			}
			metadata = rec.Data
		// 2.4 如果为 crcType 类型，则需要校验此 decoder 保存的 crc 检验和是否与记录的一致
		case crcType:
			crc := decoder.crc.Sum32()
			// current crc of decoder must match the crc of the record.
			// do no need to match 0 crc, since the decoder is a new one at this case.
			if crc != 0 && rec.Validate(crc) != nil {
				state.Reset()
				return nil, state, nil, ErrCRCMismatch
			}
			decoder.updateCRC(rec.Crc)
		// 2.5 如果为 snapshotType 类型
		case snapshotType:
			var snap walpb.Snapshot
			pbutil.MustUnmarshal(&snap, rec.Data)
			// 在反序列化之后，如果记录中的快照与 WAL 日志中快照不匹配，则报错
			if snap.Index == w.start.Index {
				if snap.Term != w.start.Term {
					state.Reset()
					return nil, state, nil, ErrSnapshotMismatch
				}
				match = true
			}

		default:
			state.Reset()
			return nil, state, nil, fmt.Errorf("unexpected block type %d", rec.Type)
		}
	}

	// 3. 通过 WAL 日志文件中最后一条记录来做不同的处理
	switch w.tail() {
	case nil: // 如果是读模式，则并不需要读取所有的记录，因为最后一条记录可能是部分写的
		// We do not have to read out all entries in read mode.
		// The last record maybe a partial written one, so
		// ErrunexpectedEOF might be returned.
		if err != io.EOF && err != io.ErrUnexpectedEOF {
			state.Reset()
			return nil, state, nil, err
		}
	default: // 如果是写模式，则需要读取所有记录，直至返回 EOF
		// We must read all of the entries if WAL is opened in write mode.
		if err != io.EOF {
			state.Reset()
			return nil, state, nil, err
		}
		// decodeRecord() will return io.EOF if it detects a zero record,
		// but this zero record may be followed by non-zero records from
		// a torn write. Overwriting some of these non-zero records, but
		// not all, will cause CRC errors on WAL open. Since the records
		// were never fully synced to disk in the first place, it's safe
		// to zero them out to avoid any CRC errors from new writes.
		if _, err = w.tail().Seek(w.decoder.lastOffset(), io.SeekStart); err != nil {
			return nil, state, nil, err
		}
		if err = fileutil.ZeroToEnd(w.tail().File); err != nil {
			return nil, state, nil, err
		}
	}

	err = nil
	if !match {
		err = ErrSnapshotNotFound
	}

	// 4. 读取完毕后，则关闭读操作
	// close decoder, disable reading
	if w.readClose != nil {
		w.readClose()
		w.readClose = nil
	}
	w.start = walpb.Snapshot{}

	w.metadata = metadata

	// 5. 如果最后一条记录不为空，则创建 encoder，准备追加操作
	if w.tail() != nil {
		// create encoder (chain crc with the decoder), enable appending
		w.encoder, err = newFileEncoder(w.tail().File, w.decoder.lastCRC())
		if err != nil {
			return
		}
	}
	w.decoder = nil

	return metadata, state, ents, err
} // wal.go
```

另外，关于记录的`decode`操作，下面帖出简要的注释过程，基本上是`encode`操作的逆操作，但是加了一个校验的过程。

```go
// decode 日志记录项
func (d *decoder) decode(rec *walpb.Record) error {
	rec.Reset()
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.decodeRecord(rec)
}

func (d *decoder) decodeRecord(rec *walpb.Record) error {
	// 1. 需要读取器
	if len(d.brs) == 0 {
		return io.EOF
	}
	// 2. 首先读与长度相关字段
	l, err := readInt64(d.brs[0])
	// 3. 解析出记录数据的字节大小以及对齐字节的大小
	recBytes, padBytes := decodeFrameSize(l)

	// 4. 构建缓冲区用于存储具体读出的数据
	data := make([]byte, recBytes+padBytes)
	// 5. 执行读实际数据的操作
	if _, err = io.ReadFull(d.brs[0], data); err != nil {
		return err
	}
	// 6. 对数据执行反序列化操作
	if err := rec.Unmarshal(data[:recBytes]); err != nil {
		return err
	}

	// 7. 对非 crcType 类型的记录，需要校验 crc，即检测记录的 crc 数值与 decoder 的检验和是否一致
	// skip crc checking if the record type is crcType
	if rec.Type != crcType {
		d.crc.Write(rec.Data)
		if err := rec.Validate(d.crc.Sum32()); err != nil {
			if d.isTornEntry(data) {
				return io.ErrUnexpectedEOF
			}
			return err
		}
	}
	// 8. 更新目前已经检验的字节索引，下一次从此处开始检验
	// record decoded as valid; point last valid offset to end of record
	d.lastValidOff += frameSizeBytes + recBytes + padBytes
	return nil
}

// 为 encoder.encodeFrameSize() 函数的逆过程
func decodeFrameSize(lenField int64) (recBytes int64, padBytes int64) {
	// the record size is stored in the lower 56 bits of the 64-bit length
	recBytes = int64(uint64(lenField) & ^(uint64(0xff) << 56))
	// non-zero padding is indicated by set MSb / a negative length
	if lenField < 0 {
		// padding is stored in lower 3 bits of length MSB
		padBytes = int64((uint64(lenField) >> 56) & 0x7)
	}
	return recBytes, padBytes
} // decoder.go
```

最后一个部分来简要阐述日志项的追加逻辑。

### WAL 日志项追加

同样，在【[etcd raftexample 源码简析](https://qqzeng.top/2019/01/09/etcd-raftexample-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)】中，当应用收到底层`raft`协议的指令消息时，会先进行写日志(`rc.wal.Save(rd.HardState, rd.Entries)`)，也即此处的日志项追加操作。

```go
// 日志项追加操作
func (w *WAL) Save(st raftpb.HardState, ents []raftpb.Entry) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	// short cut, do not call sync
	// 1. 若无 需要持久化的字段 且无日志项数据，则返回
	if raft.IsEmptyHardState(st) && len(ents) == 0 {
		return nil
	}
	// 2. MustSync 会检查当前的 Save 操作是否需要同步存盘
	// 事实上，其逻辑大致为检查 log entries 是否为0，或者 candidate id 是否变化或者是 term 有变化，
	// 一旦这些条件中之一满足，则需要先执行存盘操作。
	// 这些字段为 raft 实例需要持久化的字段，以便重启的时候可以继续协议
	mustSync := raft.MustSync(st, w.state, len(ents))

	// TODO(xiangli): no more reference operator
	// 3. 遍历日志项，并保存，在 saveEntry 中，会构建 Entry 记录，并更新 WAL 的 enti 索引字段
	for i := range ents {
		if err := w.saveEntry(&ents[i]); err != nil {
			return err
		}
	}
	// 4. 保存 HardState 字段，并保存，在 saveState 中，会构建 State 记录，但不会更新 enti 索引字段
	if err := w.saveState(&st); err != nil {
		return err
	}
	// 5. 获取最后一个 LockedFile 的大小（已经使用的）
	curOff, err := w.tail().Seek(0, io.SeekCurrent)
	if err != nil {
		return err
	}
	// 6. 若小于预分配空间大小 64MB，则直接返回即可
	if curOff < SegmentSizeBytes {
		if mustSync { // 若需同步刷盘操作，则要将已经 encode 的记录存盘
			return w.sync()
		}
		return nil
	}
	// 6. 若大于预分配空间，则需要另外创建一个文件
	return w.cut()
} // wal.go
```

其中涉及到的几个保存不同类型的记录的函数如下，比较简单：

```go
func MustSync(st, prevst pb.HardState, entsnum int) bool {
	// Persistent state on all servers:
	// (Updated on stable storage before responding to RPCs)
	// currentTerm
	// votedFor
	// log entries[]
	return entsnum != 0 || st.Vote != prevst.Vote || st.Term != prevst.Term
} // node.go 由 raft 协议库核心提供

func (w *WAL) saveEntry(e *raftpb.Entry) error {
	// TODO: add MustMarshalTo to reduce one allocation.
	b := pbutil.MustMarshal(e)
	// 构建 entryType 类型的 Record，并对记录进行编码
	rec := &walpb.Record{Type: entryType, Data: b}
	if err := w.encoder.encode(rec); err != nil {
		return err
	}
	// 更新 WAL 日志项中最后一条日志的索引号
	w.enti = e.Index
	return nil
} // wal.go

func (w *WAL) saveState(s *raftpb.HardState) error {
	if raft.IsEmptyHardState(*s) {
		return nil
	}
	w.state = *s
	b := pbutil.MustMarshal(s)
	rec := &walpb.Record{Type: stateType, Data: b}
	return w.encoder.encode(rec)
} // wal.go
```

最后若当前的文件的预分配的空间不够，则需另外创建新的文件来进行保存日志项。`cut()`函数流程如下，它的流程同`Create()`函数非常类似：

```go
// cut closes current file written and creates a new one ready to append.
// cut first creates a temp wal file and writes necessary headers into it.
// Then cut atomically rename temp wal file to a wal file.
// cut 函数实现了WAL文件切换的功能，即关闭当前WAL日志，创建新的WAL日志，继续用于日志追加。
// 每个 WAL 文件的预分配空间为 64MB，一旦超过该大小，便需要创建新的 WAL 文件
// 同样，cut 操作也会原子性的创建，能够创建临时文件来实现。
func (w *WAL) cut() error {
	// close old wal file; truncate to avoid wasting space if an early cut
	// 1. 关闭当前 WAL 文件，得到文件大小
	off, serr := w.tail().Seek(0, io.SeekCurrent)
	if serr != nil {
		return serr
	}
	// 2. 截断文件
	if err := w.tail().Truncate(off); err != nil {
		return err
	}
	if err := w.sync(); err != nil {
		return err
	}
	// 3. 构建新文件的路径（文件名），顺序递增 seq 及 enti
	fpath := filepath.Join(w.dir, walName(w.seq()+1, w.enti+1))

	// create a temp wal file with name sequence + 1, or truncate the existing one
	// 4. 创建临时文件，其会使用先前 pipelinefile 预先分配的空间来执行此创建操作
	newTail, err := w.fp.Open()
	if err != nil {
		return err
	}
	// update writer and save the previous crc
	// 5. 同 Create 函数类似，将文件加入到 WAL 的 locks 数组集合
	w.locks = append(w.locks, newTail)
	// 6. 计算 crc 检验和，它是本文件之前的所有记录的检验和
	prevCrc := w.encoder.crc.Sum32()
	// 7. 构建 WAL 实例的 encoder
	w.encoder, err = newFileEncoder(w.tail().File, prevCrc)
	if err != nil {
		return err
	}
	// 8. 先保存 检验和
	if err = w.saveCrc(prevCrc); err != nil {
		return err
	}
	// 9. 再保存 metadata
	if err = w.encoder.encode(&walpb.Record{Type: metadataType, Data: w.metadata}); err != nil {
		return err
	}
	// 10. 接着保存 HardState
	if err = w.saveState(&w.state); err != nil {
		return err
	}
	// atomically move temp wal file to wal file
	if err = w.sync(); err != nil {
		return err
	}
	off, err = w.tail().Seek(0, io.SeekCurrent)
	if err != nil {
		return err
	}
	// 11. 重命名
	if err = os.Rename(newTail.Name(), fpath); err != nil {
		return err
	}
	if err = fileutil.Fsync(w.dirFile); err != nil {
		return err
	}

	// reopen newTail with its new path so calls to Name() match the wal filename format
	newTail.Close()

	//  12. 重新打开并上锁新的文件（重命名之后的）
	if newTail, err = fileutil.LockFile(fpath, os.O_WRONLY, fileutil.PrivateFileMode); err != nil {
		return err
	}
	if _, err = newTail.Seek(off, io.SeekStart); err != nil {
		return err
	}
	// 13. 将新的文件加入数组
	w.locks[len(w.locks)-1] = newTail

	// 14. 重新计算检验和 以及 encoder
	prevCrc = w.encoder.crc.Sum32()
	w.encoder, err = newFileEncoder(w.tail().File, prevCrc)
	if err != nil {
		return err
	}
	return nil
} // wal.go
```

至此关于`WAL`库的日志管理相关的接口已经分析完毕。简单总结一下，本文是从【[etcd raftexample 源码简析](https://qqzeng.top/2019/01/09/etcd-raftexample-%E6%BA%90%E7%A0%81%E7%AE%80%E6%9E%90/)】中对`WAL`库接口的调用切入（日志重放的操作），然后简要分析了`WAL`日志文件创建、`WAL`初始化（打开）、`WAL`日志项读取及`WAL`追加日志项等流程。最后，关于`WAL`库与如何与`raft`核心协议交互的内容，后面再了解。





参考文献

[1]. [etcd-raft日志管理](https://zhuanlan.zhihu.com/p/29692778)
[2]. https://github.com/etcd-io/etcd/tree/master/wal

