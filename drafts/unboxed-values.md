# Unboxed Values for Elm in WebAssembly

I've been intermittently working on a hobby project to compile Elm to WebAssembly. I didn't do much

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

