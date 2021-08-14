
Conversions between JS and Wasm are *everythying* but people don't think about.
It's the reason for rewriting loads of Kernel stuff
It has driven most of the work on the architecture stuff, and a few rewrites.


self-imposed limitations
- compiler changes are in code gen only
  - except what's strictly needed to enable the C output option
- aim to directly swap existing apps without modification
  - even if this means *not* fixing an existing problem that could otherwise be fixed

# What's involved in porting to Wasm

- Data structure design
  - See blog posts
- Wasm code gen
  - Cover the full Elm syntax tree
  - Generate two output files instead of one, for Wasm and JS
  - Deal with ambiguous type information available to code gen stage
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
