---
title: Elm in Wasm: Value Representations
published: false
description: 
tags: #elm, #webassembly
---



## TODO

- Do I want Union types (custom types) and Records in the intro bit? Should say I'm not doing them if I'm not doing them.
- Unicode: go there? Yeah kinda have to I think



__________



In my [last post][first-class-functions], I proposed some ideas for how Elm's first-class functions could work in WebAssembly.

This time, let's look at some of the other value types in Elm. What do the most fundamental value types look like? Can integers and floating-point numbers just be raw machine numbers, or do they need to have some kind of wrapper? How about collections like Lists, Tuples and Union types? And what about the big one - extensible records, how would they work?

We'll cover all of that in this post. Then in future posts we'll look at some more related topics like string encoding and effect types.

By the way, WebAssembly is still an MVP and won’t really be ready for Elm until it has garbage collection (GC), and probably also direct access to Web APIs (which depends on GC). The [GC extension][gc-ext] is still in ["feature proposal"][gc-proposal] stage (as of August 2018) so it could be a while before it's available. Also, I'm not part of the Elm core team.

[first-class-functions]: https://dev.to/briancarroll/elm-functions-in-webassembly-50ak
[gc-ext]: https://github.com/WebAssembly/design/issues/1079
[gc-proposal]: https://github.com/WebAssembly/gc/blob/master/proposals/gc/Overview.md



## Built-in types 

Let's start with the fundamentals: `Int`, `Float`, `Char`, `String`, `List` and `Tuple`. You probably learned these during your first day or two learning Elm. By themselves, they all have fairly standard byte-level implementations. But there are also some subtleties that we need to tackle.

The trickiest aspect of these types in Elm is that they are all members of [constrained type variables][guide-type-vars]. This is the mechanism that allows some functions like `++`, `+` and `>`, to work on *more than one, but not all* value types. (If you know Haskell, it's like a minimalistic version of typeclasses. If you don't, that's OK, I won't be referring to this again!)

[guide-type-vars]: https://guide.elm-lang.org/types/reading_types.html#constrained-type-variables

The table below lists the four constrained type variables, and which functions from the core libraries use them.

| **Type variable** | **Core library functions**                                   |
| ----------------- | ------------------------------------------------------------ |
| `appendable`      | `++`                                                         |
| `number`          | `+`, `-`, `*`, `/`, `^`, `negate`, `abs`, `clamp`            |
| `comparable`      | `compare`, `<`, `>`, `<=`, `>=`, `max`, `min`, `Dict.*`, `Set.*` |
| `compappend`      | (None)                                                       |

Here's a breakdown of which types belong to which type variables

|          | **number** | **comparable** | **appendable** | **compappend** |
| :------: | :--------: | :------------: | :------------: | :------------: |
|  `Int`   |     ✓      |       ✓        |                |                |
| `Float`  |     ✓      |       ✓        |                |                |
|  `Char`  |            |       ✓        |                |                |
| `String` |            |       ✓        |       ✓        |       ✓        |
|  `List`  |            |      ✓\*       |       ✓        |      ✓\*       |
| `Tuple`  |            |      ✓\*       |                |                |

\* Only if contents are comparable

Low-level functions that operate on these type variables need to be able to look at an Elm value at *runtime*, and decide which concrete type it is. For example the `compare` function (which is the basis for  `<`, `>`, `<=`, and `>=`) can accept five different types, and needs to run different low-level code for each.

Since Elm code can only pattern-match on values from the *same* type, this has to be done in Kernel code. Let's look at the JavaScript implementation, and then think about how a WebAssembly version might work. We'll focus on `comparable`, since it's the most general of the four.



## Comparable values in JavaScript 

Well Elm is open source, so we can just take a peek at the [Kernel code for `compare`][GitHub] to see how it's done. For the purposes of this article, we only care about how it tells the difference between different Elm types, so I've commented out everything else below.

[GitHub]: https://github.com/elm/core/blob/master/src/Elm/Kernel/Utils.js#L87-L120

```js
function _Utils_cmp(x, y, ord) // x and y will always have the same Elm type in a compiled program
{
	if (typeof x !== 'object') // True for JS numbers and strings (Elm Int, Float, and String)
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

Elm integers, floats and strings compile to JavaScript primitives and can be identified using JavaScript's `typeof` operator. This is not something we'll have available in WebAssembly, so we'll have to find another way.

The other Elm types are all represented as different object types. `Char` values are represented as [String objects][string-objects] and can be identified using the `instanceof` operator. Again, `instanceof` is not available in WebAssembly, and we need something else.

In the next part of the function we get a clue that when Elm values are represented as JS objects, they normally have a `$` property. This is set to different values for different types. It's `#2` or `#3` for Tuples, `[]` or `::` for Lists, and can take on various other values for custom types and records.

