# Unboxed Values for Elm in WebAssembly

Over the last two years or so, I've been intermittently working on a hobby project to compile Elm to WebAssembly. My [last update](https://discourse.elm-lang.org/t/webassembly-compiler-update/5866) was in June 2020 showed a [working demo of TodoMVC](https://brian-carroll.github.io/elm_c_wasm/todo-mvc/). After that I was busy with other things in life for a while. But in the last few weeks I've been working on the project again, and thought it was time for another update.

## Getting more type information for code generation

Like most compilers, the Elm compiler is split into several stages, the last of which is the code generator. That's the part that transforms the internal representation of the program into a string of text to write to an output file.

The current compiler only outputs JavaScript, which doesn't need a lot of type information, so it and it wants to minimise the sizes of cached files in `elm-stuff/`, since file I/O is often the bottleneck for compilation speed on large projects.

![](C:\Users\brian\Code\wasm\blog\published\images\compiler-stages.png)

We can actually get surprisingly far outputting C without type information - I got TodoMVC working without it!

But there are 3 key reasons we want more type info:

- **Round-valued floats bug** Currently when we pass numbers from JS to Wasm, we have no reliable way to know whether they are `Int` or `Float`. For a round-valued `Float` like `3.0`, my JS-to-Wasm encoder will mistake it for an `Int` and pass the wrong bytes to the Wasm module, resulting in data corruption without any error thrown. This is a known bug and we need type info to fix it.
- **JS wrapper performance** The JavaScript wrapper around the Wasm module is quite slow at encoding values to bytes, because it is handwritten JS code that detects types at runtime, rather than generated code based on compile-time type information.
- **Generated code performance** Currently we can't implement very common performance optimisations that languages do, like "unboxed integers". Browsers will do it on hot code paths in JS so there's not much point in generating Wasm that doesn't.

Having looked into all of these issues, I think that if we can solve unboxed integers, it will also solve the "round-valued floats" bug, and make the byte encoders much easier too. So that's the first step, and the focus for the rest of this post.

## Unboxed integers

Container types like Tuples, Lists, Records and Custom types, normally have pointers to their "child" values. But a pointer is just an integer that represents a memory address! So if that "child" value is actually just an integer, then this indirection is a bit of a waste. We could "just" store the integer itself rather than the address, and save a lot of work from hopping around memory looking for things.

![](C:\Users\brian\Code\wasm\blog\published\images\unboxed.png)

This trick only really works because `Int` is the same size as a pointer. It also works for smaller types like `Bool` and `Char`. But in a tuple like `(String, List Float)`, it won't work. Strings and Lists are too big to fit. We just put pointers in the Tuple instead, which also means we can share the same String and List with other data structures, without making new copies. We just copy the pointer, not the whole structure.

## Header flags

So now things are more complicated because we have a two-tier system - some "child" values are pointers and some are just numbers.

This creates a problem for the [Garbage Collector](https://github.com/brian-carroll/elm_c_wasm/blob/master/docs/gc.md). If it can't tell which numbers are pointers and which are just numbers, then it can't figure out which values are alive and which are garbage. So we need to add some extra information to the header.

In the case of the 2-tuple, we need two bits to indicate whether each child is boxed (a pointer) or unboxed (an integer). For Records and Custom types we may need more bits. 32 bits should be enough for most practical usage. Beyond that, things get more complicated. For example in Haskell, for large structures, this information is actually stored in a [separate data structure](https://gitlab.haskell.org/ghc/ghc/-/wikis/commentary/rts/storage/heap-objects#bitmap-layout).

## Type info for header flags

So how do we get enough info to generate these flags?

I have been looking into unboxed ints. I wanted to give you an update on it and also ask for some advice!

There are two key pieces to it. The first is going well. The second is hard and I'm a bit stuck!

1) Unboxed flags for containers

All of my "container" data structures (List, Tuple, Custom, Record and Closure) need to have bit flags saying which of their children are boxed and which are unboxed. Then the GC knows which values are pointers that it needs to trace.

To do that, I need type annotations for the nodes where each of those structures is constructed. After that, the flags can just get copied at other nodes. So it's only a subset of the AST.

I was able to get the solver to insert the types of the relevant nodes into the `annotations`, along with the top-level variables. So that's going well.

(I ended up generating unique variable names for the relevant nodes, based on their `Region`. That seems good enough to get up and running, though may need cleaning up later.)


2) SuperTypes

The SuperTypes `number` and `comparable` are a particular challenge with unboxing. `Int` and `Char` are unboxed, but `Float`, `String`, `Tuple` and `List` are boxed.

If a function has a SuperType in its signature, we can only know the concrete type at runtime. Haskell does this by creating dictionaries of functions that exist at runtime and passing them around.

Elm will also need some runtime type info, although a dictionary is over-the-top for us. Just a set of integer "type IDs" will do, representing the current types assigned to each of the SuperTypes.


All of the Basics math operators have `number` in their type signature, so to implement them at a low level we need to know whether it's in an Int or Float context.

In my current boxed-only implementation, Elm Int and Float are implemented as data structures that have a header containing a type tag. Functions like `Basics.add` check the type tag at runtime and branch to either an int or float operation. That's not good for performance.

In cases where the type is known at compile time, we can again get annotations from the type solver and eliminate the branch.

But inside a function with `number` in its signature, we still need to branch at runtime. But unboxed ints don't have headers with type tags.

```elm
addNumbers : number -> number -> number
addNumbers a b =
  a + b  -- could be integer or float addition, depending on who calls it at runtime
```

To generate assembly code for `addNumbers`, we need some kind of runtime representation for the value of `number`. Perhaps a Boolean flag indicating whether it is `Int` or `Float` for the current call.
We can write some assembly-level pseudocode for the body of `addNumbers` like this:

- if the runtime flag for `number` equals `Int`, then:
  > _interpreting a & b as integer values..._
  - execute "integer add" instruction on a & b
  - return the resulting integer
- else:
  > _interpreting a & b as memory addresses of ElmFloat data structures..._
  - load the inner value of `a` (at a known offset from the starting address of the structure)
  - load the inner value of `b`
  - execute "float add" instruction
  - pass the result to the constructor for ElmFloat (creating a new value on the heap)
  - return a pointer to the new ElmFloat

Whenever we call `addNumbers` we need to set the value of `number`. Here's a contrived example:

```elm
contrivedExample : Int -> Float -> (Int, Float)
contrivedExample myInt myFloat =
  ( addNumbers myInt myInt
  , addNumbers myFloat myFloat
  )
```

The pseudocode for this would be
- call `addNumbers` with number=Int, a=myInt, b=myInt
- call `addNumbers` with number=Float, a=myFloat, b=myFloat
- call constructor for Tuple2
- return

The value of `number` could be implemented as an extra argument to the function, or as a global that gets set before a call (and probably restored afterwards).

Let's look at a similar function with `Int` instead of `number` in the type signature
```elm
addInts : Int -> Int -> Int
addInts a b =
  a + b  -- always integer addition
```

This time the low-level pseudocode doesn't need any branching, and doesn't need to receive any value for `number`
- execute "integer add" instruction on a & b
- return the resulting integer



Haskell does this by inserting dictionaries for typeclasses. But Elm only has a few typeclasses, so I think a few bits will be enough.

