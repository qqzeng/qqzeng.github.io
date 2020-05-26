---
title: go map 原理剖析
date: 2020-05-23 13:22:01
categories:
- go
tags:
- go
---

Go 语言提供了 map 内置数据类型，map 在实际开发中应用较为广泛。但在使用 Go map 时难免会有一些疑问，比如 map 底层是如何实现的、map 是如何支持泛型的、 map 中查询不存在的键为什么返回对应值类型的零值、map 遍历为什么没有保证顺序、 map 的元素为什么不能直接寻址以及 map 检测多个 go routine 并发读写的原理是什么等等。因此，本文通过阐述 go runtime 中 map 的实现原理来解决这些疑问。

<!-- More-->

注意，本文并非 map 的使用或介绍教程，因此你需要具备一定基础知识，可以从[这里](https://tour.golang.org/moretypes/19)和[这里](https://blog.golang.org/maps)了解。另外，本文剖析的 Go 源码的版本是 go1.12 ，但事实上相近的不同版本差距并不大，读者可以阅读[源码](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go)以更加细致地了解。具体地，本文首先通过介绍 Go map 源码中一些关键的结构声明和字段以阐述 map 底层大致是如何实现的，然后再结合源码介绍 map 的几个典型的操作，如创建、查询、扩容以及删除和遍历操作实现的基本原理。事实上，若读者熟悉 Java 的 HashMap 或者 C++ 的 unorderedMap 的源码，那也能快速上手 Go map 实现原理，其大致是类似的，只不过因数据结构不同，使得具体实现有些区别。另外，需要提醒的是，本文篇幅非常长，因此，若读者没有足够的时间，则建议阅读第一小节『map 基本实现原理』以对 Go map 的大致了解，它基本是足够的。其次，每一个小节（相当于 map 的一种操作）的开头部分都阐述了对应操作的大致实现原理，这可以使得读者能够不深入源码而对实现的大致原理有更进一步的了解。

## map 基本实现原理

在使用 map 编程时，你是否思考过 map 是如何实现泛型的——键类型支持几乎所有类型（除了 slice、map 和  function 等），而值类型支持所有类型。但到 Go1.4 为止，Go 未提供泛型支持。因此你可能会觉得 map 的签名包含 interface{} 类型，实际上并不是。而且，不同于 Java 和 C++ 所实现的 map 的泛型支持方式，Java 中的 HashMap 所支持的泛型仅能添加对象类型（基本类型需要装箱），并且未将类型信息保留到运行期（泛型擦除），而 C++ 中的 unorderedMap 则实现了真正的泛型，换言之，每一种键值类型的 map 通过代码生成技术都会被编译成不同的类型（因此，在可执行二进制文件中充斥着大量的类型信息）。而 Go 则集成了二者的优点。具体地，它没有 C++ 所面临的类型信息膨胀问题，因为它为不同键值类型的 map 只生成不同的 [maptype](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/type.go#L363) 结构，而且也不会有类型限制（或者频繁装箱和拆箱而遭受性能损失）。

### map 实现原理概述

Go map 由编译器和 runtime 协作实现。概括而言，包括如下两点：

关于数据结构。map 使用数组+链表的实现方式（Java  HashMap 采用数组+链表/红黑树，而 C++  unorderedMap 采用数组+链表），即采用拉链法来解决 key 的冲突问题，其中数组位置被称为 bucket，且初始 bucket 数量为 2^B（即大于用户指定的容量的最小的 2 的指数幂）。另外使用 cell（源码中没有明确这个称呼）来容纳具体键值对信息 ，且一个 bucket 只能装载 8（bucketCnt） 个 cell，当 bucket 中没有更多空间容纳添加的键值对时，则在此 bucket 后动态挂一个称为 overflow 的 bucket，以此类推。其中 bucket 的映射算法使用 key 的 hash 值的低 B 位的值，而 cell 的映射算法使用 key 的 hash 值的高 8 位的值。

关于扩容。扩容的目的是提高检索、插入和删除的效率，而扩容手段采用的是渐近式扩容或者增量扩容（原理和实现类似于 redis 的渐近式 rehash ），即每次执行插入或修改以及删除操作时最多迁移 2 个 bucket。一方面，当整个 map 中包含过多数量的键值对时，即当前键值对数量超过负载因子 6.5（loadFactor），导致此种情形出现的原因是创建的 bucket 数量过少（元素过多），因此将现有容量（即 bucket 的数量）扩大为原来的一倍，在这种情况下，旧的 bucket 中的元素根据其 key 的 hash 值的第 B+1 位是否为 0，以决定其被迁移到扩容后的 bucket 数组的前半部分还是后半部分；另一方面，当整个 map 包含过多 overflow bucket 时，导致此种情形出现的原因是频繁的插入和删除操作创建大量的 overflow bucket，因此开辟一个新的 bucket ，将旧的 bucket 元素以相同的映射方式迁移重组到新的 bucket，通过将 overflow bucket 中的键值对整合到 bucket 中，使得 bucket 中的键值对排列更紧凑，以节省空间并提高 bucket 利用率。事实上，因为采用拉链法，因此过多 overflow bucket 使得元素查找效率急剧下降（不能保证接近O(1)的复杂度）。

### map 实现涉及的关键数据结构

结合源码来看，map 的 runtime 实现主要及到 [hmap](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L115) 和 [bmap](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L149) 两个数据结构，hmap 代表 map header 数据结构，具体如下所示。

```go
type hmap struct {
	count     int    // map 键值对数目。必须处于第一个位置，以使得 len() 函数可以正确获取其长度
	flags     uint8  // map 的状态，如正在被某个迭代器遍历，或者被某个 go routine 写入
	B         uint8  // 容量为 2^B，但只能容纳 loadFactor(6.5) * 2^B 个元素
	noverflow uint16 // overflow buckets 的大致数量
	hash0     uint32 // hash 种子，用于计算 key 的 hash 值

	buckets    unsafe.Pointer // 指向 buckets 数组，大小为 2^B，若 count==0，则其为 nil.
	oldbuckets unsafe.Pointer // 扩容时使用，oldbuckets 指向旧的 bucket 数组，新的 buckets 长度是 oldbuckets 的两倍
	nevacuate  uintptr        // 扩容时使用，元素迁移进度，小于此索引的 buckets 表示已迁移完成

	extra *mapextra // 可选字段，当 key 和 value 可以被 inline 时，会使用此字段
}
// mapextra 包含一些没有包含在 map 中的字段
type mapextra struct {
	overflow    *[]*bmap // 指向一个 bmap 地址切片的指针，表示 overflow bucket
	oldoverflow *[]*bmap // 同上，扩容时使用，表示旧的 overflow bucket

	nextOverflow *bmap // 指向空闲的 overflow bucket 的指针
}
```

 hmap 定义很清晰，但需说明的是，mapextra 源码中注释说若 map 的 key 和 value 都不包含指针，并且可以被 inline（不大于 128 字节），则可使用 mapextra 来存储 overflow bucket，以避免 GC 扫描整个 map。但考虑到 bmap 有一个 overflow 的指针字段（下文），因此就把 overflow 移动到  `hmap.mapextra.overflow`以及`hmap.mapextra.oldoverflow` 字段。换言之，`mapextra.overflow` 包含的是 `hmap.buckets`的 overflow buckets，而`mapextra.oldoverflow`则包含的是`hmap.odlbuckets`的 overflow  buckets。

另外，bmap 表示 bucket 数据结构，即数组元素的表示，其在 runtime 中的定义如下。

```go
type bmap struct {
	// 存储此 bucket 中的 key 的 top hash 值（高8位）
	// 并且，若 tophash[0] < minTopHash，则表示此 bucket 正在被迁移（处于扩容状态）
	tophash [bucketCnt]uint8
}
```

事实上，bmap 在[编译期](https://github.com/golang/go/blob/release-branch.go1.12/src/cmd/compile/internal/gc/reflect.go#L82)会通过反射给它增加几个字段，因此，它真正的结构如下所示。

```go
type bmap struct {
	tophash [bucketCnt]uint8
    keys	[8]keytype 	 // 存储在此 bucket 中 8 个连续的 key
    values	[8]valuetype // 存储在此 bucket 中 8 个连续的 value
    padding	uniptr		 // 内存对齐字段（可选）
    overflow uniptr		 // overflow bucket 指针
}
```

bmap 结构也容易理解，值得注意的是，它的 key/value 的存储的方式，并不是交叉存储，而是分开存储，显然这种存储方式可以压缩 padding 的大小。因此，bmap 的内存结构大致如下所示。其中 hobH 表示元素 key 值的 hash 值的高 8 位。

```
+-------------------------------------------------------+
| hobH | hobH | hobH | hobH | hobH | hobH | hobH | hobH |
+-------------------------------------------------------+
|                         key[8]                        |
+-------------------------------------------------------+
|                         val[8]                        |
+-------------------------------------------------------+
|                    padding(optional)                  |
+-------------------------------------------------------+
|                        *overflow                      |
+-------------------------------------------------------+
```

现在，我们似乎还未找到和 map 支持泛型相关的代码。可以看一下创建 map 的函数原型。

```go
func makemap(t *maptype, hint int, h *hmap) *hmap
```

可以看到 [maptype](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/type.go#L363) 类型的参数 t 被传入创建函数。事实上，maptype 存储了关于此 map 的 key 和 value 的详细信息，对于每一个不同键值对类型的 map，在编译时期会创建一个对应的 maptype。其定义如下。

```go
type maptype struct {
	typ        _type 
	key        *_type // key 的内部类型
	elem       *_type // value 的内部类型
    bucket     *_type // bucket(bmap) 的内部类型
	keysize    uint8  // key 的大小
	valuesize  uint8  // value 的大小
	bucketsize uint16 // bucket 的大小
	flags      uint32 // key 或 value 的状态，比如 key 存储值还是指针值
}
```

如上所示，每个被创建的 maptype 都包含关于从 key 到 elem 的 map 属性的详细信息。其中  [_type](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/type.go#L28) 类型可称为类型描述符。

```go
type _type struct {
	size       uintptr
	ptrdata    uintptr
	hash       uint32
	tflag      tflag
	align      uint8
	fieldalign uint8
	kind       uint8
	alg        *typeAlg
	gcdata    *byte
	str       nameOff
	ptrToThis typeOff
}
```

 _type 类型（类型描述符）包含其所代表类型的详细信息，如大小等。另外，我们可通过其包含的 typeAlg 字段来比较两个类型的值是否相等（equal 函数），以及取得此类型的值的 hash 值（hash 函数）。typeAlg 的结构定义如下所示。

```go
type typeAlg struct {
	// (ptr to object, seed) -> hash
	hash func(unsafe.Pointer, uintptr) uintptr
	// (ptr to object A, ptr to object B) -> ==?
	equal func(unsafe.Pointer, unsafe.Pointer) bool
}
```

### map 实现涉及的关键常量和 util 函数

至此，读者应该清楚 Go map 泛型支持的实现原理了。在正式阐述 map 中各具体操作的逻辑前，为了帮助理解，我们先简单介绍一些关键常量以及一些工具类函数和方法。

```go
const (
	// bucket 包含的 cell 的数量 1 << 3 = 8
	bucketCntBits = 3
	bucketCnt     = 1 << bucketCntBits

	// map 的负载因子，默认是 6.5.
	// 即当 map 中包含的元素大于 (loadFactorFum/loadFactorDen) *  2^B 时，则进行扩容
	loadFactorNum = 13
	loadFactorDen = 2

	// 能够 inline 的 key 和 value 的大小
	maxKeySize   = 128
	maxValueSize = 128

	// dataOffset 即为 bmap 结构的大小，但包含对齐的字节。
	dataOffset = unsafe.Offsetof(struct {
		b bmap
		v int64
	}{}.v)

	// tophash 的一些特殊取值。
	emptyRest      = 0 // cell 是空的，而且在此 cell 后面不存在容纳元素的 cell.
	emptyOne       = 1 // cell 是空的
	evacuatedX     = 2 // 此 cell 所对应的 key/value 被迁移到新的 bucket 数组的前半部分： hash&bucketCnt==0
	evacuatedY     = 3 // 此 cell 所对应的 key/value 被迁移到新的 bucket 数组的后半部分： hash&bucketCnt==1
	evacuatedEmpty = 4 // cell 是空的, 而且此 bucket 对应的 cell 已被迁移
	minTopHash     = 5 // 处于正常状态的 bucket 的最小的 tophash 值。若计算的值小于此值，则直接加上此值作为新的 topHash

	// hmap.flags 的状态取值
	iterator     = 1 // 有迭代器正在使用（遍历） hmap.buckets
	oldIterator  = 2 // 有迭代器正在使用（遍历） hmap.oldbuckets
	hashWriting  = 4 // 有迭代器正在写入或修改 hmap。此字段用于防止 go routine 并发读写 map
	sameSizeGrow = 8 // 当前 map 正执行等量扩容操作。即此时扩容的原因是 overflow buckets 过多

	// 迭代 map 时使用的哨兵 bucket ID，表示当前迭代的 bucket 未处于扩容状态，或者即使处于扩容状态，也已经迁移完毕
	noCheck = 1<<(8*sys.PtrSize) - 1
)
```

```go
// 返回 bucket 数目。如 B = 4，则返回 10000
func bucketShift(b uint8) uintptr {
    // ...
	return uintptr(1) << b
}
// 返回 bucket 数目的掩码值。如 B = 4，则返回 1111
func bucketMask(b uint8) uintptr {
	return bucketShift(b) - 1
}
// 返回指定 key 的 hash 值所对应的 tophash，即获取 hash 值的高 8 位值
func tophash(hash uintptr) uint8 {
	top := uint8(hash >> (sys.PtrSize*8 - 8))
	if top < minTopHash {
		top += minTopHash
	}
	return top
}
//  返回此 bucket 是否已经被迁移完毕
func evacuated(b *bmap) bool {
	h := b.tophash[0]
	return h > emptyOne && h < minTopHash
}
// 返回此 maptype 对应类型值的 overflow 指针
func (b *bmap) overflow(t *maptype) *bmap {
	return *(**bmap)(add(unsafe.Pointer(b), uintptr(t.bucketsize)-sys.PtrSize))
}
// 设置 maptype 对应类型值的 overflow 的指针
func (b *bmap) setoverflow(t *maptype, ovf *bmap) {
	*(**bmap)(add(unsafe.Pointer(b), uintptr(t.bucketsize)-sys.PtrSize)) = ovf
}
// 返回 bucket 中存储 key 的起始偏移位置
func (b *bmap) keys() unsafe.Pointer {
	return add(unsafe.Pointer(b), dataOffset)
}
```

## map 创建函数

map 创建逻辑比较简单。对应的函数为 [makmap](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L305)，首先判断用户传入的大小值是否合法，然后创建 hmap 并初始化 map，接下来计算 `hmap.B` 的大小，即大于传入的 map 大小的最小的 2 的整数幂，最后为 hmap 创建 bmap，即分配一段连续的内存空间来存储元素。其源码如下。

```go
func makemap(t *maptype, hint int, h *hmap) *hmap {
	// t 存储 map 类型信息， hint 表示用户创建的 map 的大小
	// h 若不为 nil，则直接在 h 中创建新的 map，且若 h.buckets 也不为 nil，则其指向的 bucket 即为第一个 bucket 地址
	// 1. 判断 hint 大小是否合法，不能超过最大分配内存，也不能溢出
	mem, overflow := math.MulUintptr(uintptr(hint), t.bucket.size)
	if overflow || mem > maxAlloc {
		hint = 0
	}
	// 2. 初始化 hmap，并确定其 hash 种子的值
	if h == nil {
		h = new(hmap)
	}
	h.hash0 = fastrand()
	// 3. 计算 B 的值，即大于传入的 map 大小的最小的 2 的整数幂
	B := uint8(0)
	for overLoadFactor(hint, B) {
		B++
	}
	h.B = B
	// 4. 若 B=0，则延迟分配 bucket，否则直接开辟内存空间
	if h.B != 0 {
		var nextOverflow *bmap
		h.buckets, nextOverflow = makeBucketArray(t, h.B, nil)
		if nextOverflow != nil {
			h.extra = new(mapextra)
			h.extra.nextOverflow = nextOverflow
		}
	}
	return h
}
```

值得注意的是，makemap 函数返回值是 *hmap 指针类型（不同于 slice，其返回的是 slice 结构体），因此，当将 hmap 作为函数参数时，在函数内部对参数 map 的修改会反映到原始的 map 变量，而不需要像 slice 一样要返回修改后的 slice。

## map 元素查询

map 的元素查询关键点在于 bucket 的映射方法以及 cell 的映射方法。对应的函数为 [mapaccess1](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L396)，其大致过程如下：首先判断若 map 为空或者大小为 0，则直接返回 map 元素值类型的零值。然后，检测是否存在 go routine 并发读写 map 的情况。接下来的执行过程大致为先定位 bucket，再定位 cell。具体地，先获取当前查询的 key 的 hash 值，然后根据 hash 值的低 B 位的值计算 key 所映射的 bucket，同时，计算当前 key 的 tophash 值用于后续映射 bucket 中的 cell。接下来，执行两层 for 循环，外层循环遍历当前 bucket 链（因为可能存在 overflow bucket），内层循环遍历 bucket 的 8 个 cell ，根据 tophash 值定位对应的 cell。需要注意的是，map 元素查询过程可能和 map 扩容操作的元素迁移过程重叠，此时，若旧的 bucket 未迁移完毕，则需要到对应的旧的 bucket 中执行上述的两层 for 循环。

在介绍 map 元素查询源码逻辑前，先简单介绍几个频繁使用的 bucket 定位以及 key 和 value 定位的计算方式。

```go
b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
```

上面为 bucket 定位方式。其中 m 为 map 的掩码值，hash 为 key 的 hash 值，因此 `m&hash`可以计算出对应的 bucket 在数组中的索引，也即需要跳过的 bucket 的数目，最后加上 hmap 中 buckets 指针的偏移，可得到 key 所映射的 bucket 的地址。

```go
k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
```

上面为 key 定位方式。其中 dataOffset 为 bucket 中 key 的起始偏移，因此 `dataOffset+i*uintptr(t.keysize)`可以跳过指定数量的 key，最后通过加上当前 bucket 的地址偏移以获取对应的 key 所映射的 cell 的地址。

```go
v := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.valuesize))
```

上面为 key 所关联的 value 定位方式。显然，其定位过程同 key 类似，只不过需要加上位于其前面的 8 个 key 占用的地址空间。

最后，在 map 中通过指定 key 查找 value 的方法 mapaccess1 的源码解析如下，为了更清楚阐述，删除了部分不太相关的逻辑。

```go
func mapaccess1(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
    // 编译器将用户程序的 v := map[key] 映射到此函数调用
	// t 存储 map 类型信息， h 表示被查询的 map，而 key 表示查询的元素的 key 值
	// ...
	// 1. 若 map 为空，则返回对应元素值类型的零值
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.key.alg.hash(key, 0) // see issue 23734
		}
		return unsafe.Pointer(&zeroVal[0])
	}
	// 2. 禁止 go routine 并发读写 map
	if h.flags&hashWriting != 0 {
		throw("concurrent map read and map write")
	}
	// 3. 获取 key 对应的 typeAlg 字段，以用于计算其 hash 值以及判断两个 key 是否相同
	alg := t.key.alg
	hash := alg.hash(key, uintptr(h.hash0))
	// 4. 计算 hmap.B 的掩码值，然后定位到对应的 bucket
	m := bucketMask(h.B)
	b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
	// 5. 若 map 正在执行扩容过程，则进一步判断是否为等容量扩容，
	// 若非等量扩容（增大为原容量的两倍），则更新上述 m 的值为原来的一半，
	// 同时，定位查询 key 在旧的 bucket 数组中对应的 bucket，
	// 最后，若此对应的 bucket 未迁移完成，则后续将在此 bucket 中检索 key 对应的元素值
	if c := h.oldbuckets; c != nil {
		if !h.sameSizeGrow() {
			m >>= 1
		}
		oldb := (*bmap)(add(c, (hash&m)*uintptr(t.bucketsize)))
		if !evacuated(oldb) {
			b = oldb
		}
	}
	// 6. 计算当前 key 的 tophash 值
	top := tophash(hash)
	// 7. 在指定的 bucket 链（若包含有 overflow bucket）上根据 tophash 值查找对应的 key
bucketloop:
	// 7.1 外层循环遍历 bucket 链上的每个 bucket，
	// 其中 overflow(t) 表示获取下一个 overflow bucket
	for ; b != nil; b = b.overflow(t) {
		// 7.2 内层循环遍历 bucket 包含的每个 cell
		for i := uintptr(0); i < bucketCnt; i++ {
			// 7.3 若 cell 存储的 tophash 值和当前 key 的 tophash 不同，
			// 并且为 emptyRest，则表明当前的 bucket 已经被迁移完成，则直接中止循环
			// 否则，继续查看下一个 cell
			if b.tophash[i] != top {
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			// 7.4 获取当前的 cell 中存储的 key，且若 key 为指针，则解引用取值
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			// 7.5 若当前 cell 的 key 值与查询的 key 值相等，
			// 则计算当前 cell 的 key 所关联的 value 所存储的地址
			// 类似地，若 value 为指针，则解引用取值，最后返回此 value
			if alg.equal(key, k) {
				v := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.valuesize))
				if t.indirectvalue() {
					v = *((*unsafe.Pointer)(v))
				}
				return v
			}
		}
	}
	// 7.6 否则，说明此 key 在当前 map 的所有 bucket 中未找到，返回 map 元素值类型的零值
	return unsafe.Pointer(&zeroVal[0])
}
```

最后，还有两点需要补充说明。首先，从源码中看，map  为源码中两种不同的获取指定 key 所对应 value 的方式实现了两个方法 mapaccess1 和 mapaccess2，其实现逻辑大致类似，只不过 mapaccess2 对应的是源码中`v, ok := map[key]`的访问操作；其次，为了提升执行效率，对于具体的 key 类型，编译器将查找、插入、删除操作所对应的函数用替换为更具体函数。比如，对于 key 为 uint32 类型，其调用 [src/runtime/hashmap_fast.go](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/hashmap_fast.go) 文件中的 [mapaccess1_fast32(t *maptype, h *hmap, key uint32) unsafe.Pointer](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map_fast32.go#L12) 函数。

## map 元素插入或更新

map 元素插入或更新的实现逻辑和 map 元素查询逻辑有很多重叠的地方。对应函数为 [mapassign](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L576)，其大致执行逻辑为：首先做一些预备工作，比如判断当前 map 是否为 nil 或者容量为 0，是否存在 go routine 并发写，以及计算当前 key 的 hash 值，标记当前 map 处于写入状态等。接下来的三层（也可以认为是两层）循环是整个函数的核心，最外层循环主要考虑到当前 map 是否需要执行扩容操作，因为一旦执行扩容操作，则先前 bucket 中的 key 分布信息会失效，同时，在最外层循环中还会执行定位当前 key 所对应的 bucket 索引操作，而且，若当前确实处于扩容状态，则协助迁移最多两个 bucket。然后，进入到里面的两层循环，此两层循环的逻辑同 mapaccess1 函数的两层循环逻辑类似，第一层遍历 bucket 链以定位具体的 bucket，而第二层遍历每个 bucket 的 8 个 cell，查询当前 key 是否在之前就已经插入过，若是，则更新对应 key 在 tophash 数组中的索引地址、key 存储在 cell 中的地址以及 key 所关联的 value 的地址，最后统一赋值。最后一个部分包含一些收尾工作，比如重置当前 map 的写状态，并返回 key 所关联的 value 的地址，最后由汇编指令将对应的值存储到此指针所指的内存地址。在 map 中通过插入或更新键值对的函数 mapassign 的源码如下，同样，为了更清楚阐述，删除了部分不太相关的逻辑。

```go
func mapassign(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	// 编译器将用户程序的 map[key] = value 映射到此函数调用。
	// t 存储 map 类型信息， h 为对应的 map，而 key 表示被插入或更新元素的 key 值。
	// 那么对应 value 值是如何传入的呢？事实上，赋值的最后一步是由编译器额外生成的汇编指令来完成的。
	// mapassign 返回存储对应值的指针，汇编指令将对应的值存储到此指针所指的内存地址。
	// 1. 若 h == nil，则直接 panic。 var m map[keytype]valuetype 这种情形下 m == nil
	if h == nil {
		panic(plainError("assignment to entry in nil map"))
	}
	// ...
	// 2. 同样禁止 go routine 并发写 map
	if h.flags&hashWriting != 0 {
		throw("concurrent map writes")
	}
	// 3. 获取 key 对应的 typeAlg 字段，以用于计算其 hash 值以及判断两个 key 是否相同
	alg := t.key.alg
	hash := alg.hash(key, uintptr(h.hash0))
	// 4. 标记当前 go routine 正在写 map
	h.flags ^= hashWriting
	// 5. 若 buckets 为空，即创建 map 时指定容量为 0： m := make(map[keytype]valuetype, 0)
	// 则直接创建容量为 1 的 map
	if h.buckets == nil {
		h.buckets = newobject(t.bucket) // newarray(t.bucket, 1)
	}
	// 6. again 标签表示由于执行了扩容操作导致 key 的分布信息失效，
	// 因此需要重新走一遍 key 的整个定位过程。
again:
	// 7. 计算当前 key 所映射的 bucket 索引值
	bucket := hash & bucketMask(h.B)
	// 8. 判断当前 map 是否处于扩容状态（包含两种扩容情况），
	// 若是，则先执行 bucket 迁移操作，再执行后续逻辑。
	// 因为 map 扩容时元素迁移是渐近式的，每次插入或修改操作最多迁移两个 bucket
	if h.growing() {
		growWork(t, h, bucket)
	}
	// 9. 定位 key 所对应的 bucket 的地址，同时计算出 key 的 tophash 值
	b := (*bmap)(unsafe.Pointer(uintptr(h.buckets) + bucket*uintptr(t.bucketsize)))
	top := tophash(hash)
	// inserti 指向 key 的 hash 值在 tophash 数组所处的位置
	var inserti *uint8
	// insertk 指向 key 所处的 cell 的位置
	var insertk unsafe.Pointer
	// val 指向 key 关联的 value 所处的的位置
	var val unsafe.Pointer
	// 10. bucketloop 仍旧为两层循环，外层循环遍历 bucket 链，内层循环遍历每个 bucket 的 8 个 cell，
	// 在其中查找同当前 key 相同的 cell，若查询成功，返回 key 所关联的 value 的地址，跳转到 done，
	// 否则，直接跳出循环，此时 inserti、insertk 以及 val 都为空值。
bucketloop:
	for {
		for i := uintptr(0); i < bucketCnt; i++ {
			// 11. 内层循环。循环遍历当前 bucket 的 8 个 cell，查找当前 key 是否存在。
			// 若通过 tophash 找到一个空位 cell，
			// 则记录对应的空位索引地址、key 所存放的 cell 地址，以及关联的 value 的存放地址。
			// 否则，若发现当前遍历的 tophash 值为 emptyRest，表明此 bucket 及其后续的元素已经被迁移，
			// 因此，直接退出遍历当前 bucket 的循环。
			// 否则，当前遍历的 tophash 值同 key 的 tophash 值不相等，且不为空，也不为 emptyRest 时，
			// 则继续遍历下一个 tophash 值。
			if b.tophash[i] != top {
				if isEmpty(b.tophash[i]) && inserti == nil {
					inserti = &b.tophash[i]
					insertk = add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
					val = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.valuesize))
				}
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			// 12. 找到同当前 key 的 tophash 相等的 cell，即当前 key 在之前有可能已经被插入过，
			// 但还需比较两个 key 值是否相同（因为两个不同的 key 其 tophash 有可能相同）
			// 若 key 值不同，则继续遍历下一个 key。
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			if !alg.equal(key, k) {
				continue
			}
			// 13. 否则，可以肯定当前 key 之前已插入过，此次操作为更新操作。
			// 则将 key 所对应的值拷贝到对应的 cell，
			// 然后，计算 key 所关联的 value 的地址，跳转到 done，表明此次操作已经完毕
			if t.needkeyupdate() {
				typedmemmove(t.key, k, key)
			}
			val = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.valuesize))
			goto done
		}
		// 14.继续遍历下一个 overflow bucket，直至遍历完所有的 overflow bucket
		// 则跳出循环。
		ovf := b.overflow(t)
		if ovf == nil {
			break
		}
		b = ovf
	}
	// 15. 若程序执行到这里，说明未能找到对应的 key，表明此次操作为插入操作，需要添加一个 key/value 对，
	// 但在正式插入之前，需要先检测是否需要扩容。
	// 具体地，若 map 当前未执行扩容操作，但满足任一扩容条件（增量扩容和等量扩容），
	// 则执行预扩容操作（即扩容的准备工作），hashGrow 完成分配新的 buckets 工作，
	// 并将旧的 buckets 挂到 oldbuckets 字段。
	// 最后，重新执行步骤 7-14，因为扩容后，所有 key 的分布位置都发生了变化，
	// 因此需要重新走一次之前整个的查找定位 key 的过程。
	if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
		hashGrow(t, h)
		goto again // Growing the table invalidates everything, so try again
	}

	// 16. 表明当前 map 不需要扩容（或者已经扩容完毕），此次操作为插入操作，
	// 且在当前 bucket 中未能找到存储 key 的 cell。
	// 因此，需要创建一个 overflow bucket，然后将此 key 插入到第一个 tophash 位置，
	// 同时计算对应的 key 插入的 cell 位置，和 value 插入的位置。
	if inserti == nil {
		// all current buckets are full, allocate a new one.
		newb := h.newoverflow(t, b)
		inserti = &newb.tophash[0]
		insertk = add(unsafe.Pointer(newb), dataOffset)
		val = add(insertk, bucketCnt*uintptr(t.keysize))
	}
	// 17. 真正执行存储 key 和 value 以及 tophash 值的动作，
	// 但需要考虑 key 和 value 是否为指针的情况，
	// 当插入完毕后，更新当前 map 的元素的数量 count。
	if t.indirectkey() {
		kmem := newobject(t.key)
		*(*unsafe.Pointer)(insertk) = kmem
		insertk = kmem
	}
	if t.indirectvalue() {
		vmem := newobject(t.elem)
		*(*unsafe.Pointer)(val) = vmem
	}
	typedmemmove(t.key, insertk, key)
	*inserti = top
	h.count++

	// 18. 程序执行到这里，表示当前 key/value 已经插入成功，
	// 但有可能在插入过程序执行了扩容以及创建 overflow bucket 的动作。
done:
	// 19. 再次检测是否存在 go routine 并发写，
	// 然后，重置当前 map 的写状态，
	// 最后，返回当前 key 所关联的 value 存储的地址
	if h.flags&hashWriting == 0 {
		throw("concurrent map writes")
	}
	h.flags &^= hashWriting
	if t.indirectvalue() {
		val = *((*unsafe.Pointer)(val))
	}
	return val
}
```

最后，同 map 元素查询操作类似，mapassign 同样有一系列的函数，其根据 key 具体类型，编译器将其优化为相应的快速函数。

## map 扩容函数

考虑到在 map 元素插入或更新，以及 map 元素的删除操作中都涉及到 map 扩容逻辑（bucket 渐近式迁移过程），因此在阐述 map 元素的删除操作之前，先重点了解 map 的扩容原理。下文从三个方面阐述 map 的扩容原理，首先介绍触发 map 扩容的条件，其次阐述扩容的准备工作（即 hashGrow 函数的逻辑），最后重点阐述扩容的具体逻辑（即 growWork 和 evacuate 的逻辑）。

### map 扩容的触发条件

在 mapassign 函数中，在最外层循环包含了检测当前 map 的扩容触发条件是否成立的代码逻辑。具体如下所示。

```go
if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
		hashGrow(t, h)
		goto again
}
```

其中，`h.growing()`方法简单地根据当前 map 的 oldbuckets 是否为空以判断当前 map 是否处于扩容状态。

```go
func (h *hmap) growing() bool {
	return h.oldbuckets != nil
}
```

而`overLoadFactor()`函数则判断当添加当前元素后，是否触发增量扩容（扩大为原容量的两倍）。所谓增量扩容是由当前 map 包含过多的元素导致的，换言之，bucket 数量过少，因此需要增加 bucket 的数量。

```go
func overLoadFactor(count int, B uint8) bool {
	return count > bucketCnt && uintptr(count) > loadFactorNum*(bucketShift(B)/loadFactorDen)
}
```

最后的`tooManyOverflowBuckets()`函数则判断是否触发了等量扩容。所谓等量扩容是由于当前 map 包含过多的 overflow bucket 导致的，而过多的 oveflow bucket 实际上是相对于 bucket 数量而言的，其准确的描述为：map 中包含的 overflow bucket 的数量和 bucket 的数量基本持平，则说明 overflow bucket 中的 cell 非常稀疏（因为若非常紧凑，则早已触发了增量扩容）。因此，等量扩容的目的是将 overflow bucket 中的元素尽可能迁移到 bucket 中，以提高 bucket 的利用率，也间接提高了元素的查询效率。

```go
// 等量扩容的判断条件。在此情况下，overflow buckets 的使用通常是稀疏的，否则早就执行扩容操作了（超过 loadFactor）
func tooManyOverflowBuckets(noverflow uint16, B uint8) bool {
	if B > 15 {
		B = 15
	}
	// 当 bucket 数量不大于 1<<15 时，则触发条件为 overflow bucket 的数量是否超过 bucket 的数量；
	// 否则，其触发条件为 overflow bucket 的数量是否超过 1<< 15。
	return noverflow >= uint16(1)<<(B&15)
}
```

上面的解释可能让读者有些疑惑，为何当 bucket 数量大于 1<<15 时，还是判断 overflow bucket 的数量（noverflow）是否大于 1<<15 以确定是否需要执行等量扩容。源码中注释提示我们需要结合`incrnoverflow()`函数来理解。

```go
func (h *hmap) incrnoverflow() {
	// 因为 noverflow 为 uint16 类型，因此需要限制 h.B 的大小。
    // 当 bucket 数量不大于 1<<15 时，则每次都会直接递增 noverflow 的值，
    // 因此，此时 noverflow 的值是一个准确的值。所以，当 noverflow > 1<<15 时，
    // 会触发等量扩容。
	if h.B < 16 {
		h.noverflow++
		return
	}
	// 当 bucket 数量大于 1<<15 时，每次调用 h.incrnoverflow()，
	// 不一定会增加 noverflow 的大小，实际上它是以 1/(1<<(h.B-15)) 概率递增 h.noverflow，
	// 换言之，结合 tooManyOverflowBuckets() 方法中的判断是否触发等量扩容的条件来看，
	// 当 bucket 数量大于 1<<15 时，只要 noverflow 的值超过 1<<15，则说明需要执行等量扩容。
	// 这个近似的操作是合理的。
	mask := uint32(1)<<(h.B-15) - 1
	// Example: if h.B == 18, then mask == 7,
	// and fastrand & 7 == 0 with probability 1/8.
	if fastrand()&mask == 0 {
		h.noverflow++
	}
}
```

### map 扩容的准备工作

`hashGrow()`函数完成  map 扩容的准备工作。其操作内容大致包括两个方面，首先它会申请新的 bucket 空间，同时更新 oldbucket。其次，更新（转移）迭代器的状态，同时初始化 bucket 的迁移进度。

```go
func hashGrow(t *maptype, h *hmap) {
	// bigger 为增量扩容的扩大因子，即扩大为原来的两倍
	// 1. 判断是否触发了增量扩容，若触发的是等量扩容，则重置 bigger 为 0，
	// 并标记当前是处于等量扩容状态。
	// 然后，保存当前的 bucket 指针，同时开辟新的 bucket 空间。
	// 需要说明的是，无论是等量扩容还是增量扩容，都需要重新开辟 bucket 数组空间，
	// 只是开辟的大小不同。
	bigger := uint8(1)
	if !overLoadFactor(h.count+1, h.B) {
		bigger = 0
		h.flags |= sameSizeGrow
	}
	oldbuckets := h.buckets
	newbuckets, nextOverflow := makeBucketArray(t, h.B+bigger, nil)
	// 2. &^ 为按位置 0 操作符。 z := x &^ y, 它将 y 中的 1 bit 清零，否则保持和 x 相同。
	// 简单而言，在 buckets 转移到 oldBuckets 下之后，此操作转移对应的迭代器的标志位。
	flags := h.flags &^ (iterator | oldIterator)
	if h.flags&iterator != 0 {
		flags |= oldIterator
	}
	// 3. 提交 grow 操作，即更新 map 使其真正处于扩容状态。
	// 同时切换 overflow 和 nextOverflow 指针
	h.B += bigger
	h.flags = flags
	h.oldbuckets = oldbuckets
	h.buckets = newbuckets
	h.nevacuate = 0 // 初始化扩容进度（ bucket 迁移进度为 0）
	h.noverflow = 0 // 重置 overflow bucket 数量
	if h.extra != nil && h.extra.overflow != nil {
		if h.extra.oldoverflow != nil {
			throw("oldoverflow is not nil")
		}
		h.extra.oldoverflow = h.extra.overflow
		h.extra.overflow = nil
	}
	if nextOverflow != nil {
		if h.extra == nil {
			h.extra = new(mapextra)
		}
		h.extra.nextOverflow = nextOverflow
	}
	// the actual copying of the hash table data is done incrementally
	// by growWork() and evacuate().
}
```

### map 渐近式扩容原理

map 元素的插入或修改，以及删除操作都可能执行到 map 的渐近式扩容操作。比如上一小节的 mapassign 函数中存在如下逻辑。

```go
if h.growing() {
	growWork(t, h, bucket)
}
func growWork(t *maptype, h *hmap, bucket uintptr) {
	// 1. 再一次确认此次扩容需要迁移的 bucket 索引，然后执行 evacuate 进行 bucket 迁移
	evacuate(t, h, bucket&h.oldbucketmask())
	// 2. 若当前还是处于扩容状态，即当前还剩有 bucket 未迁移完成，
	// 则再迁移一个 bucket
	if h.growing() {
		evacuate(t, h, h.nevacuate)
	}
}
```

growWork 函数的操作比较简单，它最多执行两个 bucket （包括每个 bucket 后所挂的 overflow bucket）的迁移过程。真正的 bucket 迁移的逻辑位于函数  evacuate 中。同样，在展示其源码注释逻辑时，先概述整个 bucket 迁移过程。

整个 bucket 迁移过程大到处包含四个步骤。首先，获取需要被迁移的 bucket 的地址。其次，若当前 bucket 未被迁移，则依据当前扩容的类型，并根据被迁移的 bucket 在旧的 bucket 数组中的索引，定位其在新的 bucket 数组中插入前半段或者后半段对应的目标 bucket 地址，换言之，后续只需将被迁移的旧的 bucket 中的所有元素逐一插入到新的 bucket 中即可。具体同样是通过两层循环实现，外层循环遍历当前旧的 bucket 链中的每一个 bucket，而内层循环遍历每个 bucket 中的 8 个 cell。具体地，在内层循环遍历过程中，一旦发现当前 cell 的 tophash 为 evacuatedEmpty，则表明其已被迁移。另外，若此次扩容为增量扩容，则还要判断当前 bucket 的元素是迁移到新的 bucket 数组的前半段还是后半段，确定好之后，就可以将原 bucket 中的 key 和 value 存储到对应的目标 bucket 中，然后继续迁移下一个元素。同时，若目标 bucket 没有更多空间容纳被迁移的元素时，则同样在目标 bucket 后挂一个 overflow bucket。第三个步骤执行清除 bucket 操作，即当当前 bucket 已迁移完毕后，且若当前被迁移的 bucket 未被 go routine 使用，则清空旧的 bucket 所存储的 cell 空间。最后，更新 bucket 迁移进度，若所有旧的 bucket 都迁移完成，则清空 map 中包含的旧的 bucket 数组指针和 overflow 指针 。map 渐近式扩容的函数 [evacuate](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L1136) 的源码如下。

```go
// 被迁移到新的数组中的目标 bucket 结构
type evacDst struct {
	b *bmap          
	i int            
	k unsafe.Pointer 
	v unsafe.Pointer
}
func evacuate(t *maptype, h *hmap, oldbucket uintptr) {
	// evacuate 迁移 oldbucket 索引处的 bucket
	// 1. 计算需要迁移的 bucket (oldbucket索引) 的地址偏移，同时计算出旧的 bucket 的容量
	b := (*bmap)(add(h.oldbuckets, oldbucket*uintptr(t.bucketsize)))
	newbit := h.noldbuckets()
	// 2. 若当前 bucket 未被迁移，则开始执行迁移的逻辑。
	// 具体是判断当前 bucket 的首个 tophash 值是否介于 emptyOne 和 minTopHash 中间，
	// 即处于迁移完毕的状态。
	if !evacuated(b) {
		// 3. evacDst 表示迁移的目标 bucket 结构，因此，x 和 y 分别表示迁移到新的 bucket 数组中的前半段还是后半段。
		// x.b 计算出当前被迁移的 bucket b，其对应的在新的 bucket 数组中处于前半段的地址
		// x.k 计算出当前被迁移的 bucket b，其存储的 key 对应的在新的 bucket 数组中处于前半段的 cell 地址
		// x.v 计算出当前被迁移的 bucket b，其存储的 key 关联的 value 对应的在新的 bucket 数组中处于前半段的地址
		// 上述三个计算是关联的，递进式计算求值。
		var xy [2]evacDst
		x := &xy[0]
		x.b = (*bmap)(add(h.buckets, oldbucket*uintptr(t.bucketsize)))
		x.k = add(unsafe.Pointer(x.b), dataOffset)
		x.v = add(x.k, bucketCnt*uintptr(t.keysize))
		// 4. 通过 h.flags 字段判断是否是增量扩容，
		// 若是，则需计算当前被迁移的 bucket b 放置到新的 bucket 数组后半段的具体情况。
		// 类似地，计算 evacDst 包含的三个字段的值。
		if !h.sameSizeGrow() {
			y := &xy[1]
			y.b = (*bmap)(add(h.buckets, (oldbucket+newbit)*uintptr(t.bucketsize)))
			y.k = add(unsafe.Pointer(y.b), dataOffset)
			y.v = add(y.k, bucketCnt*uintptr(t.keysize))
		}
		// 5. 同样是两层循环，外层循环遍历当前需要被迁移的 bucket b 以及挂在其后的 overflow bucket
		// 内层循环遍历每个 bucket 的 8 个 cell
		for ; b != nil; b = b.overflow(t) {
			// 6. 计算当前 bucket 存储 key 和 value 的起始地址偏移
			k := add(unsafe.Pointer(b), dataOffset)
			v := add(k, bucketCnt*uintptr(t.keysize))
			// 7. 遍历当前 bucket 的 8 个 cell
			for i := 0; i < bucketCnt; i, k, v = i+1, add(k, uintptr(t.keysize)), add(v, uintptr(t.valuesize)) {
				// 8. 获取对应 cell 的 key 的 tophash，
				// 若为 empty，则表示其已被迁移，则将其 tophash 标记为 evacuatedEmpty，继续遍历下一个 cell
				// 同时若当前 key 为指针类型，对当前 key 进行解引用，获取对应的 key 值
				top := b.tophash[i]
				if isEmpty(top) {
					b.tophash[i] = evacuatedEmpty
					continue
				}
				// 未迁移的 cell 只可能是 empty 或是正常的 tophash（大于 minTopHash）
				if top < minTopHash {
					throw("bad map state")
				}
				k2 := k
				if t.indirectkey() {
					k2 = *((*unsafe.Pointer)(k2))
				}
				// 9. useY 表示当前 bucket 被迁移到新的 bucket 的后半段
				// 若当前执行增量扩容，则首先计算 key 的 hash 值。
				var useY uint8
				if !h.sameSizeGrow() {
					hash := t.key.alg.hash(k2, uintptr(h.hash0))
					if h.flags&iterator != 0 && !t.reflexivekey() && !t.key.alg.equal(k2, k2) {
						// 9.1 需要注意的一种情况是：当扩容的同时存在 go routine 对 map 进行迭代，
						// 同时，发现相同的 key 值，计算得出不同的 hash 值，这种情况只在 NaN 才出现。
						// 因为，所有的 NaN 值都不同。
						// 对于这种 key 可以随意对其目标进行分配，而且 NaN 的 tophash 也没有意义，
						// 但还是给它计算一个随机的 tophash
                        // 同时，公平地把这些 key(NaN) 均匀分布到前半段和后半段
						useY = top & 1
						top = tophash(hash)
					} else {
						// 9.2 通过 hash&newbit 是否为 0，来决定当前 key 被迁移到新的 bucket 数组的前半段还是后半段。
						// newbit 为旧的 map 容量大小。
						// 事实上这是一个 trick，比如对于旧容量为 16 的情况，即 h.B = 4,
						// bucket 的映射算法为 maskBucket & hash，即取决于 1111 &  hash 值，
						// 当容量扩大一倍后，可通过其第 B 位为 0 还是 1 来判断迁移到新的 bucket 数组的前半段还是后半段。
						if hash&newbit != 0 {
							useY = 1
						}
					}
				}
				if evacuatedX+1 != evacuatedY || evacuatedX^1 != evacuatedY {
					throw("bad evacuatedN")
				}
				// 10. 设置迁移完成的 bucket cell 的状态为 evacuatedX 或 evacuatedY，
				// 分别表示迁移到新的 bucket 数组中的前半段或者后半段。
				b.tophash[i] = evacuatedX + useY // evacuatedX + 1 == evacuatedY
				dst := &xy[useY]                 // evacuation destination
				// 11. 若当前的 tophash 的位置索引超过了 8，则表明当前的 bucket 已经存储满了，
				// 需要在其后挂上新的 overflow bucket，同时初始化其属性值。
				if dst.i == bucketCnt {
					dst.b = h.newoverflow(t, dst.b)
					dst.i = 0
					dst.k = add(unsafe.Pointer(dst.b), dataOffset)
					dst.v = add(dst.k, bucketCnt*uintptr(t.keysize))
				}
				// 12. 设置目标 bucket 指定索引处的 tophash 值，
				// 类似地，若 key 或 value 存储指针值，则将原 key/value 复制到新位置。
				// 最后，更新目标迁移 bucket 的属性值，以为后续元素的迁移做准备
				dst.b.tophash[dst.i&(bucketCnt-1)] = top 
				if t.indirectkey() {
					*(*unsafe.Pointer)(dst.k) = k2 // copy pointer
				} else {
					typedmemmove(t.key, dst.k, k) // copy value
				}
				if t.indirectvalue() {
					*(*unsafe.Pointer)(dst.v) = *(*unsafe.Pointer)(v)
				} else {
					typedmemmove(t.elem, dst.v, v)
				}
				dst.i++
				dst.k = add(dst.k, uintptr(t.keysize))
				dst.v = add(dst.v, uintptr(t.valuesize))
			}
		}
		// 13. 若没有 go routine 在使用旧的 buckets，则将旧的 buckets 清除掉，减轻 gc 压力
        // 即清除掉此 bucket 所存储的 cell(key 和 value) 的空间
		if h.flags&oldIterator == 0 && t.bucket.kind&kindNoPointers == 0 {
			b := add(h.oldbuckets, oldbucket*uintptr(t.bucketsize))
			ptr := add(b, dataOffset)
			n := uintptr(t.bucketsize) - dataOffset
			memclrHasPointers(ptr, n)
		}
	}
	// 14. 最后，若此次迁移的 bucket 正好是当前进度值，则更新扩容进度
	if oldbucket == h.nevacuate {
		advanceEvacuationMark(h, t, newbit)
	}
}

func advanceEvacuationMark(h *hmap, t *maptype, newbit uintptr) {
	// 1. 更新 bucket 迁移进度
	h.nevacuate++
	// 2. 尝试往后最多看 1024 个 bucket，在这些 bucket 中找一个还没有被迁移的 bucket，作为当前迁移进度
	stop := h.nevacuate + 1024
	if stop > newbit {
		stop = newbit
	}
	for h.nevacuate != stop && bucketEvacuated(t, h, h.nevacuate) {
		h.nevacuate++
	}
	// 3. 若当前 bucket 迁移进度表示已经扩容完成，则清空旧的 bucket 数组指针，
	// 以及 overflow bucket 指针，同时，清除表示当前正在进行扩容的标志位。
	if h.nevacuate == newbit { // newbit == # of oldbuckets
		h.oldbuckets = nil
		if h.extra != nil {
			h.extra.oldoverflow = nil
		}
		h.flags &^= sameSizeGrow
	}
}
```

## map 元素删除

map 元素的删除函数为 [mapdelete](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L691)，若读者熟悉前面的 map 操作，则 map 元素删除操作也是容易理解的，基本过程和 mapassign 类似，同样会检测是否需要涉及协助迁移 bucket 的操作。具体地，先做一些判断工作，然后根据 key 来定位 bucket 和 cell。然后将对应的 key 和 value 清除掉，同时将 bucket 对应索引位置的 tophash 设置为 emptyOne。最后，更新 map 包含的元素数量，恢复未写状态等。主要区别有两点：其一，找到 cell 之后，需要将对应的 key 和 value 给清除，对应代码如下。

```go
if t.indirectkey() {
	*(*unsafe.Pointer)(k) = nil
} else if t.key.kind&kindNoPointers == 0 {
	memclrHasPointers(k, t.key.size)
}
v := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.valuesize))
if t.indirectvalue() {
	*(*unsafe.Pointer)(v) = nil
} else if t.elem.kind&kindNoPointers == 0 {
	memclrHasPointers(v, t.elem.size)
} else {
	memclrNoHeapPointers(v, t.elem.size)
}
```

其二，考虑到删除一个元素后，当前 bucket 的 cell 可能已全部被清空，甚至当前 bucket （overflow bucket）的前面的 bucket 也为空，则需要依次将这些 bucket 的状态设置为 emptyRest。具体操作逻辑比较简单，这里就不展示相关代码了。最后，同 map 元素的查询、插入或修改类似，map 元素的删除也会根据 key 的具体类型，将其优化成更具体的函数。

## map 元素遍历

map 元素遍历包含两个关键点。即 map 迭代顺序的原理，以及 map 迭代操作和 map 扩容操作的并发执行过程。

- map 的迭代不保证顺序。这在源码中体现为对于某一次迭代操作，其随机初始化迭代初始的 bucket 索引，同时，随机初始化对应的 bucket 中的 cell 的索引。因此，绝大多数情况下，map 的迭代操作是从中间 bucket 索引位置开始的，往后遍历（地址增长方向），当遍历到 bucket 数组末尾时，则会调转方向，重新到 bucket 数组的起始位置开始遍历，直至遍历到开始生成的随机 bucket 索引的位置，说明 bucket 数组已经遍历完成；
- map 的迭代操作可能同扩容操作并发执行。对于增量扩容而言，bucket  还有可能被迁移到新的 bucket 数组中，也有可能还处于旧的 bucket 数组。这给 map 的迭代操作带来了较大的复杂性。具体而言，当 map 当前迭代的 bucket 处于旧的 bucket 数组时（还未被迁移），则迭代器会指向旧的 bucket 数组中对应 bucket 索引，然后，遍历对应 bucket 包含的 cell，同时，只会输出（返回）那些将被迁移到当前 bucket 的元素，这是因为对于增量扩容的情形，旧的 bucket 中的元素有可能被迁移到新的 bucket 数组中的前半段或者后半段。当将位于旧的 bucket 数组中的对应的 bucket （包括挂在其后的 overflow bucket）所有的 cell 遍历完成后，仍旧会返回到原来的（新的）bucket 数组中，然后，更新当前迭代的 bucket 索引，继续往后遍历。

map 元素的遍历在源码中对应两个函数，其中 [mapiterinit](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L804) 执行迭代器结构的初始化操作，同时调用 [mapnext](https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go#L853) 以获取当前迭代器指向的元素的 key 和 value，同时更新迭代器的状态，指向下一个元素，持续遍历直至遍历完所有元素。mapiterinit 函数的源码如下，删除了不太相关的逻辑。

```go
func mapiterinit(t *maptype, h *hmap, it *hiter) {
	// ...
	// 1. 若当前 map 为 nil 或长度为0，则直接返回
	if h == nil || h.count == 0 {
		return
	}
	// ...
	it.t = t
	it.h = h
	// 2. 将 map 当前的状态复制到迭代器
	it.B = h.B
	it.buckets = h.buckets
	if t.bucket.kind&kindNoPointers != 0 {
		h.createOverflow()
		it.overflow = h.extra.overflow
		it.oldoverflow = h.extra.oldoverflow
	}
	// 3. 这就是每次迭代同一个 map 将打印不同的元素顺序的一个原因。
	// 其每次推迭代时，会随机从一个 bucket 索引开始，针对此 bucket 还会随机从其中的一个 cell 索引开始
	r := uintptr(fastrand())
	if h.B > 31-bucketCntBits {
		r += uintptr(fastrand()) << 31
	}
	it.startBucket = r & bucketMask(h.B)
	it.offset = uint8(r >> h.B & (bucketCnt - 1))
	// 4. 设置当前指向的 bucket 索引（初始时，即为随机抽到的 bucket 索引）
	it.bucket = it.startBucket
	// 5. 设置当前正处于迭代 map 的过程，多个迭代操作可以并发进行
	if old := h.flags; old&(iterator|oldIterator) != iterator|oldIterator {
		atomic.Or8(&h.flags, iterator|oldIterator)
	}
	// 6. 获取当前迭代器指向的元素的 key 和 value，同时更新迭代器的状态，指向下一个元素
	mapiternext(it)
}
```

mapiternext 函数源码如下，同样删除了部分不太相关的逻辑。

```go
func mapiternext(it *hiter) {
	// 1. 首先获取迭代器的一些状态值，同时禁止 map 的并发迭代和写入
	h := it.h
	// ...
	if h.flags&hashWriting != 0 {
		throw("concurrent map iteration and map write")
	}
	t := it.t
	bucket := it.bucket
	b := it.bptr
	i := it.i
	checkBucket := it.checkBucket
	alg := t.key.alg
	// 2. next 标签表示一个 bucket 的迭代过程，
	// 即当一个 bucket 所有的 cell 遍历完成后，会继续遍历下一个 overflow bucket，
	// 然后返回到此处，再执行元素的整个定位逻辑。
next:
	// 3. 若 b 为 nil，则表示当前正是迭代的开始（还未遍历任何元素）
	if b == nil {
		// 3.1 这个条件表明迭代指针返回到了起始迭代的位置，即整个迭代过程已经完成了。
		// it.wrapped 表示已经从头开始遍历了，因为，最开始是从中间的 bucket 开始遍历的。
		// 此时，标记 key 和 value 为 nil，表明迭代结束。
		if bucket == it.startBucket && it.wrapped {
			// end of iteration
			it.key = nil
			it.value = nil
			return
		}
		// 3.2 这个条件表明 map 当前正在执行扩容操作。
		// 此时，若当前迭代指针所指向的 bucket 未被迁移完成，则需要到旧的 bucket 执行迭代遍历，
		// 同时，只输出（返回）那些将被迁移到当前（新的） bucket 的那些元素。
		// 具体地，它计算出当前遍历的 bucket 在旧的 bucket 数组中的索引 oldbucket，
		// 然后，计算出对应的旧的 bucket 地址偏移。
		// 接下来，通过当前 bucket 的第一个 tophash 值的状态，以判断当前 bucket 是否已经迁移完成。
		// 若未迁移完成，则设置 checkBucket 为当前正在迭代的旧的 bucket，
		// 否则，表示当前 bucket 已经迁移完毕，则还是在新的 bucket 数组中定位到对应的 bucket 地址，
		// 同时，将 checkBucket 为 noCheck，表示当前迭代的 bucket 不受扩容的影响。
		if h.growing() && it.B == h.B {
			oldbucket := bucket & it.h.oldbucketmask()
			b = (*bmap)(add(h.oldbuckets, oldbucket*uintptr(t.bucketsize)))
			if !evacuated(b) {
				checkBucket = bucket
			} else {
				b = (*bmap)(add(it.buckets, bucket*uintptr(t.bucketsize)))
				checkBucket = noCheck
			}
			// 3.3 否则，表明当前 map 未执行扩容操作，则直接计算对应的 bucket 地址即可，
			// 同样，将 checkBucket 为 noCheck，表示当前迭代的 bucket 不受扩容的影响。
		} else {
			b = (*bmap)(add(it.buckets, bucket*uintptr(t.bucketsize)))
			checkBucket = noCheck
		}
		// 3.4 更新当前迭代的 bucket 索引，若当前迭代的 bucket 索引等于 bucket 的数量减一，
		// 则表示从中间开始遍历 bucket，已经遍历到末尾了，因此重置 bucket 索引，同时设置 wrapped。
		// 即表示下一次迭代时，需要从头开始遍历前一部分的 bucket 元素。
		// 最后，在每次迭代 bucket 的开始，初始化当前迭代的 cell 的数目 i（不是 cell 的索引）。
		bucket++
		if bucket == bucketShift(it.B) {
			bucket = 0
			it.wrapped = true
		}
		i = 0
	}
	// 4. 设置好当前迭代的 bucket 索引后，就开始循环遍历此 bucket 中的 cell
	// 注意此循环中的 i 在每次迭代时会递增，而当迭代一个新的 bucket 后，会清零。
	for ; i < bucketCnt; i++ {
		// 4.1 计算当前迭代遍历的 cell 的索引。 & (bucketCnt - 1) 目的是避免溢出。
		// 若当前迭代的 cell 的索引处的 tophash 值为空，或者为 evacuatedEmpty，
		// 表明当前 cell 没有元素，或者当前 cell 被迁移了。
		// 因此，继续遍历下一个 cell。
		offi := (i + it.offset) & (bucketCnt - 1)
		if isEmpty(b.tophash[offi]) || b.tophash[offi] == evacuatedEmpty {
			continue
		}
		// 4.2 通过 cell 的索引，计算出对应的 key 和 value，
		// 同时，若 key 为指针，则解引用。
		k := add(unsafe.Pointer(b), dataOffset+uintptr(offi)*uintptr(t.keysize))
		if t.indirectkey() {
			k = *((*unsafe.Pointer)(k))
		}
		v := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+uintptr(offi)*uintptr(t.valuesize))
		// 4.3 此条件表明迭代的 map 正在执行扩容操作，而且是增量扩容。
		// 且此时的 bucket 地址对应的是旧的 bucket 地址。
		if checkBucket != noCheck && !h.sameSizeGrow() {
			// 4.3.1 正常情况下（除了 key 为 NaN）都会走这里。
			// 同时，正如前面所说，只遍历出那些将会迁移到新的 bucket 中的元素。
			if t.reflexivekey() || alg.equal(k, k) {
				hash := alg.hash(k, uintptr(h.hash0))
				if hash&bucketMask(it.B) != checkBucket {
					continue
				}
			} else {
				// 4.3.2 否则，表明此 key 为 NaN，因此，正如在 evacuate 方法中所阐述的，
				// 对于 NaN 元素，在扩容过程中，以随机（50%）的概率被迁移到新的数组的前半段和后半段。
				// 因此，这里和之前的逻辑相对应，看其 tophash 的最低位是否为 1，
				// 若是，则迁移到后半段，否则迁移到前半段。
				if checkBucket>>(it.B-1) != uintptr(b.tophash[offi]&1) {
					continue
				}
			}
		}
		// 4.4 进入到此条件表明 key 为正常的未被迁移的元素（包括 NaN）
		// 则直接设置迭代器的 key 和 value 即可。
		if (b.tophash[offi] != evacuatedX && b.tophash[offi] != evacuatedY) ||
			!(t.reflexivekey() || alg.equal(k, k)) {
			it.key = k
			if t.indirectvalue() {
				v = *((*unsafe.Pointer)(v))
			}
			it.value = v
		} else {
			// 4.5 执行到此处表明对应的元素已经被迁移，更新甚至删除了，
			// 因此调用 mapaccessK 来深度获取对应的 key 和 value
			rk, rv := mapaccessK(t, h, k)
			if rk == nil {
				continue // key has been deleted
			}
			it.key = rk
			it.value = rv
		}
		// 4.6 更新迭代器当前迭代的 bucket 索引，同时递增当前 bucket 中被遍历的 cell 的数目。
		// 设置 checkBucket 的值，因为下一次迭代过程，可能仍旧遍历的是扩容过程中未被迁移的 bucket。
		// 然后返回。
		it.bucket = bucket
		if it.bptr != b { // avoid unnecessary write barrier; see issue 14921
			it.bptr = b
		}
		it.i = i + 1
		it.checkBucket = checkBucket
		return
	}
	// 4.7 若执行到这里，表明当前迭代的 bucket 的所有 cell 已经遍历完毕。
	// 因此，需要继续遍历下一个 overflow bucket，
	// 同时，重置 i 为 0，表示当前迭代的 bucket 已遍历的 cell 数目 为 0。
	// 随即跳转到 next 标签处。
	b = b.overflow(t)
	i = 0
	goto next
}
```

至此，Go map 的几个典型操作的执行逻辑已经阐述完毕。

简单小结，本文围绕  map 介绍了七个方面的内容，其中重点为『map 基本实现原理』、『map 元素查询』以及『map 扩容函数』。七个方面的内容小结如下。

- 『map 基本实现原理』从 map 的数据结构和扩容原理两个层面概述 map 实现原理，同时，将 Go map 同 Java 的 HashMap 以及 C++ 的 unorderedMap 进行了原理上简单对比，最后介绍了一些关键的数据结构、常量以及 util 函数，这有助于理解后续介绍的 map 的各操作的逻辑。若读者不能读完全文，仅了解此小节的内容也能够了解 map 的大致实现原理；
- 『map 创建函数』简单介绍了 map 的创建过程，其返回的是 hmap 类型的指针；
- 『map 元素查询』详细介绍了 map 执行指定元素 key 的查询逻辑，在理解了 bucket、key 以及 value 通过指针地址定位的操作，以及 bucket 和 cell 的映射方法之后，其重点在于遍历两层循环以查找指定的 key 所对应的 value；
- 『map 元素插入或更新』相较于 map 元素的查询逻辑会更复杂，虽然其也包括两层循环来查找指定的 key 和 value，但考虑到 map 元素插入或更新可能会执行 map 的渐进式扩容操作，因此，在此方法中其会协助迁移至多两个 bucket，一旦执行了迁移操作，则需要重新执行 key 的整个定位过程；
- 『map 扩容函数』是个较为复杂的过程。因此，将其拆解为 map 扩容的触发条件、map 扩容的准备工作以及 map 渐进式扩容原理这三个部分来阐述。其重点在于渐进式扩容的过程，考虑到对于增量扩容的情况，原 bucket 数组中指定 bucket 元素可能被迁移到新开辟的 bucket 数组的前半段或者后半段；
- 『map  元素删除』相关逻辑比较简单，同 map 元素插入或更新类似，只不过多了一个清理过程，即将空的 bucket 设置为 emptyRest 状态。
- 『map 元素遍历』主要包括迭代器初始化以及获取当前迭代器指向元素的 key 和 value，同时更新迭代器的状态以指向下一个元素。其中，获取迭代器指向元素的逻辑较为复杂，因为它也需要考虑迭代操作和扩容操作的并发执行，在这种情形下，对于增量扩容，且当前迭代器指向的 bucket 还未迁移完毕，则需要进入到旧的 bucket 数组中指定 bucket 索引处遍历所有的 cell，并返回那些将会被迁移到对应的新的 bucket 索引的元素。

最后，相信对于本文开头提出的那些疑问，读者心中已经有了解答。『参考文献』部分列出文中涉及的资料出处。

## 参考文献

[1]. https://github.com/golang/go/blob/release-branch.go1.12/src/runtime/map.go
[2]. [深度解密Go语言之map](https://www.cnblogs.com/qcrao-2018/p/10903807.html#什么是-map)
[3]. [How the Go runtime implements maps efficiently (without generics)](https://dave.cheney.net/2018/05/29/how-the-go-runtime-implements-maps-efficiently-without-generics)