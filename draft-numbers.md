

## Alternatives for Integers

### Unboxing

In the proposed scheme above, all of the primitive values are "boxed". But lots of languages use "unboxed integers". For example, there is some good documentation online about the memory representations of values in both [OCaml][ocaml-values] and [Haskell][haskell-values], Elm's older sisters.

The idea is that since a pointer is usually the same size as an integer, it is not really necessary to put an integer in a "box" with a type header. It can be included directly in the relevant data structure.

<img src="../drafts/boxed-unboxed.svg" />

It's memory-efficient, and for any complex calculations with integers, it saves a lot of unboxing and re-boxing. But it also makes the runtime implementation a bit more difficult! We now have two possible ways of accessing elements inside a data structure. If it's an integer, the value is right there. But if it's anything else, we need to follow a pointer to find the value. And somehow we need to be able to tell which is which.

[OCaml][ocaml-values] solves this by reducing integers from 32 to 31 bits and using the last bit as a flag marking it as an unboxed integer (1) or a pointer to some other value (0).

[Haskell][haskell-values] does the same thing in a different way, defining one "info table" object in memory for every container type, including a set of single-bit flags for each parameter in the container, again marking which ones are unboxed integers.

[ocaml-values]: https://v1.realworldocaml.org/v1/en/html/memory-representation-of-values.html
[haskell-values]: https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects

Elm could use either of these unboxing approaches, but at this stage the focus is to get something up and running, so I'm going to have everything boxed for now. Unboxing can be a future optimisation.



### 64-bit integers

WebAssembly has native support for 64-bit integers so it would be possible for all Elm integers to be 64 bits wide. What are the pros and cons?

In a language implementation that uses unboxed integers, they are normally the same size as pointers. Otherwise all "container" data structures need to have different sizes depending on what they contain, which is a huge complexity cost. WebAssembly pointers are 32-bit, so if we want to allow unboxing, we have to use that size.

However with *boxed* integers it makes no difference. 64 and 32 bit values have about the same complexity. Elm's Bitwise package assumes 32 bits, and that's also how JavaScript bitwise operators work.

Anecdotally, I think usage of 64-bit integers in web development is pretty rare, except perhaps in some security related areas. For my prototyping I'm going with 32 for backward compatibility.


