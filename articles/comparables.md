---
title: Elm in Wasm: Comparable values
published: false
description: 
tags: #elm, #webassembly
---



In my [last post][first-class-functions], I proposed some ideas for how Elm's first-class functions could work in WebAssembly.

This time, let's look at some of the other value types in Elm. What do the most fundamental value types look like? Can integers and floating-point numbers just be raw machine numbers, or do they need to have some kind of wrapper? How about collections like Lists, Tuples and Union types? And what about the big one - extensible records, how would they work?

We'll cover all of that in this post. Then in future posts we'll look at some more related topics like string encoding and effect types.

By the way, WebAssembly is still an MVP and won’t really be ready for Elm until it has garbage collection (GC), and probably also direct access to Web APIs (which depends on GC). The [GC extension][gc-ext] is still in ["feature proposal"][gc-proposal] stage (as of August 2018) so it could be a while before it's available. Also, I'm not part of the Elm core team.

[first-class-functions]: https://dev.to/briancarroll/elm-functions-in-webassembly-50ak
[gc-ext]: https://github.com/WebAssembly/design/issues/1079
[gc-proposal]: https://github.com/WebAssembly/gc/blob/master/proposals/gc/Overview.md



## Comparables, Appendables and Numbers

Let's start with the fundamentals: `Int`, `Float`, `Char`, `String`, `List` and `Tuple`. You probably learned these during your first day or two of Elm, and each of them has fairly straightforward byte level implementations. But there are also some subtleties that we need to tackle.

The trickiest aspect of these types in Elm is that they are all members of [constrained type variables][guide-type-vars]. This is the mechanism that allows some functions like `++`, `+` and `>`, to work on *more than one, but not all* value types.

[guide-type-vars]: https://guide.elm-lang.org/types/reading_types.html#constrained-type-variables

The table below lists the four constrained type variables, and which functions from the core libraries use them.

| **Type variable** | **Core library functions**                                   |
| ----------------- | ------------------------------------------------------------ |
| `appendable`      | `++`                                                         |
| `number`          | `+`, `-`, `*`, `/`, `^`, `negate`, `abs`, `clamp`            |
| `comparable`      | `compare`, `<`, `>`, `<=`, `>=`, `max`, `min`, `Dict.*`, `Set.*` |
| `compappend`      | (Not used)                                                   |

Here's a breakdown of which types belong to which type variables

|          | **number** | **comparable** | **appendable** | **compappend** |
| :------: | :--------: | :------------: | :------------: | :------------: |
|  `Int`   |     ✓      |       ✓        |                |                |
| `Float`  |     ✓      |       ✓        |                |                |
|  `Char`  |            |       ✓        |                |                |
| `String` |            |       ✓        |       ✓        |       ✓        |
|  `List`  |            |      ✓\*       |       ✓        |      ✓\*       |
| `Tuple`  |            |      ✓\*       |                |                |

\* Lists and Tuples are only comparable only if their contents are comparable



Low-level functions that operate on these type variables need to be able to look at an Elm value and decide which concrete type it is. For example the `compare` function (which is the basis for  `<`, `>`, `<=`, and `>=`) can accept five different types, and needs to run different low-level code for each.

There's no syntax to do that in Elm code - it's deliberately restricted to Kernel code. Let's look at the JavaScript implementation, and then think about how a WebAssembly version might work. We'll focus on `comparable`, since it covers the most types.



## Comparable values in JavaScript 

Well Elm is open source, so we can just take a peek at the [Kernel code for `compare`][GitHub] to see how it's done. For the purposes of this article, we only care about how it tells the difference between different Elm types, so I've commented out everything else below.

[GitHub]: https://github.com/elm/core/blob/master/src/Elm/Kernel/Utils.js#L87-L120

