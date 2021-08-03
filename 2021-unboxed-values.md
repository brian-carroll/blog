# Elm compiler changes for  WebAssembly

**Disclaimer:** *This post is about planned changes to my [unofficial fork](https://github.com/brian-carroll/elm-compiler) of the [Elm compiler](https://github.com/elm/compiler). I don't know anything about any plans for the official compiler!*

Over the last two years or so, I've been working on compiling Elm to WebAssembly, as a hobby project to learn about how language runtimes and compilers work. My [last update](https://discourse.elm-lang.org/t/webassembly-compiler-update/5866) was in June 2020 showed a [working demo of TodoMVC](https://brian-carroll.github.io/elm_c_wasm/todo-mvc/). After that I got busy with other things in life for a while. But in the last few weeks I've been working on it again, and thought I'd share my plans for the next steps.



## More Types for Code Gen

Like most compilers, the Elm compiler is split into several stages, the last of which is the code generator. That's what transforms the compiler's internal data structures into a string of text to write to the output file. I've written a new code generator for Wasm, and made some demos with it, which is a great start.

Now, to take things to the next step, there are changes needed in some other parts of the compiler too. In particular, Wasm really needs more type information than JavaScript does. In this post we'll explore what information it needs, what it can do with it, and what changes are needed.

The input to the code generator is the Optimized version of Elm's [Abstract Syntax Tree](https://en.wikipedia.org/wiki/Abstract_syntax_tree). One of the main ways in which it's "optimized" is that it has all unnecessary data stripped from it. This is the data that's stored in the cache files at `elm-stuff/*.elmo`, and compilation speed on large projects is dominated by reading those files. So although we may need extra information in the AST for Wasm, we also need to be careful not to bloat the cache files too much. We don't want to slow things down for JavaScript output.

![](C:\Users\brian\Code\wasm\blog\published\images\compiler-stages.png)

We can actually get surprisingly far outputting C without type information - I got TodoMVC working without it!

Here are the key things we can do with more type information:

- **Improve the JS-Wasm wrapper** Some of Elm's runtime needs to be in JS, because Wasm can't yet access browser APIs like DOM and HTTP. We have a [JS-Wasm wrapper](https://github.com/brian-carroll/elm_c_wasm/blob/master/docs/wrapper.md) that encodes and decodes values crossing over that boundary, but we can make it better using types.
  - **Fix `Float` encoding bug** When we pass a `number` from JS to Wasm, the encoder doesn't have the type info to know whether Elm expects an `Int` or `Float`. The current hack is to just guess that all round numbers are `Int`. But if a `Float` happens to have a round value, we will write the wrong bytes. For example if we write the bytes for the integer `3`, but interpret them as a float, we get `1.4822e-323`! That's obviously a blocker for real-world usage.
  - **Auto-generate byte encoders & decoders** The wrapper's encoding and decoding are quite slow, partly because it detects types at runtime. We should replace it with generated code based on type information. The standard compiler already does similar things for `port`s in some cases.
- **Implement unboxed integers** Currently the Wasm representation of Elm `Int` values is an object (or "box") with the actual integer value inside it. That made things easier to implement in the first version. But getting rid of the "box" would speed up all integer-related code. This is one of the best-known language runtime optimisations, and it's use used in Haskell, OCaml, JavaScript JIT compilers, Java, .NET, etc.
- **Eliminate branching on SuperTypes** Some operators and functions in Elm's core libraries have "SuperTypes" in their signatures. For example +, `>`, and `++`,  operate on `number`, `comparable`, and `appendable` respectively. My current implementation for `+` checks the header of its first argument to see if it's `Int` or `Float`, then branches to either an integer or float addition. But in a lot of cases we could eliminate the branch if we had more type information.



Having looked into all of these issues, I think that if we can solve unboxed integers, we will have enough information to make the other two issues relatively easy.

So the first step is to implement unboxed integers. That's the focus of the rest of this post.



## Unboxed integers

Byte-level implementations of "container" types like Tuples, Lists, Records and Custom types, normally use pointers to reference their child values. But if the child value is just an integer, this system is a bit wasteful. A pointer is just an integer that represents a memory address, so we're storing one integer to refer to the location of another integer!

If we could "just" store the integer itself rather than the address, it would save a lot of work from hopping around memory looking for things.

![](C:\Users\brian\Code\wasm\blog\published\images\unboxed.png)

The hard part is that we now have two different ways of doing things. Our unboxing trick only works for values that are the same size as a pointer, or smaller. That's `Int`, `Bool`, `Char`  and maybe a few others.

But for something like `(String, List Float)`, this trick doesn't work well. Strings and Lists are too big. It's better to store them separately and put pointers in the Tuple. That way we can also share the same String and List with other data structures without making new copies every time.

So the downside of this scheme is that now we have two different ways to do things. Some things are "boxed" (big enough to use pointers) and other things are "unboxed" (small enough to store the value directly).



## Unboxing flags

This creates a problem for the [Garbage Collector](https://github.com/brian-carroll/elm_c_wasm/blob/master/docs/gc.md). A number that refers to an address looks the same as a number that's... just a number! The GC needs a way to tell which numbers are pointers and which are just numbers, then it can't figure out which values are alive and which are garbage.

There are two main ways to do this

### Least significant bit flag
If we don't mind reducing the size of an `Int` to 31 bits instead of 32, we can use the lowest bit as the "unboxed" flag. This is [what OCaml does](https://dev.realworldocaml.org/runtime-memory-layout.html) for all integers, and [what v8 does](https://github.com/thlorenz/v8-perf/blob/master/data-types.md#efficiently-representing-values-and-tagging) for JavaScript numbers that it decides are "small integers".

This technique takes advantage of the fact that pointers are always going to be even-numbered addresses anyway. It's standard practice to align everything in memory to 32-bit or 64-bit address boundaries, because the hardware works more efficiently that way.

It doesn't require any type information from the compiler. But the kernel code in core libraries needs to implement code for bit shifting and masking.

### Container header flags

Another option is to put flags in the headers of container types, indicating which children are boxed and which are unboxed. Up to 32 bits should be enough for most cases, since few values have more than 32 direct children. But it might not be sufficient for particularly large Records or Custom types.

For larger containers, we could have every value point to an "info table" for its type, and put the unboxing flags there. This is [what the GHC runtime does](https://gitlab.haskell.org/ghc/ghc/-/wikis/commentary/rts/storage/heap-objects#info-tables) in Haskell. Since there's only one per type, it could have a lot of information without adding space to every individual value. We already have something a bit similar in the current WebAssembly implementation. Every Record already points to a constant `FieldGroup` structure indicating what fields it has.

The advantage of this approach is that we get to keep all 32 bits of our `Int`. The drawback is that it's more complex to implement than the LSB flag.

It requires extra type annotations anywhere a container value is constructed, without being copied. In the Canonical AST that would be 4 out of 28 expression constructors (`List`, `Lambda`, `Record` and `Tuple`). We already have enough type information for custom type constructors since they are top-level values.



## SuperType branches

- How do we do it as little as possible at runtime? What compiler types do we need for that?
- When we *do* need to branch at runtime, how do we select the branch?

### Least significant bit flag



### Header  type tags



### Runtime representation of SuperTypes







```
How far can I get with LSB flags plus compile-time info?
-------------------------------------------------------
Inside functions with `number` in the signature, I use the LSB instead of the runtime SuperType
For number calls that have a concrete type, I don't need either runtime SuperType _or_ LSB flags

In the case of comparable...
int    unboxed
float  boxed
char   boxed for now (UTF-16 needs the full 32 bits! Unicode value is 21 bits, but then Char 'compares' differently than String)
string boxed
list   boxed
tuple  boxed

So I need type tags if I don't have runtime SuperTypes.
But then I'm saving space on header flags
Maybe I only need type tags for boxed values? Then it only really needs 2 bits... and I save a lot of space on flags...

What about comparables with completely solved types?
someBool = myString > myOtherString
In this case I want type info to skip the runtime check on type tag or LSB.


```



| Technique         | Benefit                                                      |
| ----------------- | ------------------------------------------------------------ |
| Runtime SuperType | Distinguish `number`, `comparable`, and `appendable` types at runtime |
| Unbox flags       | Help GC tracing                                              |
| ----------------- | ------------------------------------------------------------ |
| LSB flag          | Help GC tracing, distinguish `number` types at runtime, distinguish boxed/unboxed `comparable` at runtime |
| Type tag          | Distinguish boxed `comparable` and `appendable` types at runtime |

In both schemes, we should only have to identify types at runtime inside of functions that have a SuperType in their signature.

The first scheme requires a lot more compiler support.

In the LSB flag & type tag scheme, what compiler support do we need?

**Just enough to eliminate branches on calls to Basics SuperType ops:** then we need types for those calls only. Args and return values. Need to know the value of the SuperType for that call. Just for simple types. If there's nested types for `comparable`, give up and figure it out at runtime.





## JS Wrapper issue

- Identify calls to JS functions
  - We already do this bit
- Need to

  - Get full type info for the call
  - Generate encoder/decoder
  - Handle Closures (already do this dynamically)
- Most Kernel values have Elm aliases with type annotations
  - Just 4 exceptions in core. Others in Http, Bytes, etc.
    - If Wasm was official what would we do? Just write the type annotation in the source for all of them! Don't have to export it!
    - Could modify `Constrain.Expression.constrain` to have a Bool arg that says `isTopLevel` and skip the `CLet` in that case.
    - Maybe just throw if there's no type annotation, or make a special case in the compiler
    - Or have a slower dynamic decoder
  - Generate
    - Global
      - We already have a "top level expression" generation function `Generate.C.addDef`
      - In the `VarKernel` case for that, look up the annotation _for the definition_ and generate the encoder/decoder stuff
      - The encoder is in the name of the `VarKernel`, not its Elm alias
    - Expression
      - References to the `VarKernel` just get generated as calls to the Wasm stand-in
- Complication: type variables
  - Maybe in this case insert a CLet to find out the specific type? Does that work? Can't remember



### How would it work in a real example?

```elm
-- user code
Http.get
    { url = "./assets/data.json"
    , expect = Http.expectJson JsonLoaded JD.string
    }
-- package Elm code, where `command` is JS
request
  : { method : String
    , headers : List Header
    , url : String
    , body : Body
    , expect : Expect msg
    , timeout : Maybe Float
    , tracker : Maybe String
    }
  -> Cmd msg
request r =
  command <| Request <|                       -- command is a JS function
    { method = r.method
    , headers = r.headers
    , url = r.url
    , body = r.body
    , expect = r.expect
    , timeout = r.timeout
    , tracker = r.tracker
    , allowCookiesFromOtherDomains = False
    }
```

So the structure of the type here is

- Custom type constructor `Request` from `Http.MyCmd`
  - Record with 8 fields, first one is a String, blah
  - has a `msg` type variable... forget that for now
- So I want a constructor function for a `Request` on the JS side that takes an address for a Wasm `Request`
- This JS function already knows what fields I'm going to want in the Record, it **doesn't have to look anything up**
- Should also know the order of them in the Wasm Record and match everything up (it's alphabetical)

Decoding a `Cmd`

```js
function _Platform_leaf(home)
{
	return function(value)
	{
		return {
			$: __2_LEAF,
			__home: home,
			__value: value
		};
	};
}

// Http.command is an alias for Platform.leaf('Http'), which is a partially applied constructor for Cmd where the first arg is 'home'
// So when we see Platform.leaf in C we could call a C constructor for Cmd, then have a Cmd decoder
function decodeCmd(addr8) {
    var index32 = addr8 >> 2;
    switch (_Utils_mem32[index32+1]) {
            
    }
}
function decodeCall$elm$http$Http$command() {

}

function decodeAny(addr8) {
  var index32 = addr8 >> 2;
  // check type tag
  // if List, first detect type, then select a decoder, then decode the list with the right decoder
  // if Custom, check upper bits of ctor to get the whole type, then call the decoder for that
  // For records... dunno
  // maybe need to gather type info on Record nodes, and put a type index (decoder index) into the Record struct itself
}

function decodeCustom$elm$http$Http$MyCmd(addr8) {
  var index32 = addr8 >> 2;
  switch (_Utils_mem32[index32+1]) {
    case 0:
      return $elm$http$Http$Cancel(
         decodeString(_Utils_mem32[index32+2])
      );
    case 1:
      return $elm$http$Http$Request(
        decodeRecord_allowCookiesFromOtherDomains_body_expect_headers_method_timeout_tracker_url(
           _Utils_mem32[index32+2]
        )
      );
    default:
      throw new Error('Corrupt WebAssembly memory at 0x' + addr8.toString(16));
  }
}
// hang on, just because we know the field names doesn't mean we know what's in them...
// so this is the wrong name, probably need to call it decodeRecord4625
// why not both... add a numeric index on the end as a sort of hash of the field types
function decodeRecord_allowCookiesFromOtherDomains_body_expect_headers_method_timeout_tracker_url(addr8) {
  var index32 = addr8 >> 2;
  return {
    allowCookiesFromOtherDomains: decodeBool(_Utils_mem32[index32+3]),
    body: decodeBody(_Utils_mem32[index32+4]),
    expect: decodeExpect(decodeAny, _Utils_mem32[index32+5]),
    headers: decodeList(decodeHeader, _Utils_mem32[index32+6]),
    method: decodeString(_Utils_mem32[index32+7]),
    timeout: decodeCustom$elm$core$Maybe$Maybe(decodeFloat, _Utils_mem32[index32+8]),
    tracker: decodeCustom$elm$core$Maybe$Maybe(decodeString, _Utils_mem32[index32+9]),
    url: decodeString(_Utils_mem32[index32+10]),
  }
}
```



Some of the calls are to Platform.leaf and will become `Cmd`s or `Sub`s.

The rest are just in JS for "perf" (which we are going to make 10x worse)

Example

```elm
isSubChar : (Char -> Bool) -> Int -> String -> Int
isSubChar =
  Elm.Kernel.Parser.isSubChar
```









## Type info for unboxed flags

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

