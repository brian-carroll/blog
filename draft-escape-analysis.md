# Escape analysis

- It would be nice to allocate some things as local variables in the C code
  - Could end up as registers (big benefit)
  - Could end up in the stack instead of the heap (similar time to allocate but saves on collection)

How to do it

- Escaping means
  - Being returned to the caller
  - Being passed into a called function, which might want to create some new value that points to it
- Like a mark algorithm except runtime is too late, needs to be compile time!
- Involves some kind of graph analysis on AST



|   | Size known at compile time?     |
| --- | --- |
| int | y |
| float | y |
| bool | y |
| char | y |
| string | **N** |
| cons | y |
| tuple2/3 | y |
| custom | y (need C typedef per Elm type) |
| record | y (need C typedef per Elm type) |



## Special case for numbers

- always generate numerical expressions as stack variables
- wrap the result before it escapes (passed to function or returned)
- special cases for Basics
- special cases for number-only user functions (different calling convention, use the stack)



## Booleans

maybe shouldn't have True and False as global constants

plain old values are easier to put on the stack/registers



## 64 bit

What if unboxed integers were 64 bits? Makes them bigger than Wasm pointers

So a collection would be of variable size depending on number of unboxed integers. Pain in the hole.



Or use 64 for pointers even though we only need 32. Do we really care?



Or what if you can only unbox integers that are < 2<sup>31</sup> ? Need to code gen logic to check that.