```js
function _Utils_cmp(x, y, ord) // x and y will always have the same Elm type in a compiled program
{
	if (typeof x !== 'object') // True for Elm Int, Float, and String
	{
        // ... compare using JS built-ins like `===` and `<`
	}

	if (x instanceof String) // True for Elm Char
	{
		// ... compare character values ...
	}
	
	if (x.$[0] === '#') // True for Elm Tuples ('#2' or '#3')
	{
		/* ... recursively compare tuples ...
			(we know we have a Tuple of comparables if the program even compiled)
         */
	}

    //  ... recursively compare lists (the only remaining comparable type)
}
```

Elm's `Int`, `Float` and `String` values correspond directly to JavaScript primitives and can be identified using JavaScript's `typeof` operator. This is not something we'll have available in WebAssembly, so we'll have to find another way to get the same kind of information.

The other Elm types are all represented as different object types. `Char` values are represented as [String objects][string-objects] and can be identified using the `instanceof` operator. Again, `instanceof` is not available in WebAssembly, and we need something else.

In the next part of the function we get a clue that when Elm values are represented as JS objects, they normally have a `$` property. This is set to different values for different types. It's `#2` or `#3` for Tuples, `[]` or `::` for Lists, and can take on various other values for custom types and records. In `--optimize` mode it becomes a number.

Now this is something we _can_ do in WebAssembly. The `$` property is just an extra piece of data that's bundled along with the value itself. We can add a "header" of extra bytes in front of the runtime representation of every value to carry the type information we need.

The table below shows an outline of what this could look like.

[string-objects]: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String#Distinction_between_string_primitives_and_String_objects



## Comparable values in WebAssembly

<img src='https://thepracticaldev.s3.amazonaws.com/i/n1n2vmjnnjmjquk9kglr.png' />

Using these representations, we can distinguish between any of the values that are members of `comparable`,  `appendable`, or`number`.

For example, to add two Elm `number`values, the algorithm would be:

- If tag is 5 (`Float`)
  - Do floating-point addition
- else
  - Do integer addition

