Conversions between JS and Wasm are *everythying* but people don't think about.
It's the reason for rewriting loads of Kernel stuff
It has driven most of the work on the architecture stuff, and a few rewrites.


self-imposed limitations
- compiler changes are in code gen only
  - except what's strictly needed to enable the C output option
- aim to directly swap existing apps without modification
  - even if this means *not* fixing an existing problem that could otherwise be fixed

# What's involved in porting to Wasm

- The most important fact: no browser APIs in Wasm
  - spec in stage 1 for 3 years
  - needs a translation layer to convert bytes to JS value and vice versa
  - You get a speed-up from Wasm but you get a slow-down from the translation layer
  - The performance of the overall Wasm+JS system really depends on how well you can optimise that layer
    - Minimise the traffic back and forth, only encode/decode what you really need (this is hard)
    - Be fast with whatever you do send back and forth
    - Be very careful with memory managment. Wasm may need to hold long-lived references to JS values, and vice-versa. They each have their own GC's, and the JS one doesn't know about our Wasm one.

- Kernel code
  - Wasm only:
    - All pure modules (Basics, List, Result, Maybe, Bitwise, String, Char...)
    - This really needs an intermediate language, writing Wasm directly is not realistic
  - JS only:
    - Effectful modules (Browser, VirtualDom, Http...)
  - Wasm and JS:
    - Platform
    - Json
- Memory management
  - Normal GC stuff: allocation, stack tracing, mark/sweep, defragmentation, heap resizing
  - Wasm references to JS values
  - Mixed JS/Wasm call stacks
- JS/Wasm interop
  - Encode/decode between JS and Wasm representations of Elm values
  - Minimise unnecessary encoding and decoding
  - Deal with cross-language references
    - JS references to Wasm values, with a GC that can move addresses
      - full decoding
      - Process cache
    - Wasm references to JS values
      - use a heap, include it in GC
  - Special cases for Platform, Json, VirtualDom, and ports
  - App initialisation order: Wasm that depends on JS, and JS that depends on Wasm
  - Asynchronous Wasm loading and compilation
- Infrastructure
  - Reorganising libraries to have Elm, JS and C (or some low-level language)
  - Build system: compile both Elm and the intermediate language



# The Wrapper

## Why we need it

We can call JS functions from Wasm, but we can only pass numbers to them. But browser APIs like `document.createElement` and `fetch` expect strings and objects and various other things, not just numbers. That means we need a JavaScript wrapper function to act as a translation layer. The Wasm program can write a sequence of bytes into its ArrayBuffer, then pass the index and length of that sequence out to the JS wrapper function. The wrapper function will read the relevant bytes from the ArrayBuffer, construct the right strings and objects and stuff, and pass them to any JS function. On receiving the JS return value of some known shape, the wrapper can encode it back to bytes, asking the Wasm module to allocate a block of memory for it.

## Encoding values from JS to Wasm

Does dynamic type detection using `typeof` and knowledge of how Elm values are implemented in JavaScript.
There are special cases for the `Json` module and for various other Kernel modules

## Wasm references to JS values

We can also encode a _reference_ to a JavaScript value, rather than encoding the value itself. If we're passing JavaScript functions into Wasm, then this is really the only way to do it. But it can also be a good trick for JS values that are only doing a round-trip through Wasm.

The wrapper handles these Wasm-to-JS references by maintaining an array of the JS values. We can use the array index as an integer ID on the Wasm side, wrapped in a structure called `JsRef`. Whenever the Wasm module passes a `JsRef` back out to JavaScript, the wrapper can just look it up in the array.

Our Wasm Garbage Collector is integrated with this system, so when a Wasm `JsRef` is collected, the corresponding value gets removed from the array on the JavaScript side as well. (And because we've dropped it, the browser's GC might decide to collect it later, if it wants to.)

### Calling JS from Wasm

The `apply` operator is the code that implements Elm function calls in Wasm, and the first thing it does it to check whether the function being called is a `JsRef`. If so, it calls a helper function in the wrapper with the JsRef ID and the address of an arguments array. At that point all we need to do is translate the arguments to JS format, call the JS function, and encode the result back to bytes again.

### Calling Wasm from JS

Calling Wasm from JS is a little trickier. 
- push a Wasm stack frame
- encode all the args
- call the Wasm function with the encoded arguments
- decode the result as a JS value
- pop the stack frame

### Reading Closures out of Wasm to JS


## JS refs to Wasm values


## call stacks




# Results



# Future

## Roadmap to prod
- support *all* kernel modules that exist


## Possible perf improvements
- Wasm Virtual DOM with custom memory allocator
- compiler-inlined function calls (saturated)
- C inlining of Utils_apply
- modulo-cons
- unboxed ints (lots of work & semantic changes)
- Replace stack map with C stack tracing
