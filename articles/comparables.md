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

    //  ... recursively compare lists ...
}
```

Elm's `Int`, `Float` and `String` values correspond directly to JavaScript primitives and can be identified using JavaScript's `typeof` operator. This is not something we'll have available in WebAssembly, so we'll have to find another way.

The other Elm types are all represented as different object types. `Char` values are represented as [String objects][string-objects] and can be identified using the `instanceof` operator. Again, `instanceof` is not available in WebAssembly, and we need something else.

In the next part of the function we get a clue that when Elm values are represented as JS objects, they normally have a `$` property. This is set to different values for different types. It's `#2` or `#3` for Tuples, `[]` or `::` for Lists, and can take on various other values for custom types and records.

Aha! This `$` thing gives us a clue how we can do this. It's just an extra piece of data that's bundled along with the value itself. In a byte-level implementation, we can make it a header that goes in front of the bytes for the value itself.

Let's see what that system looks like.

[string-objects]: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String#Distinction_between_string_primitives_and_String_objects



## Comparable values in WebAssembly

<img src='https://thepracticaldev.s3.amazonaws.com/i/n1n2vmjnnjmjquk9kglr.png' />

Using these representations, we can distinguish between any of the values that are members of `comparable`,  `appendable`, or`number`.

For example, to add two Elm `number`values, the algorithm would be:

- If tag is 5 (`Float`)
  - Do floating-point addition
- else
  - Do integer addition

This is great because in WebAssembly, integer and floating-point addition are different [instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#numeric-instructions). We're not allowed to be ambiguous about it like in JavaScript.

Functions operating on `appendable` values can use similar techniques to distinguish String (7) from List (0 or 1) and execute different code branches for each.



### Structural sharing

To have efficient immutable data structures, it's important that we do as much structural sharing as possible. The above implementations of List and Tuple allow for that by using pointers. For example when we copy a List, we'll just do a "shallow" copy, without recursively following pointers. The pointer is copied literally, so we get a second pointer to the same value.



## String Encoding

WebAssembly has no string primitives, so they have to be implemented at the byte level. That makes sense because different source languages targeting WebAssembly may have different string representations, and WebAssembly needs to support that.

Above I showed the String body containing a sequence of bytes. There are various "encodings" of characters to bytes, and the modern *de facto* standard is UTF-8. Most recently-developed languages use it as their default encoding (Go, Rust, etc.).

**But**... in the browser, there is a cost to using UTF-8. The Web APIs implement *all* strings as UTF-16. This includes some non-obvious things. For example, when you ask the browser to create a "div" in the DOM using `document.createElement('div')`, that `'div'` is a [DOMString](https://heycam.github.io/webidl/#idl-DOMString), which is UTF-16. Similarly, when Elm's `Http` module passes a URL to `XmlHttpRequest `, that URL must be a UTF-16 string. The list goes on.

In theory browser vendors *could* switch to supporting two encodings instead of one for [all 134 Web APIs](https://developer.mozilla.org/en-US/docs/Web/API), just to support WebAssembly. But I don't think that seems likely. It would make a lot more sense to simply provide access to the existing APIs from WebAssembly. Based on [Mozilla's blog articles on WebAssembly][mozilla-blog], the general approach seems to be to make WebAssembly look the same to the browser internals as JIT-compiled JavaScript, and I assume that would include encodings.

[mozilla-blog]: https://hacks.mozilla.org/category/webassembly/

I haven't found anything to 100% confirm this, but if I'm right, and Elm WebAssembly uses UTF-8 internally, the runtime will have to convert between UTF-8 and UTF-16 for every effect. It's not a complex conversion, but there's some performance cost.

Based on this, it's worth actually asking the question whether UTF-8 is the right choice in the browser. As far as I can tell, the main arguments for UTF-8 over UTF-16 are as follows:

1. UTF-8 is more compact since the representation of every character is either smaller or the same size. (Smaller strings may also be faster to iterate over, bringing some performance benefit.)
2. UTF-16 implementations have historically tended to be buggy
   - For example Elm currently inherits some problems from JavaScript's UTF-16 implementation. The example below shows that `String.length` counts 16-bit [code units][unicode-code-unit] but `String.foldl` iterates over [characters][unicode-char], which can be either one or two code units.

[unicode-code-unit]: http://unicode.org/glossary/#code_unit
[unicode-char]: http://unicode.org/glossary/#character

```elm
---- Elm 0.19.0 ----------------------------------------------------------------
Read <https://elm-lang.org/0.19.0/repl> to learn more: exit, help, imports, etc.
--------------------------------------------------------------------------------
> s = "🙈🙉🙊"
"🙈🙉🙊" : String
> String.length s
6 : Int
> String.foldl (\_ nchars -> nchars + 1) 0 s
3 : number
```

However, there's nothing that actually *prevents* a correct implementation of UTF-16. If we're starting from scratch on a new platform, we can just write a correct UTF-16 `String` library for Elm, and make things easier when communicating to the outside world via Web APIs.

Correcting bugs/inconsistencies in the `String` package would break backward compatibility with previous versions of Elm. The JavaScript kernel code would need to match the WebAssembly kernel code, assuming both options exist in a future compiler. That would make `String.length` slower - O(N) instead of O(1). But breaking backward compatibility in favour of correctness might be the right choice.

Maybe the conversion cost will be low enough that Elm can use UTF-8 internally without any real issues in practice. But at least, UTF-8 doesn't seem as obvious a choice in a browser context as it would be in another context. It seems like it needs some kind of benchmarking.

Now here's a [huge list of reasons](http://utf8everywhere.org/) why UTF-8 is the best thing in the world, which I'm adding here because people sometimes get a bit hot and bothered about character encodings. But in this case... browsers, y'know?

¯\\\_(ツ)\_/¯




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

<img src="./boxed-unboxed.svg" />

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