We need this information because in WebAssembly, integer and floating-point addition are different [instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#numeric-instructions). We're not allowed to be ambiguous about it like in JavaScript.

Functions operating on `appendable` values can use similar techniques to distinguish String (7) from List (0 or 1) and execute different code branches for each.



### Structural sharing

To have efficient immutable data structures, it's important that we do as much structural sharing as possible. The above implementations of List and Tuple allow for that by using pointers. For example when we copy a List, we'll just do a "shallow" copy, without recursively following pointers. The pointer is copied literally, so we get a second pointer to the same value.





## Alternatives for type information

I made an assumption above. I assumed that the type information needs to be attached to the *runtime* value representation. But just because that's how it's done in the current JavaScript implementation of Elm doesn't mean it's the only way to do it!

It's also possible for a compiler to generate several single-type implementations of functions like `compare` or `++` and use the appropriate one for each individual call-site. That could eliminate the need for functions to distinguish between types at runtime.

There's a compiler called [MLton][mlton] that does this for the Standard ML language, a close relative of Elm, and they call it "monomorphizing". Evan mentions it as one of the [potential projects][projects] for people interested in contributing to Elm.

For me personally, I felt that investigating WebAssembly was more than big enough for a hobby project, so I haven't researched this any further. It could be a really interesting project for someone else though!

[projects]: https://github.com/elm/projects#explore-monomorphizing-compilers
[mlton]: http://mlton.org/

Note that even if monomorphizing gets rid of the need to check types at runtime, having headers for each value could still be useful. For example many Garbage Collectors rely on headers to understand how to traverse pointers, so if Elm had its own GC then it might need headers. (Elm probably won't have its own GC in WebAssembly, it'll use the browser's GC, but perhaps in some future server-side Elm.)



## Alternatives for Integers

### Unboxing

In the proposed scheme above, all of the primitive values are "boxed". But lots of languages use "unboxed integers". For example, there is some good documentation online about the memory representations of values in both [OCaml][ocaml-values] and [Haskell][haskell-values], Elm's older sisters.

The idea is that since a pointer is usually the same size as an integer, it is not really necessary to put an integer in a "box" with a type header. It can be included directly in the relevant data structure.

<img src="C:/Users/brian/Code/wasm/blog/articles/boxed-unboxed.svg" />

It's memory-efficient, and for any complex calculations with integers, it saves a lot of unboxing and re-boxing. But it also makes the runtime implementation a bit more difficult! We now have two possible ways of accessing elements inside a data structure. If it's an integer, the value is right there. But if it's anything else, we need to follow a pointer to find the value. And somehow we need to be able to tell which is which.

[OCaml][ocaml-values] solves this by reducing integers from 32 to 31 bits and using the last bit as a flag marking it as an unboxed integer (1) or a pointer to some other value (0).

[Haskell][haskell-values] does the same thing in a different way, defining one "info table" object in memory for every container type, including a set of single-bit flags for each parameter in the container, again marking which ones are unboxed integers.

[ocaml-values]: https://v1.realworldocaml.org/v1/en/html/memory-representation-of-values.html
[haskell-values]: https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects

Elm could use either of these unboxing approaches, but again, it would complicate the implementation so for my early prototyping project, I'm going to leave integers boxed for now.



### 64-bit integers

WebAssembly has native support for 64-bit integers so it would be possible for all Elm integers to be 64 bits wide. What are the pros and cons?

In a language implementation that uses unboxed integers, they are normally the same size as pointers. Otherwise all "container" data structures need to have different sizes depending on what they contain, which is a huge complexity cost. WebAssembly pointers are 32-bit, so if we want to allow unboxing, we have to use that size.

However with *boxed* integers it makes no difference. 64 and 32 bit values have about the same complexity. Elm's Bitwise package assumes 32 bits, and that's also how JavaScript bitwise operators work.

Anecdotally, I think usage of 64-bit integers in web development is pretty rare, except perhaps in some security related areas. For my prototyping I'm going with 32 for backward compatibility.





## String Encoding

WebAssembly has no string primitives, so they have to be implemented at the byte level. That makes sense because different source languages targeting WebAssembly may have different string representations, and WebAssembly needs to support that.

Above I showed the String body containing a sequence of bytes. There are various "encodings" of characters to bytes, and the modern *de facto* standard is UTF-8. Most recently-developed languages use it as their default encoding (Go, Rust, etc.).



### String representations in other languages

#### Python
The Python 3 Standard library has a Unicode type whose API is Unicode code points. But as per [PEP 393][pep-393], the underlying representation is a C structure that uses different storage formats depending on the maximum character value at creation time. It also holds metadata including length, a hash (for use in dictionary keys etc.), and the representation used.
[pep-393]: https://www.python.org/dev/peps/pep-0393/


#### Rust
Rust's [String][rust-string] consists of "a pointer to some bytes, a length, and a capacity. The pointer points to an internal buffer String uses to store its data. The length is the number of bytes currently stored in the buffer, and the capacity is the size of the buffer in bytes." The internal representation is UTF-8. There are APIs to convert between bytes and strings.
[rust-string]: https://doc.rust-lang.org/std/string/struct.String.html#representation


#### Java
Similarly, Java's [JEP 254][jep-254] describes multiple string representations depending on the maximum character value. However all the built-in representations use units of either 8 or 16 bits. There is no built-in Unicode support but there are libraries to support it. A detailed density analysis of different string types for Java can be found [here][java-string-density].
[jep-254]: http://openjdk.java.net/jeps/254
[java-string-density]: http://cr.openjdk.java.net/~shade/density/state-of-string-density-v1.txt


#### JavaScript
[This article][js-string-encoding] gives a detailed description of JavaScript's string representation. The summary is that the ECMAScript standard allows for engines to use either UTF-16 or UCS-2, which are similar but slightly different. Most engines use UTF-16.
[js-string-encoding]: https://mathiasbynens.be/notes/javascript-encoding


#### OCaml
OCaml's [String][ocaml-string] library is based on a sequence of one-byte characters. Unicode support doesn't seem to be strong.
[ocaml-string]: https://caml.inria.fr/pub/docs/manual-ocaml/libref/String.html

#### Summary

Most languages seem to grapple with a tradeoff between Unicode compliance, convenience, and memory density. It seems to be the best practice to present the application programmer with an API that treats strings as sequences of Unicode characters, while trying to have an underlying representation that is as dense as possible.

Most guides on this are targeted at application developers rather than language implementers. Best practice guides such as [The Unicode Book][unicode-book] and one from the [Flask][flask] web framework, advocate that programs should deal exclusively with Unicode characters internally, and only do encoding and decoding when dealing with external systems you can't control. In Elm this means the `String` package should provide functions to iterate over Unicode `Char`s and only Effect Managers should deal with encodings.

The internal memory representation should be something that facilitates this.

[flask]: http://flask.pocoo.org/docs/1.0/unicode/
[unicode-book]: https://unicodebook.readthedocs.io/good_practices.html



### Strings with Web APIs

Most of the browser's Web APIs use JavaScript Strings in UTF-16 format. For example `document.getElementById` expects its argument to be a  [DOMString][DOMString], which is UTF-16. `XmlHttpRequest` can deal with UTF-8 request and response bodies, but what about the string that specifies the URL? That's usually done with JavaScript strings. When the WebAssembly API comes out, will that require UTF-16 too? I can only suppose that the browser's underlying C++ implementation expects UTF-16, so wouldn't it present this to WebAssembly?

[DOMString]: https://developer.mozilla.org/en-US/docs/Web/API/DOMString

There's limited information at this stage on how the Web APIs will work with WebAssembly. There's an [overview of the proposal][host-bindings] but it seems to leave a lot up to browser vendors. It focuses on very low-level details and doesn't say anything about specific APIs like DOM or HTTP.

[host-bindings]: https://github.com/WebAssembly/host-bindings/blob/master/proposals/host-bindings/Overview.md

The general idea is that each Web API will be represented as a "table" of numbered functions. To send a string from Wasm to a browser API, the Wasm program writes it to its own block of memory and passes the address and length to one of the API functions. The Wasm memory block is visible to JavaScript as an ArrayBuffer and also visible to browser APIs, so it can be read from there.

When the browser sends a string to Wasm, calls an "exported" function in the Wasm program to tell it how much memory to allocate for that string. The Wasm program returns a memory address for the external code to write to, and gets a callback when it is done.

The proposal does actually mention UTF-8 encoded strings as one of the possible interface types. It also mentions ArrayBuffer and JSON. The JSON data is "parsed as if it were passed to `JSON.parse()`", which sort of implies UTF-16, I think. It remains to be seen how many Web APIs will actually provide the UTF-8 String argument type.



## Summary

I've outlined some possible byte-level representations for the most basic Elm data types. We haven't discussed Custom types or Records yet. That's for the next post!

We discussed some of the challenges presented by Elm's "constrained type variables" `comparable`,  `appendable`, and `number` needing some type information at runtime. We came up with a way of dealing with this using "boxed" values with headers. We looked at how some languages use unboxed representations for integers in particular, and briefly touched on how this could be done for Elm at the cost of some complexity.

We dipped our toes into the huge topic of string representation, with some particular considerations for the browser environment in general and WebAssembly in particular.



## Next up

I've been working away on this project for over 6 months at this stage and my blog posts are lagging way behind! Coming soon-ish:

- Records and Custom types (post nearly finished!)
- Garbage collection (Wasm built-in GC, custom collectors, immutable data and pure functions)
- Elm runtime (Process, Scheduler, and Platform kernel libraries)
- Code generation and intermediate languages (Rust, C, or direct-to-WebAssembly)

If you like you can check out some of my GitHub repos around this topic

- A [fork of the Elm compiler](https://github.com/brian-carroll/elm-compiler) that generates Wasm (from my Elm AST test data, not from real apps!)
- Some of the [Elm kernel libraries in C](https://github.com/brian-carroll/elm_c_wasm), compiled to Wasm.