Aha! This `$` thing actually looks like something we can use! It's just an extra field that's bundled along with the value itself. We can easily find a way to represent that as bytes. In fact, when you compile Elm 0.19 with `--optimize`, the `$` property becomes a number! That's *really* easy to represent as bytes. It can just be a small header prepended to the value.

In fact, we can also add a header in front of the representations of Int, Float, Char and String. This seems like a fairly lightweight substitute for the `typeof` and `instanceof` operators used in JavaScript.

Let's see what that system looks like.



[string-objects]: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String#Distinction_between_string_primitives_and_String_objects



## Comparable values in WebAssembly

<img src='https://thepracticaldev.s3.amazonaws.com/i/n1n2vmjnnjmjquk9kglr.png' />

Using these representations, we can distinguish between any of the values that are members of `comparable`,  `appendable`, or`number`.

For example, to add two Elm `number`values, the algorithm would be:

- If constructor is 5 (`Float`)
  - Do floating-point addition (`f64.add`)
- else
  - Do integer addition (`i32.add`)

This is great because in WebAssembly, integer and floating-point addition are different [instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#numeric-instructions). We're not allowed to be ambiguous about it like in JavaScript.

Functions operating on `appendable` values can use similar techniques to distinguish String (7) from List (0 or 1) and execute different low-level code for each.



### Structural sharing

To have efficient immutable data structures, it's important that we do as much structural sharing as possible. The above implementations of List and Tuple allow for that by using pointers. For example when we copy a List, we'll just do a "shallow" copy, which means we don't recursively follow pointers. Instead, just copy the pointer as a literal value, so that the new list points at the same value as the old list.



## Alternatives for type information

I made an assumption above. I assumed that the type information needs to be attached to the *runtime* value representation. But just because that's how it's done in the current JavaScript implementation of Elm doesn't mean it's the only way to do it!

It's also possible for a compiler to generate several single-type implementations of polymorphic functions like `compare` or `++` or `List.map`. There's a compiler called [MLton][mlton] that does this for the Standard ML language, a close relative of Elm, and they call it "monomorphizing". Evan mentions it as one of the [potential projects][projects] for people interested in contributing to Elm.

For me personally, I felt that investigating WebAssembly was more than big enough for a hobby project, so I haven't researched this any further. It could be a really interesting project for someone else though!

[projects]: https://github.com/elm/projects#explore-monomorphizing-compilers
[mlton]: http://mlton.org/



## Alternatives for Integers

### Unboxing

In the proposed scheme above, all of the primitive values are "boxed". But lots of languages use "unboxed integers". For example, there is some good documentation online about the memory representations of values in both [OCaml][ocaml-values] and [Haskell][haskell-values], Elm's older sisters.

[ocaml-values]: https://v1.realworldocaml.org/v1/en/html/memory-representation-of-values.html
[haskell-values]: https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects

The idea is that since a pointer is usually the same size as an integer, it is not really necessary to put an integer in a "box" with a type header. It can be included directly in the relevant data structure.

![](C:\Users\brian\Code\wasm\blog\articles\boxed-unboxed.svg)

It's good for memory efficiency, but it does make the runtime implementation a bit more complicated! We now have two different ways of accessing elements inside any data structure. If it's an integer, the value is right there. But if it's anything else, we need to follow a pointer to find the value. Somehow we need to be able to tell which is which.

OCaml solves this by treating the least significant bit of every integer as a flag that says whether it's a pointer (0) or an integer value (1). The other 31 bits are used to hold the actual value. Pointers have to be aligned to 32-bit boundaries for most CPUs to work efficiently with them, so the lowest bit would be zero anyway. So they have 31-bit integers instead of 32, but I guess a range of +/-1 billion is enough for most common cases.

Haskell takes a different approach, defining one "info table" object in memory for every container type. The info table contains various information about values of that type, such as which fields are integers and which are pointers. This avoids losing one bit of range, at the cost of a small number of statically allocated objects in memory.

Either of these approaches could be used for Elm, although the info table could be a good place to put other pieces of type information. We'll see more on this later.

We're not going to get into Garbage Collection too much here, but the pointer/integer distinction is of course very important for that. Garbage Collectors do need to know which values are pointers. In Elm's case though, it probably makes most sense to wait for the platform to implement GC, so we won't get any deeper into that.



### 64-bit integers

WebAssembly has native support for 64-bit integers so it would be *possible* for all Elm integers to be 64 bits wide. Is it a good idea?

Currently Elm Integers are based on JavaScript numbers, which are sometimes floating-point and sometimes 32-integers, depending on what the browser's Just-In-Time compiler decides to do with them.

Bitwise operations on JS forces them to be treated as 32-bit integers, and Elm inherits this. Keeping compatibility with that could be an argument in favour of 32 bits.

Using 64-bit integers could complicate the 'unboxed integers' approach further, because pointers are always 32 bits wide in WebAssembly. If any element within a container type could be either 32 or 64 bits wide, that could complicate a lot of runtime code. However for boxed integers, there is really no extra complication at all.

My personal view is that 32 bit integers seem more than enough for most common cases in web front-ends, so 64-bit integers are not worth making the default. Perhaps Elm will eventually have a larger set of numerical types, and both options can be made available.



## String Encoding

That topic is big enough that I want to leave it for another post! It's very much intertwined with effects and the runtime implementation, because encoding matters when you're talking to the "outside world".



## Custom types

- Follow the example of List and Tuple
- JS uses an object with $ as constructor
- Except when it's an Enum. That becomes an integer.
- Constructors only need to be unique within a given type. Compiler ensures we never mix them up.



## Bool and Unit

`Bool` can be implemented just like a "custom type" with two constructors. (It's not "custom", it's built-in, but the only special thing about it is that the `if` keyword operates on it!) `True` and `False` can just be constant constructor values, defined once per program at a fixed memory location, to which all `Bool` values can point.

Alternatively, `True` and `False` could be unboxed as the integers 1 and 0. But we still need a way to create a `List Bool` if somebody wants to, so unboxing `Bool` requires the same machinery as unboxing `Int`. Indeed, this is how OCaml does it.

The Unit type (written as `()`) is just a "custom" type with a single constructor. Like `True` or `False`, its runtime representation can either be a fixed constant in memory that all `()` values point to, or an unboxed integer. OCaml uses an unboxed integer. (Zero would be the most intuitive choice, although in theory any integer would be equally valid!)



## Extensible Records

- Lit review
  - Haskell uses info tables for everything including records. It has extensible records. Recheck SPJ's paper.
    - http://web.archive.org/web/20160322051608/http://research.microsoft.com/en-us/um/people/simonpj/Haskell/records.html
    - Does code transformations, records -> tuples
    - Uses a typeclass with get and set methods, parameterised by the record type and the field type. So it's not a record it's an accessor thing. Actually I have no damn idea what it is. It must have the value in it though.
    - Each extensible record arg becomes a tuple of values of that typeclass 
    - They massively focus on the fact that Haskell previously didn't have non-positional parameters, and how they don't want to rewrite the compiler for it.
    - They're splitting up a record into its constituent parts at compile time, I think
    - 
  - OCaml stores records as arrays, which is what I'm basically proposing. Doesn't have field sets because it doesn't have extensibility. Just compiles the field names to offsets.
- Options
  - Carry it around with every value
  - Split into two objects, where FieldSet is a fixed thing outside managed heap. Like Haskell's info table.
- Consists of two linked values, the Record and the FieldSet.
  - The most important fact to realise is that in Elm, **it's not record _values_ that are extensible, it's function _type signatures_**. Every record value has a concrete type. In the example below, `myFunction` has an extensible type signature. It can operate on either Rec1 or Rec2, but all values are definitely Rec1 or definitely Rec2.
    - Rec1 = { someField : Int }
    - Rec2 = { someField : Int, otherField : Bool }
    - myFunction : { r | someField : Int } -> String
  - To turn field names into numerical values, we need a global table of field names. Thankfully, the compiler already generates this for Elm 0.19's optimisation features. The JS implementation compresses record fieldnames down to unique letter combinations, but we can easily modify that to unique numbers for WebAssembly.
  - FieldSet is a lookup table for each concrete record type, telling us the position in that record type of a particular fieldname.
- Value lookup works like this
  - myRecord.myField
  - myField is represented as an integer field number
  - myRecord has a pointer to its FieldSet
  - Lookup the field number in the FieldSet to get its offset
  - Using this offset, index into the record to find the field value.
- Accessors are just curried versions of a global function, containing the field number