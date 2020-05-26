---
title: go slice 最佳实践
date: 2020-05-23 13:22:01
categories:
- go
tags:
- go
---

Go 语言切片提供了一种方便、有效且强大的用于处理序列数据的方式。切片和数组都是 Go 内置的数据类型。简单而言，切片类似于动态数组。考虑到 Go 中数组类型和其长度绑定，属于编译期数据类型，操作不够灵活，这导致数组的使用范围非常有限，可以说数组在 Go 中最大的应用就是为切片保存存储空间。相反，切片的应用场景则较广泛，但也较为复杂，切片的运用和程序性能息息相关。因此，本文通过一些示例程序揭示和解决切片使用中相对令人困惑的地方，最重要的是，通过一些 benchmark 阐述和论证切片编程的典型最佳实践。

<!-- More-->

本文并非切片（slice） 的介绍或使用教程，因此假设你已具备切片和数组的基本知识，同时了解大致底层实现，比如[熟悉 slice 的基本操作](https://tour.golang.org/moretypes/7)、清楚[slice 的编程使用](https://golang.org/doc/effective_go.html#slices)，而且能基本了解 [slice 内部实现原理](https://blog.golang.org/slices-intro)以及 [append 和 copy 的实现机制](https://blog.golang.org/slices)。了解上述内容后，相信你对切片已经有比较深刻的认识。这些对于掌握切片编程的最佳实践至关重要。本文以 slice 为核心，阐述切片原理中令人隐蔽和棘手地方，同时，通过 [benchmark](https://golang.org/pkg/testing/#hdr-Benchmarks) 来论证切片编程的最佳实践。另外，本文所有实验均在 Ubuntu 18.04 x86_64，go1.14.3 linux/amd64 的环境下测试通过。为了节省篇幅，删除了文中示例代码的注释，所有示例代码可以在[这里](https://github.com/qqzeng/go-code-snippet/tree/master/slice-best-practice)找到。

在阐述重点内容前，先了解关于切片的一些细节，这有助于理解切片是如何工作的，启示我们应该如何准确且高效地使用切片。

- 当我们在谈论 slice 时，实际上我们指的是 [slice header](https://golang.org/pkg/reflect/#SliceHeader)，它包括长度，容量，底层数据的地址三个字段。这说明在 slice 的赋值和函数参数传递操作复制的是 slice header；
- slice 用于描述和其自身分开存储的数组的连续数据部分。换言之，数组代表 slice 底层数据存储，而 slice 描述数组的一部分；
- 接上一条，Go 中只有值传递，即显式复制被传递的参数，而没有引用传递。另外，在 Go 中谈论引用类型的概念是不合适的，将其称之为[指针持有者类型](https://go101.org/article/value-part.html)（pointer holder）会更合适；
- 当 slice 作为参数传递时，可以改变 slice 的元素，但不能改变 slice 本身。因此，若需要改变 slice 本身，可以将改变后的 slice 返回给调用方，也可以将 slice 的指针作为参数传递；
- 数组类型和其长度绑定，换言之，相同元素类型但不同长度的数组（包括数组指针）属于不同数组类型，不能相互赋值。而元素类型相同的 slice 肯定是同一种类型；
- 多个 slice 可能共享同一个底层数组，因此更改其中一个 slice 的底层数组，可能影响其他切片的状态；
- append 操作在切片容量不够的情况下，会执行扩容操作，扩容会改变元素原来的位置。即， append 操作不一定改变底层数组，因此，append 操作得到的 slice 和原来的 slice 有可能共享底层数组；
- slice 未提供专门的内置函数用于扩展 slice 容量，append 本质是追加元素而非扩展容量，扩展切片容量是 append 的副作用；
- [slice 的扩容策略](https://github.com/golang/go/blob/master/src/runtime/slice.go#L125)包括两个步骤，一是将容量扩充为原 slice 容量的 2 倍或 1.25 倍，二是内存对齐操作。

## nil 切片&空切片

Go 包含两种特殊状态的切片，即 nil 切片和空切片。这两种特殊状态的 slice 有时候会带来一些棘手的问题，因此，我们我们通过下面简单示例程序来了解它们，更详细的阐述在[这里](https://juejin.im/post/5bea58df6fb9a049f153bca8)。

```go
func TestSpecialStateOfSlice(t *testing.T) {
	t.Run("TestSSOS", func(t *testing.T) {
		var s1 []int            // nil slice
		var s2 = []int{}        // empty slice
		var s3 = make([]int, 0) // empty slice
		var s4 = *new([]int)    // nil slice

		fmt.Println(len(s1), len(s2), len(s3), len(s4)) // 0 0 0 0
		fmt.Println(cap(s1), cap(s2), cap(s3), cap(s4)) // 0 0 0 0
		fmt.Println(s1, s2, s3, s4) // [] [] [] []
		
        fmt.Println(s1 == nil, s2 == nil, s3 == nil, s4 == nil) // true false false true
        
		var a1 = *(*[3]int)(unsafe.Pointer(&s1))
        // var a1 = *(*reflect.SliceHeader)(unsafe.Pointer(&s1))
		var a2 = *(*[3]int)(unsafe.Pointer(&s2))
		var a3 = *(*[3]int)(unsafe.Pointer(&s3))
		var a4 = *(*[3]int)(unsafe.Pointer(&s4))

		fmt.Println(a1) // [0 0 0]
		fmt.Println(a2) // [6717704 0 0]
		fmt.Println(a3) // [6717704 0 0]
		fmt.Println(a4) // [0 0 0]
	})
}
```

上面的代码中，首先需要理解四种初始化的确切含义。其中，内置 new 操作被用来为一个任何类型的值开辟内存并返回一个存储此值的指针， 用 new 开辟出来的值均为零值。因此，new 对于创建 slice (map) 没有太大价值。而 make 操作可用来创建 slice (以及map 和 channel)，并且被创建的 slice 中所有元素值均被初始化为零值。从上面的输出可以看出 nil 切片和零切片的打印内容没有什么差异，但空切片底层数组指向的是一个既定地址——[zerobase](https://github.com/golang/go/blob/master/src/runtime/malloc.go#L901) 。空切片和 nil 比较的结果为 false。且官方建议，为了避免混淆空切片和 nil 切片，尽可能使用 nil 切片。

## 切片遍历

Go 为我们提供 `for range`操作来遍历容器类型（slice、map和数组）的变量，相比于传统的`for`循环，`for range`循环操作有一些让人困惑的地方，同时，Go也在某些场合对`for range`操作进行了优化。因此，充分理解`for range`操作能提高容器迭代效率。下面，我们首先阐述`for range`循环中一些相对难以理解的地方，然后，通过一个 benchmark 来论证`for range`的最佳实践，最后，我们通过一个 benchmark 以简单比较数组和 slice 的`for range`操作效率。

### range 循环操作的细节

我们首先通过下面的代码段了解`for range`操作的一些“奇怪”特征（输出显示在对应语句旁边）。

```go
type MyInt int

func TestRangeOfContainer(t *testing.T) {
	t.Run("TestROC1", func(t *testing.T) {
		arr := []MyInt{1, 2, 3}
		for _, v := range arr {
			arr = append(arr, v)
		}
		fmt.Println(arr) // [1 2 3 1 2 3]
	})

	printSeperateLine("TestROC2")
	t.Run("TestROC2", func(t *testing.T) {
		arr := []MyInt{1, 2, 3}
		newArr := []*MyInt{}
		for _, v := range arr {
			newArr = append(newArr, &v)
		}
		for _, v := range newArr {
			fmt.Print(*v, " ") // [3 3 3]
		}
		fmt.Println()
	})

	t.Run("TestROC3", func(t *testing.T) {
		type Person struct {
			name string
			age  MyInt
		}
		persons := [2]Person{{"Alice", 28}, {"Bob", 25}}
		for i, p := range persons {
            // 0 {Alice 28}
            // 1 {Bob 25}
			fmt.Println(i, p)
			// fail to update the element of original array 
            // because of its duplicate <persons> is provided.
			persons[1].name = "Jack"
			// fail to update the field of original array 
            // because of its being a element in its duplicate.
			p.age = 31
		}
		fmt.Println("persons:", &persons) // persons: &[{Alice 28} {Jack 25}]
	})

	t.Run("TestROC4", func(t *testing.T) {
		type Person struct {
			name string
			age  MyInt
		}
		persons := [2]Person{{"Alice", 28}, {"Bob", 25}}
		pp := &persons
		for i, p := range pp {
            // 0 {Alice 28}
            // 1 {Jack 25}
			fmt.Println(i, p)
			// this modification has effects on the iteration.
			pp[1].name = "Jack"
			// fail to update the field of original array pointer.
			p.age = 31
		}
		fmt.Println("persons:", &persons) // 1 {Jack 25} persons: &[{Alice 28} {Jack 25}]
	})

	t.Run("TestROC5", func(t *testing.T) {
		type Person struct {
			name string
			age  MyInt
		}
		persons := []Person{{"Alice", 28}, {"Bob", 25}}
		for i, p := range persons {
            // 0 {Alice 28}
            // 1 {Jack 25}
			fmt.Println(i, p)
			// this modification has effects on the iteration.
			persons[1].name = "Jack"
			// fail to update the field of original slice.
			p.age = 31
		}
		fmt.Println("persons:", &persons) // persons: &[{Alice 28} {Jack 25}]
	})
}
```

我们简单解释上述测试的结果：

- `TestROC1`测试用例中，若 range 操作所遍历的 slice 同初始化声明的 slice 为同一个变量时，则此循环将不会终止。换言之，range 操作所遍历的对象并非原有的 slice 变量；

- `TestROC2`测试用例中，若 range 循环提取值 v 为不同（地址的）变量，则后一个 range 循环将打印出原有 slice 的元素列表。换言之，range 循环操作提取的元素 v，其实是同一个变量（地址不变），循环过程只是将 slice 的元素值拷到到此变量；

- `TestROC3`测试用例中，循环中对原有数组的更新未能起作用，进一步说明 range 操作所遍历的对象并非原有的数组变量，另外，对原有数组元素的更新未能成功，进一步说明 range 循环操作提取的元素并非原有数组中的元素；

- `TestROC4`测试用例中，循环中成功更新原有数组指针，同时结合`TestROC3`，说明 range 操作所遍历的数组指针是原有数组指针的浅拷贝，同样，对原有数组指针中元素未能更新成功，说明 range 循环操作提取元素并非原有数组指针所指向元素；
- `TestROC5`测试用例的结果所得出的结论同`TestROC5`类似，只不过此容器变量为 slice 类型。

综上所述，可得出如下三个结论：

- range 操作遍历的容器变量是原有容器变量的一个（匿名）副本。 且只有容器的直接部分（sizeof 函数所计算部分）被复制。数组是值类型，因此，range 操作的是数组的完整拷贝，而 slice 是指针持有者类型，因此，range 操作的 slice 副本，其和原有 slice 共享底层存储；
- range 操作中的每个循环步，会将容器副本中的一个键和值元素对复制给循环变量，因此，对循环变量的修改不会体现到原容器中，这也说明 range 循环元素元素尺寸较大的数组会带来较大的性能开销；
- range 操作所遍历的键和值将被赋值给同一对循环变量实例。

### range 循环的最佳实践

上一小节提到，对具有较大元素尺寸的数组应用 range 操作会导致较低的循环效率，下面通过一个 benchmark 来简单论证。

```go
type MyInt int
const (
	arraySize   = 1 << 15
	arrayD2Size = 1 << 5
)
func BenchmarkRangeOfArray(b *testing.B) {
	b.Run("BenchmarkROA1", func(b *testing.B) {
		arr := [arraySize][arrayD2Size]MyInt{}
		for i := 0; i < b.N; i++ {
			for i, v := range arr {
				_, _ = i, v
			}
		}
	})
	b.Run("BenchmarkROA2", func(b *testing.B) {
		arr := [arraySize][arrayD2Size]MyInt{}
		parr := &arr
		for i := 0; i < b.N; i++ {
			for i, v := range parr {
				_, _ = i, v
			}
		}
	})
	b.Run("BenchmarkROA3", func(b *testing.B) {
		arr := [arraySize][arrayD2Size]MyInt{}
		for i := 0; i < b.N; i++ {
			for i, v := range arr[:] {
				_, _ = i, v
			}
		}
	})
	b.Run("BenchmarkROA4", func(b *testing.B) {
		arr := [arraySize][arrayD2Size]MyInt{}
		for i := 0; i < b.N; i++ {
			for i := range arr {
				_ = i
			}
		}
	})
	b.Run("BenchmarkROA5", func(b *testing.B) {
		arr := [arraySize][arrayD2Size]MyInt{}
		for i := 0; i < b.N; i++ {
			for j := 0; j < len(arr); j++ {
				_, _ = j, arr[j]
			}
		}
	})
}
```

我们执行``go test -benchmem -run=^$ -bench=^BenchmarkRangeOfArray$ -count 1``来执行上面的 benchmark ，其在笔者机器上的测试结果如下。

```go
BenchmarkRangeOfArray/BenchmarkROA1                  670           1531845 ns/op               0 B/op          0 allocs/op
BenchmarkRangeOfArray/BenchmarkROA2                 3410            366578 ns/op               0 B/op          0 allocs/op
BenchmarkRangeOfArray/BenchmarkROA3                 3391            360236 ns/op               0 B/op          0 allocs/op
BenchmarkRangeOfArray/BenchmarkROA4                91201             12965 ns/op               0 B/op          0 allocs/op
BenchmarkRangeOfArray/BenchmarkROA5                98376             12702 ns/op               0 B/op          0 allocs/op
```

从测试结果，可得出如下结论：

- 当 range 直接遍历具有大尺寸的数组元素时，其遍历效率远低于遍历其对应的指针和切片；
- range 操作遍历数组指针和切片的效率接近，但都低于只提供循环索引变量的情况，同时也低于传统的 for 循环的遍历操作。这说明若在循环中不需要使用到循环变量，则省略它们是好的实践；

当我们将`arrayD2Size`设置为 0 时（即不需要拷贝循环变量），我们发现所有测试结果都非常接近。另外，读者若有兴趣，可以变化`arrayD2Size`的大小以观察其对 range 遍历效率的影响。

### range 操作的 memclr 优化

所谓的 [memclr](https://github.com/golang/go/blob/05c02444eb2d8b8d3ecd949c4308d8e2323ae087/src/runtime/memclr_386.s#L13) 优化指的是，当我们使用 range 遍历操作来清空一个容器时，即将容器中每个元素赋值为其对应类型的零值字面量，则编译器会将整个循环优化成一个 memclr 调用，这显著提升清空容器的执行效率。下面我们通过一个简单的 benchmark 来比较 memclr 优化和使用传统的 for 循环来清空容器的效率比较。

```go
type MyInt int

const (
	expLimit = 26
	incrUint = 2
	initExp  = 6
)

func memclr(s []MyInt) {
	for i := range s {
		s[i] = 0
	}
}
func memsetLoop(s []MyInt, v MyInt) {
	for i := 0; i < len(s); i++ {
		s[i] = v
	}
}
func BenchmarkClearSlice(b *testing.B) {
	for j := 0; initExp+j*incrUint < expLimit; j++ {
		sliceSize := 1 << uint(initExp+j*incrUint)
		b.Run("BenchmarkCS"+strconv.Itoa(j), func(b *testing.B) {
			sli := make([]MyInt, sliceSize)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				memclr(sli)
			}
		})
		b.Run("BenchmarkCS"+strconv.Itoa(j), func(b *testing.B) {
			sli := make([]MyInt, sliceSize)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				memsetLoop(sli, 0)
			}
		})
	}
}
```

然后，执行测试命令`go test -benchmem -run=^$ -bench=^BenchmarkClearSlice$ -count 1`，得到的结果如下：

```
BenchmarkClearSlice/BenchmarkCS-1-64            92657308                11.7 ns/op             0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-64            33621434                34.5 ns/op             0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-256           39937538                30.1 ns/op             0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-256           11074920               109 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-1024          11525629               104 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-1024           2989976               417 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-4096           1785872               653 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-4096            617702              1647 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-16384           263352              4584 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-16384           150302              6888 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-65536            43773             27638 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-65536            38641             32088 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-262144           10000            108601 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-262144           10000            122657 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-1048576           2304            484845 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-1048576           2294            537908 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-4194304            549           2092379 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-4194304            220           5122413 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-1-16777216           141           8401282 ns/op               0 B/op          0 allocs/op
BenchmarkClearSlice/BenchmarkCS-2-16777216            62          20834414 ns/op               0 B/op          0 allocs/op
```

上面的测试结果论证了 memclr 优化的有效性。同时，我们还可以使用 [pprof](https://blog.golang.org/pprof) 工具来具体查看程序中`memclr`方法和`memsetLoop`各自具体的 cpu 耗时，具体的使用方法这里就不展开了。读者还可以使用这个[测试程序](https://github.com/qqzeng/go-code-snippet/blob/master/slice-best-practice/memclr_pprof_case.go)，首先构建它，然后执行程序，它会生成相应的`cpu profile`，最后执行 pprof 命令来查看生成的报告 `go tool pprof memclr_pprof_case  -cpuprofile /tmp/profile442700233/cpu.pprof`，然后使用 top 命令查看程序中最耗时的那些函数，还可以使用`list/disasm <function name>`来查看具体耗时。pprof  执行结果如下。

```
File: memclr_pprof_case
Type: cpu
Time: May 22, 2020 at 7:10pm (CST)
Duration: 12.36s, Total samples = 11.58s (93.71%)
Entering interactive mode (type "help" for commands, "o" for options)
(pprof) top 5
Showing nodes accounting for 11560ms, 99.83% of 11580ms total
Dropped 15 nodes (cum <= 57.90ms)
Showing top 5 nodes out of 13
      flat  flat%   sum%        cum   cum%
    8000ms 69.08% 69.08%     8000ms 69.08%  main.memsetLoop
    3420ms 29.53% 98.62%     3420ms 29.53%  runtime.memclrNoHeapPointers
     140ms  1.21% 99.83%      140ms  1.21%  runtime.futex
         0     0% 99.83%    11420ms 98.62%  main.main
         0     0% 99.83%     3410ms 29.45%  main.memclr
(pprof) list main.memesetLoop
Total: 11.58s
(pprof) list main.memsetLoop
Total: 11.58s
ROUTINE ======================== main.memsetLoop in /home/ubuntu/workSpaces/go/src/github.com/qqzeng/go-code-snippet/slice-best-practice/memclr_pprof_case.go
        8s         8s (flat, cum) 69.08% of Total
         .          .     17:   for i := range s {
         .          .     18:           s[i] = 0
         .          .     19:   }
         .          .     20:}
         .          .     21:func memsetLoop(s []MyInt, v MyInt) {
     6.41s      6.41s     22:   for i := 0; i < len(s); i++ {
     1.59s      1.59s     23:           s[i] = v
         .          .     24:   }
         .          .     25:}
         .          .     26:
         .          .     27:func testMemclr() {
         .          .     28:   sli := make([]MyInt, arraySize)
(pprof) list main.memclr
Total: 11.58s
ROUTINE ======================== main.memclr in /home/ubuntu/workSpaces/go/src/github.com/qqzeng/go-code-snippet/slice-best-practice/memclr_pprof_case.go
         0      3.41s (flat, cum) 29.45% of Total
         .          .     12:   arraySize = 1 << 26
         .          .     13:   loopLimit = 100
         .          .     14:)
         .          .     15:
         .          .     16:func memclr(s []MyInt) {
         .      3.41s     17:   for i := range s {
         .          .     18:           s[i] = 0
         .          .     19:   }
         .          .     20:}
         .          .     21:func memsetLoop(s []MyInt, v MyInt) {
         .          .     22:   for i := 0; i < len(s); i++ {
(pprof)
```

pprof 给出的结果同我们的 benchmark 接近，`memsetLoop`的耗时是`memclr`的两倍左右。

### 数组和切片的测试比较

最后，我们对不同容量的数组和切片进行简单的性能测试。这个测试的主题和 range 操作没有太大联系，只是我们使用 range 循环来为数组和切片进行赋值。benchmark 程序如下，且为了节省篇幅，省略了更大容量数组的测试程序，全部代码可参考[这里](https://github.com/qqzeng/go-code-snippet/blob/master/slice-best-practice/slices/range_slice_test.go#L244)。

```go
type MyInt int

const (
	incrUint = 2
)

func BenchmarkBasicSlice(b *testing.B) {
	const incrUint = 3
	const expLimit = 28
	for j := 0; initExp+j*incrUint < expLimit; j++ {
		sliceSize := 1 << uint(initExp+j*incrUint)
		b.Run("BenchmarkS-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				s := make([]MyInt, sliceSize)
				for i, v := range s {
					s[i] = MyInt(1 + i)
					_ = v
				}
			}
		})
	}
}
func BenchmarkBasicArray(b *testing.B) {
	const incrUint = 3
	const (
		arraySize6  = 1 << 6
		arraySize9  = 1 << (6 + incrUint)
		arraySize12 = 1 << (6 + incrUint*2)
		arraySize15 = 1 << (6 + incrUint*3)
		arraySize18 = 1 << (6 + incrUint*4)
		arraySize21 = 1 << (6 + incrUint*5)
		arraySize24 = 1 << (6 + incrUint*6)
		arraySize27 = 1 << (6 + incrUint*7)
	)
	b.Run("BenchmarkA-"+strconv.Itoa(arraySize6), func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			a := [arraySize6]MyInt{}
			for i, v := range a {
				a[i] = MyInt(1 + i)
				_ = v
			}
		}
	})
    // ...
}
```

执行命令`go test -benchmem -run=^$ -bench=^BenchmarkBasic* -count 1`，测试结果如下所示。

```
BenchmarkSlice/BenchmarkS-64             8226044               131 ns/op             512 B/op          1 allocs/op
BenchmarkSlice/BenchmarkS-512            1420550               857 ns/op            4096 B/op          1 allocs/op
BenchmarkSlice/BenchmarkS-4096            225555              5459 ns/op           32768 B/op          1 allocs/op
BenchmarkSlice/BenchmarkS-32768            30286             42308 ns/op          262144 B/op          1 allocs/op
BenchmarkSlice/BenchmarkS-262144            3770            331089 ns/op         2097152 B/op          1 allocs/op
BenchmarkSlice/BenchmarkS-2097152            236           4803495 ns/op        16777216 B/op          1 allocs/op
BenchmarkSlice/BenchmarkS-16777216            40          28614153 ns/op        134217728 B/op         1 allocs/op
BenchmarkSlice/BenchmarkS-134217728            2        8294252180 ns/op        1073741824 B/op        1 allocs/op

BenchmarkArray/BenchmarkA-64            25120772                46.8 ns/op             0 B/op          0 allocs/op
BenchmarkArray/BenchmarkA-512            6202855               195 ns/op               0 B/op          0 allocs/op
BenchmarkArray/BenchmarkA-4096            739294              1564 ns/op               0 B/op          0 allocs/op
BenchmarkArray/BenchmarkA-32768           101179             12290 ns/op               0 B/op          0 allocs/op
BenchmarkArray/BenchmarkA-262144           12030            100248 ns/op               0 B/op          0 allocs/op
BenchmarkArray/BenchmarkA-2097152            273           4581004 ns/op        16777216 B/op          1 allocs/op
BenchmarkArray/BenchmarkA-16777216            39          29075298 ns/op        134217728 B/op         1 allocs/op
BenchmarkArray/BenchmarkA-134217728            2        8289524371 ns/op       1073741824 B/op        1 allocs/op
```

从测试结果来看，在容量较小时（小于 1 << 21时，并非准确阈值），因为数组在编译时期已经分配好存储空间，而 slice 则需在运行时动态分配，因此，数组的效率要显著优于 slice 的效率（一倍左右），而当设置非常大的容量之后，二者的速度基本接近，但在笔者机器上运行多次，发现仍然是数组效率占优。读者不妨自己动手试试看。

## 切片的扩容

在阐述 slice 的克隆、插入和删除相关的最佳实践之前，先简单介绍切片扩容操作，前面了解到切片并未提供显式的扩容接口，其中 append 操作可以按照一定的策略自动扩容，切片类似于动态数组，频繁的扩容必然影响程序效率。前文简单介绍了 slice 扩容策略，读者可通过自己阅读[源码](https://github.com/golang/go/blob/master/src/runtime/slice.go#L125)，或者参考[这里](https://jodezer.github.io/2017/05/golangSlice%E7%9A%84%E6%89%A9%E5%AE%B9%E8%A7%84%E5%88%99)以了解具体的扩容策略。

### 切片扩容的细节

先简单了解因为切片的扩容操作导致的一些微妙的问题。我们看如下两段代码。

```go
func TestGrowOfsli(t *testing.T) {
	t.Run("TestGOS-1", func(t *testing.T) {
		sli := []int{10, 20, 30, 40}
		newSli := append(sli, 50)
		fmt.Printf("Before update sli = %v, Pointer = %p, len = %d, cap = %d\n", sli, &sli, len(sli), cap(sli))
		fmt.Printf("Before update newSli = %v, Pointer = %p, len = %d, cap = %d\n", newSli, &newSli, len(newSli), cap(newSli))
		newSli[1] += 10
		fmt.Printf("After update sli = %v, Pointer = %p, len = %d, cap = %d\n", sli, &sli, len(sli), cap(sli))
		fmt.Printf("After update newSli = %v, Pointer = %p, len = %d, cap = %d\n", newSli, &newSli, len(newSli), cap(newSli))
	})

	t.Run("TestGOS-2", func(t *testing.T) {
		array := [4]int{10, 20, 30, 40}
		sli := array[0:2]
		newSli := append(sli, 50)
		var pArrayOfSli = (*[3]int)(unsafe.Pointer(&array))
		var pArrOfnewSli = (*[3]int)(unsafe.Pointer(&array))
		fmt.Printf("Before sli = %v, Pointer Slice = %p, Pointer Array Of Slice = %p, Pointer Array= %p, len = %d, cap = %d\n",
			sli, &sli, pArrayOfSli, &array, len(sli), cap(sli))
		fmt.Printf("Before newSli = %v, Pointer Slice = %p, Pointer Array Of NewSlice = %p, Pointer Array= %p, len = %d, cap = %d\n",
			newSli, &newSli, pArrOfnewSli, &array, len(newSli), cap(newSli))
		newSli[1] += 10
		fmt.Printf("After sli = %v, Pointer = %p, len = %d, cap = %d\n", sli, &sli, len(sli), cap(sli))
		fmt.Printf("After newSli = %v, Pointer = %p, len = %d, cap = %d\n", newSli, &newSli, len(newSli), cap(newSli))
		fmt.Printf("After array = %v\n", array)
	})
}
```

执行命令`go test -run=^TestGrowOfsli$`，测试结果如下所示。

```
Before append sli = [10 20 30 40], Pointer = 0xc00000c0e0, len = 4, cap = 4
Before append newSli = [10 20 30 40 50], Pointer = 0xc00000c100, len = 5, cap = 8
After append sli = [10 20 30 40], Pointer = 0xc00000c0e0, len = 4, cap = 4
After append newSli = [10 30 30 40 50], Pointer = 0xc00000c100, len = 5, cap = 8

Before sli = [10 20], Pointer Slice = 0xc00000c1c0, Pointer Array Of Slice = 0xc00001c220, Pointer Array= 0xc00001c220, len = 2, cap = 4
Before newSli = [10 20 50], Pointer Slice = 0xc00000c1e0, Pointer Array Of NewSlice = 0xc00001c220, Pointer Array= 0xc00001c220, len = 3, cap = 4
After sli = [10 30], Pointer = 0xc00000c1c0, len = 2, cap = 4
After newSli = [10 30 50], Pointer = 0xc00000c1e0, len = 3, cap = 4
After array = [10 30 50 40]
```

从`TestGOS-1`的输出结果来看：一方面，此时的 append 操作重新分配底层存储，即新的切片和原切片没有共享底层数组，另一方面，append 操作扩容后的新容量为 8(=2*4)，因此，在修改其中一个切片的元素，另一个切片的的元素并未受到相应影响。

从`TestGOS-2`的输出结果来看：一方面，此时的 append 操作未重新分配底层存储，两个切片共享底层数组，值得注意的是，此时修改其中一个切片的元素，另一个切片以及底层的数组的元素值也同样被更新。

综上所述，切片的 append 操作产生的结果切片不一定会重新分配底层存储，因此，对结果切片的更新操作也不一定会影响同其共享的切片，以及被共享的底层数组。这需要我们在编程时额外注意。

### 切片扩容的测试

另外，我们通过一个简单的 benchmark 测试下频繁扩容的具体影响，代码如下。

```go
func BenchmarkGrowSlice(b *testing.B) {
	const innerLoops = 100
	const preAllocSize = innerLoops * 5
	b.Run("BenchmarkGS-1", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			var s []int
			for j := 0; j < innerLoops; j++ {
				s = append(s, []int{j, j + 1, j + 2, j + 3, j + 4}...)
			}
		}
	})
	b.Run("BenchmarkGS-2", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			s := make([]int, 0, preAllocSize)
			for j := 0; j < innerLoops; j++ {
				s = append(s, []int{j, j + 1, j + 2, j + 3, j + 4}...)
			}
			// fmt.Println(cap(s))
		}
	})
	b.Run("BenchmarkGS-3", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			s := make([]int, preAllocSize)
			n := 0
			for j := 0; j < innerLoops; j++ {
				n += copy(s[n:], []int{j, j + 1, j + 2, j + 3, j + 4})
			}
		}
	})
}
```

三个测试用例的不同之处在于内存分配以及为 slice 添加元素的方式。执行测试命令`go test -benchmem -run=^$ -bench=^BenchmarkGrowSlice$ -count 1`，测试结果如下。

```
BenchmarkGrowSlice/BenchmarkGS-1                  373908              3237 ns/op           12240 B/op          8 allocs/op
BenchmarkGrowSlice/BenchmarkGS-2                 1000000              1172 ns/op               0 B/op          0 allocs/op
BenchmarkGrowSlice/BenchmarkGS-3                 1107466              1048 ns/op               0 B/op          0 allocs/op
```

因为`BenchmarkGS-1`未提前分配内存，而使用 append 操作自动扩容。因此其在添加大量数据的场景下，会因频繁扩容而效率低下。而`BenchmarkGS-2`提前分配足够的内存，同时使用 append 操作来添加元素，因此执行添加元素操作时，实际上无需额外分配空间，这使得它的效率要远高于未提前分配内存且使用 append 操作的方式。最后的`BenchmarkGS-3`和 append 操作的效率类似。因此，可得出结论：实际编程中，对于 append 和 copy 操作，一般而言， append 是应用于未知所需容量大小的场景，而 copy 则是预先知道所需容量，因此，添加元素时只需拷贝元素即可。但即使 append 操作能够自动扩容，若知道所需容量的大小，提前分配足够的初始容量是一种好的实践方式，若不能确定所需要容量大小，分配一个经验值的容量大小也有利于减少 append 扩容操作的次数，提高程序效率。

下文通过一些简单的 benchmark 以介绍切片克隆、删除以及插入切片元素的实践技巧。这部分内容来源于[这里](https://github.com/golang/go/wiki/SliceTricks)，并对它们扩展及测试，以形成对各种操作执行效率的基本认识。这部分详细参考代码在[这里](https://github.com/qqzeng/go-code-snippet/blob/master/slice-best-practice/slices/mod_slice_test.go)。

## 克隆切片

克隆切片元素可以使用 append 或 copy 操作，下面展示了切片克隆的三种具体实现方式。

```go
type MyInt int
func Clone(ori []MyInt) []MyInt {
	oriClone := append(ori[:0:0], ori...)
	return oriClone
}
// if ori is nil, return a non-nil slice.
func Clone2(ori []MyInt) []MyInt {
	oriClone := make([]MyInt, len(ori))
	copy(oriClone, ori)
	return oriClone
}
// returns nil even if the source slice a is a non-nil empty slice.
func Clone3(ori []MyInt) []MyInt {
	oriClone := append([]MyInt(nil), ori...)
	return oriClone
}
```

下面是以上三种方式对应的测试程序。

```go
const (
	expLimit = 26
	incrUint = 2
	initExp  = 6
)
func benchmarkCloneSlice(b *testing.B, f func(b *testing.B, sz int, cloner func(ori []MyInt) (result []MyInt))) {
	for j := 0; initExp+j*incrUint < expLimit; j++ {
		sliceSize := 1 << uint(initExp+j*incrUint)
		b.Run("BenchmarkCS-1-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			f(b, sliceSize, Clone)
		})

		b.Run("BenchmarkCS-2-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			f(b, sliceSize, Clone2)
		})

		b.Run("BenchmarkCS-3-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			f(b, sliceSize, Clone3)
		})
	}
}
func BenchmarkCloneSlice(b *testing.B) {
	benchmarkCloneSlice(b, func(b *testing.B, sz int, cloner func(ori []MyInt) (result []MyInt)) {
		sli := make([]MyInt, sz)
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_ = cloner(sli)
		}
	})
}
```

执行测试命令`go test -benchmem -run=^$ -bench=^BenchmarkCloneSlice$ -count 1`，笔者机器上的测试结果如下。

```
BenchmarkCloneSlice/BenchmarkCS-1-64             8705222               126 ns/op             512 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-64            11212414               111 ns/op             512 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-64            11065206               112 ns/op             512 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-256            3613802               338 ns/op            2048 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-256            3305574               367 ns/op            2048 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-256            3419361               358 ns/op            2048 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-1024            928869              1291 ns/op            8192 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-1024            893323              1671 ns/op            8192 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-1024            774730              1323 ns/op            8192 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-4096            274794              4509 ns/op           32768 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-4096            222540              6111 ns/op           32768 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-4096            267927              4381 ns/op           32768 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-16384            72402             17123 ns/op          131072 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-16384            50442             21794 ns/op          131072 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-16384            73422             16813 ns/op          131072 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-65536            17569             68165 ns/op          524288 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-65536            12440             97966 ns/op          524288 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-65536            17532             68458 ns/op          524288 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-262144            3733            302609 ns/op         2097152 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-262144            1802            667451 ns/op         2097152 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-262144            4084            306389 ns/op         2097152 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-1048576           1363            882149 ns/op         8388608 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-1048576            468           2566684 ns/op         8388608 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-1048576           1442            860908 ns/op         8388608 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-4194304            237           4942850 ns/op        33554432 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-4194304            170           6988974 ns/op        33554432 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-4194304            235           4960112 ns/op        33554432 B/op          1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-1-16777216            60          19953652 ns/op        134217728 B/op       1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-2-16777216            43          27613843 ns/op        134217728 B/op       1 allocs/op
BenchmarkCloneSlice/BenchmarkCS-3-16777216            61          19484353 ns/op        134217728 B/op       1 allocs/op
```

从以上性能测试结果来看，第一种和第三种方式的克隆效率接近，都要优于第二种克隆方式。但值得注意的是，第二种克隆方式克隆 nil 切片会得到一个 non-nil 切片，而第三种克隆方式克隆一个空切片会得到一个 nil 切片，这可能不是你需要的，因此，在实际使用时需作额外判断。综上，第一种克隆方式是最简单有效的，它直接从已有切片派生一个 0 容量的新切片。

## 删除切片元素

删除切片元素的一个关键点在于是否需要维持剩余元素的相对顺序，这对执行效率有较大影响。另外，删除切片元素包括删除单个和删除连续范围的切片元素。但事实上，删除单个切片元素是删除连续范围切片元素的一种特殊情况，二者的实现和性能表现都类似。因此这里只展示删除连续范围切片元素的测试结果。

### 删除单个切片元素

###  删除连续范围切片元素

下面展示删除连续范围切片元素的三种具体实现方式，其中方式一和二维持剩余切片元素的相对顺序。

```go
type MyInt int
func DelRangeInOrder(s []MyInt, from int, to int) []MyInt {
	tmp := append(s[:from], s[to:]...)
	return tmp
}
func DelRangeInOrder2(s []MyInt, from int, to int) []MyInt {
	tmp := s[:from+copy(s[from:], s[to:])]
	return tmp
}
func DelRangeOutOfOrder(s []MyInt, from int, to int) []MyInt {
	if n := to - from; len(s)-to < n {
		copy(s[from:to], s[to:])
	} else {
		copy(s[from:to], s[len(s)-n:])
	}
	tmp := s[:len(s)-(to-from)]
	return tmp
}
```

下面是以上三种删除方式对应的测试程序。

```go
const (
	expLimit = 26
	incrUint = 2
	initExp  = 6
)
func generateInterval(r *rand.Rand, max int) (int, int) {
	delIndexL := r.Intn(max)
	delIndexH := r.Intn(max)
	if delIndexL > delIndexH {
		return delIndexH, delIndexL
	}
	return delIndexL, delIndexH
}
func benchmarkDeleteRangeOfSlice(b *testing.B, f func(b *testing.B, sz int,
	deleter func(sli []MyInt, dl int, dh int) (result []MyInt))) {
	for j := 0; initExp+j*incrUint < expLimit; j++ {
		sliceSize := 1 << uint(initExp+j*incrUint)
		b.Run("BenchmarkDROS-1-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			f(b, sliceSize, DelRangeInOrder)
		})

		b.Run("BenchmarkDROS-2-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			f(b, sliceSize, DelRangeInOrder2)
		})

		b.Run("BenchmarkDROS-3-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			f(b, sliceSize, DelRangeOutOfOrder)
		})
	}
}
func BenchmarkDeleteRangeOfSlice(b *testing.B) {
	benchmarkDeleteRangeOfSlice(b, func(b *testing.B, sz int,
		deleter func(sli []MyInt, dl int, dh int) (result []MyInt)) {
		sli := make([]MyInt, sz)
		r := rand.New(rand.NewSource(time.Now().UnixNano()))
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			dl, dh := generateInterval(r, sz)
			_ = deleter(sli, dl, dh)
		}
	})
}
```

执行测试命令`go test -benchmem -run=^$ -bench=^BenchmarkDeleteRangeOfSlice$ -count 1`，笔者机器上的测试结果如下。

```
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-64                 19558353                61.2 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-64                 18577694                63.6 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-64                 17482377                63.7 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-256                16634200                67.6 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-256                17841384                69.6 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-256                17188262                70.2 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-1024               12792736                95.7 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-1024               12631670                92.7 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-1024               15232003                79.5 ns/op             0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-4096                5089140               241 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-4096                5129475               235 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-4096                7656724               159 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-16384                619933              1913 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-16384                630433              1940 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-16384               1000000              1042 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-65536                 99871             11927 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-65536                103848             11668 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-65536                198235              6153 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-262144                13483             88173 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-262144                13726             90386 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-262144                42987             28412 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-1048576                2991            350443 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-1048576                3769            347662 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-1048576                8601            133422 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-4194304                 789           1515745 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-4194304                 826           1612763 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-4194304                2442            530678 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-1-16777216                220           5430883 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-2-16777216                190           6285572 ns/op               0 B/op          0 allocs/op
BenchmarkDeleteRangeOfSlice2/BenchmarkDROS-3-16777216                384           2738002 ns/op               0 B/op          0 allocs/op
```

性能测试结果符合我们的猜想，不用维持剩余切片元素的相对顺序能显著提升性能。注意，三种方式删除 nil 或空切片会 panic。

## 插入切片

插入切片元素同删除切片元素相对应，但不同的是，实际编程中，插入切片元素的实践一般指将一个切片所有元素插入到另一个切片。虽然也有将零散元素插入到切片的情况。但这里只展示将一个切片插入到另一个切片指定位置的测试结果。下面是两种插入方式，它们的根本区别在于一种是一次性分配足够的内存，同时结合 copy  操作，而另一种则直接使用 append 操作。

```go
type MyInt int
func InsertSlice(s []MyInt, elements []MyInt, i int) []MyInt {
	s = append(s[:i], append(elements, s[i:]...)...)
	return s
}
// More efficient but tedious
func InsertSlice2(s []MyInt, elements []MyInt, i int) []MyInt {
	if cap(s)-len(s) >= len(elements) {
		s = s[:len(s)+len(elements)]
		copy(s[i+len(elements):], s[i:])
		copy(s[i:], elements)
	} else {
		x := make([]MyInt, 0, len(elements)+len(s))
		x = append(x, s[:i]...)
		x = append(x, elements...)
		x = append(x, s[i:]...)
		s = x
	}
	return s
}
```

下面是以上两种插入方式对应的测试程序。

```go
const (
	expLimit = 26
	incrUint = 2
	initExp  = 6
)
func BenchmarkInsertSlice(b *testing.B) {
	for j := 0; initExp+j*incrUint < expLimit; j++ {
		sliceSize := 1 << uint(initExp+j*incrUint)
		b.Run("BenchmarkIS-1-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			sli := make([]MyInt, sliceSize)
			sli2 := make([]MyInt, sliceSize/2)
			r := rand.New(rand.NewSource(time.Now().UnixNano()))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				insertIndex := r.Intn(sliceSize)
				_ = InsertSlice(sli, sli2, insertIndex)
			}
		})

		b.Run("BenchmarkIS-2-"+strconv.Itoa(sliceSize), func(b *testing.B) {
			sli := make([]MyInt, sliceSize)
			sli2 := make([]MyInt, sliceSize/2)
			r := rand.New(rand.NewSource(time.Now().UnixNano()))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				insertIndex := r.Intn(sliceSize)
				_ = InsertSlice2(sli, sli2, insertIndex)
			}
		})
	}
}
```

执行测试命令`go test -benchmem -run=^$ -bench=^BenchmarkInsertSlice$ -count 1`，笔者机器上的测试结果如下。

```
BenchmarkInsertSlice/BenchmarkIS-1-64            2187957               511 ns/op            1615 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-64            4695094               228 ns/op             768 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-256            819127              1337 ns/op            6487 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-256           2078091               513 ns/op            3072 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-1024           301641              4187 ns/op           25864 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-1024           647520              1836 ns/op           12288 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-4096            75786             14610 ns/op           96167 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-4096           137834              8866 ns/op           49152 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-16384           25744             47725 ns/op          348537 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-16384           34798             36605 ns/op          196608 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-65536            6430            175863 ns/op         1372954 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-65536            8308            139352 ns/op          786432 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-262144           1411            899223 ns/op         5491595 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-262144           1154            967825 ns/op         3145728 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-1048576           351           3325487 ns/op        21887040 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-1048576           313           3942896 ns/op        12582912 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-4194304            85          13348969 ns/op        86763014 B/op          2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-4194304            98          11056438 ns/op        50331648 B/op          1 allocs/op
BenchmarkInsertSlice/BenchmarkIS-1-16777216           21          57495901 ns/op        348690919 B/op       2 allocs/op
BenchmarkInsertSlice/BenchmarkIS-2-16777216           28          41363541 ns/op        201326592 B/op        1 allocs/op
```

性能测试结果（注意内存次数分配）依旧证明了一次性分配足够的内存能显著提升性能。

至此，关于 slice 的一些容易让人困惑的细节以及一些典型操作的最佳实践两个部分已经阐述完毕。

简单小结，本文围绕 slice 介绍了两个方面的内容：

- 关于理解 slice 原理的一些关键点，这些点也相对容易让人困惑。比如 nil 切片和空切片，以及切片的扩容操作；
- 实际编程使用的涉及 slice 各种操作的最佳实践，包括 `for range`遍历切片、切片扩容、切片的克隆、往一个切片中插入另一个切片，删除切片的元素。

但值得注意的是，本文提供的 benchmark 都是最简单的情况，因此可能得出的结论并不具有普适性，即实际应用中不能一概而论。但通过这些测试结果，得出的几个基本性结论是值得思考的。有兴趣的读者可以亲自实践并拓展。『参考文献』部分列出文中涉及的资料。

文中实践源码在[这里](https://github.com/qqzeng/go-code-snippet/tree/master/slice-best-practice)。

## 参考文献

[1]. https://blog.golang.org/slices-intro
[2]. https://blog.golang.org/slices
[3]. https://go101.org/article
[4]. https://juejin.im/post/5bea58df6fb9a049f153bca8
[5]. [go slice growslice](https://jodezer.github.io/2017/05/golangSlice%E7%9A%84%E6%89%A9%E5%AE%B9%E8%A7%84%E5%88%99)
[6]. https://blog.golang.org/pprof
[7]. https://github.com/golang/go/wiki/SliceTricks