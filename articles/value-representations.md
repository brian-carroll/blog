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

Aha! This `$` thing gives us a clue how we can do this. It's just an extra piece of data that's bundled along with the value itself. In a byte-level implementation, we can make it a "header" that goes in front of the bytes for the value itself.

Let's see what that system looks like.

[string-objects]: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String#Distinction_between_string_primitives_and_String_objects



## Comparable values in WebAssembly

<img src='https://thepracticaldev.s3.amazonaws.com/i/n1n2vmjnnjmjquk9kglr.png' />

Using these representations, we can distinguish between any of the values that are members of `comparable`,  `appendable`, or`number`.

For example, to add two Elm `number`values, the algorithm would be:

- If constructor is 5 (`Float`)
  - Do floating-point addition
- else
  - Do integer addition

This is great because in WebAssembly, integer and floating-point addition are different [instructions](https://webassembly.github.io/spec/core/syntax/instructions.html#numeric-instructions). We're not allowed to be ambiguous about it like in JavaScript.

Functions operating on `appendable` values can use similar techniques to distinguish String (7) from List (0 or 1) and execute different code branches for each.



### Structural sharing

To have efficient immutable data structures, it's important that we do as much structural sharing as possible. The above implementations of List and Tuple allow for that by using pointers. For example when we copy a List, we'll just do a "shallow" copy, without recursively following pointers. Instead, the pointer can just be copied literally, so we get a second pointer to the same value without copying the value itself.



## Alternatives for type information

I made an assumption above. I assumed that the type information needs to be attached to the *runtime* value representation. But just because that's how it's done in the current JavaScript implementation of Elm doesn't mean it's the only way to do it!

It's also possible for a compiler to generate several single-type implementations of polymorphic functions like `compare` or `++` or `List.map`. There's a compiler called [MLton][mlton] that does this for the Standard ML language, a close relative of Elm, and they call it "monomorphizing". Evan mentions it as one of the [potential projects][projects] for people interested in contributing to Elm.

For me personally, I felt that investigating WebAssembly was more than big enough for a hobby project, so I haven't researched this any further. It could be a really interesting project for someone else though!

[projects]: https://github.com/elm/projects#explore-monomorphizing-compilers
[mlton]: http://mlton.org/



## Alternatives for Integers

### Unboxing

In the proposed scheme above, all of the primitive values are "boxed". But lots of languages use "unboxed integers". For example, there is some good documentation online about the memory representations of values in both [OCaml][ocaml-values] and [Haskell][haskell-values], Elm's older sisters.

The idea is that since a pointer is usually the same size as an integer, it is not really necessary to put an integer in a "box" with a type header. It can be included directly in the relevant data structure.

![](C:\Users\brian\Code\wasm\blog\articles\boxed-unboxed.svg)

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

Above I showed the String body containing a sequence of bytes. There are various "encodings" of characters to bytes, and the modern standard is UTF-8. That would really be the first choice for any modern language.

**But**... in the browser, there is a cost to using UTF-8. The Web APIs implement *all* strings as UTF-16. We're not just talking about user-visible strings - the same applies to all parameters in all Web APIs. When you ask the browser to create a "div" in the DOM, that name "div" is a [DOMString](https://heycam.github.io/webidl/#idl-DOMString), which is UTF-16. (That's right, although HTML documents are most often encoded in UTF-8, the DOM is UTF-16.) Similarly, when Elm's `Http` module passes a URL to `XmlHttpRequest `, that URL must be a UTF-16 string. And if the call returns a JSON string, that's UTF-16 too.

All of Elm's input and output data flows through the browser, so if Elm uses UTF-8 internally, it will have to do conversions on every effect.

As far as I can tell, the main arguments for UTF-8 over UTF-16 are

1. UTF-8 is more compact since the representation of every character is either smaller or the same size
2. UTF-16 implementations have historically tended to be buggy
   - For example some "string length" functions, including those in JavaScript and Elm, count 16-bit words instead of actual *characters* (which can be 16 or 32 bits depending on the character).

```elm
---- Elm 0.19.0 ----------------------------------------------------------------
Read <https://elm-lang.org/0.19.0/repl> to learn more: exit, help, imports, etc.
--------------------------------------------------------------------------------
> s = "🙈🙉🙊"
"🙈🙉🙊" : String
> String.foldl (\_ nchars -> nchars + 1) 0 s
3 : number
> String.length s
6 : Int
```

However, there's nothing that actually *prevents* us doing a correct implementation of UTF-16. If we're starting from scratch on a new platform, we can just build a correct UTF-16 system for Elm, that correctly supports all Unicode characters, and make it simpler to talk to the Web APIs.

Now here's a [huge list of reasons](http://utf8everywhere.org/) why UTF-8 is the best thing in the world. Before you hardcore UTF-8 evangelists start bashing your keyboard at me in rage, please bear in mind that I've read that whole article and agree with everything it says. But... like... browsers, y'know? `¯\_(ツ)_/¯`

I know Elm will eventually run on servers too. And plenty of languages have some support for more than one character encoding. So I'm not sure where that leaves everything.

This is Evan's call and I don't envy it. I kind of want to nonchalantly drop the issue and back away slowly.



## Custom types

- Follow the example of List and Tuple
- JS uses an object with `$` as constructor
- Except when it's an Enum. That becomes an integer.
- Constructors only need to be unique within a given type. Compiler ensures we never mix them up.



## Bool and Unit

`Bool` can be implemented as if it were a custom type with two constructors. (It's not "custom", it's built-in, but the only special syntax for it is the `if` keyword!) `True` and `False` can be global constant values, defined once per program at a fixed memory location. This means that when putting a Bool into a data structure, it's just a pointer like any other value. For example in `(True, 3.14, "Hi")` , the tuple itself just contains three pointers.

Alternatively, `True` and `False` could be unboxed as the integers 1 and 0. But we still need a way to create a `List Bool`, so unboxing `Bool` requires the same machinery as unboxing `Int`. (In fact, that's how [OCaml][ocaml-values] implements Booleans.) As mentioned earlier, I don't intend to implement unboxing for now.

Similarly, the Unit type, written as `()`, is just a "custom" type with a single constructor. Again, its runtime representation can either be a global constant or an unboxed integer, and again I'm choosing a global constant to keep the implementation simple.



## Extensible Records

[Records](https://elm-lang.org/docs/records) are one of the most interesting parts of Elm's type system. When we're thinking about implementation, it's important to notice that only record *types* that are extensible. Individual *records* (the values themselves) are not extensible - they always have a definite set of fields that can never change, because everything is immutable. In other words, it's *polymorphism*.

For example, in this code, each function takes an extensible record type, which allows us to pass it a value of either type `Rec1` or `Rec2`. But all values are definitely `Rec1` or definitely `Rec2`.

```elm
type alias Rec1 = { myField : Int }
type alias Rec2 = { myField : Int, otherField : Bool }

sumMyField : List { r | myField : Int } -> Int
sumMyField recList =
	List.sum .myField recList   -- .myField is a function that can be passed around

incrementMyField : { r | myField : Int } -> r
incrementMyField r =
	{ r | myField = r.myField + 1 }  -- record update expression
```

The basic operators that work on extensible record types are "accessors" and "updates". In both cases we need to *find* the relevant field in a particular record before we can do anything with it. So there needs to be some mechanism to look up the position of a field within a record.

I've developed a working prototype in C that compiles to WebAssembly. There are three aspects to understand: fields, field sets and records values.

### Field IDs as integers

In Elm source code, a field is a human-friendly label for a parameter. But the 0.19 compiler is able to convert them to shortened names in the generated JavaScript, using its `--optimize` mode. To achieve this, it keeps track of all the field names in a program so that it can [generate unique shortened names][shortnames] for each.

[shortnames]:https://github.com/elm/compiler/blob/master/compiler/src/Generate/JavaScript/Mode.hs#L79-L106

For WebAssembly we need a way to represent fields as numbers rather than short names. But luckily it's relatively easy to adapt 0.19's name-shortening code to do that. We can just take the same set of field names and map them to integer field IDs instead.

### C data structures

```c
typedef struct {
    u32 size;
    u32 fields[];
} FieldSet;

typedef struct {
    Header header;
    FieldSet* fieldset;
    void* values[];
} Record;
```

The `FieldSet` data structure represents a record *type* in an Elm program. It's simply an array of integers that would be populated by the Elm compiler, containing the field IDs for that type. All records of the same type will point to a single shared `FieldSet`. The order of the fields doesn't matter, but it's useful to arrange them in ascending order because it makes searching for a specific field more efficient.

The `Record` structure contains a pointer to the corresponding `FieldSet` and an array of pointers to the parameter values. The value pointers are arranged in the same order as the field IDs in the `FieldSet`.

This arrangement of data structures enables fairly simple implementations of accessor functions and update expressions.

### Accessor functions

An accessor is an Elm function that does the following

- Given a field ID and a `Record`
- Find the index of the field ID in the record's `FieldSet`
- Return the value at the same index in the record's `values` array

An accessor function is created by partially applying the field ID to a Kernel function. This means it has exactly the same representation as any other Elm function and can be passed around as a value. You can check out the [source code][src-utils] or read my previous post on [Elm functions in Wasm][func-post] for more details.

[src-utils]: https://github.com/brian-carroll/elm_c_wasm/blob/master/src/kernel/utils.c
[func-post]: https://dev.to/briancarroll/elm-functions-in-webassembly-50ak



### Update expressions

A record update expression can be implemented using the following C function

```c
Record* record_update(Record* r, u32 n_updates, u32 fields[], void* values[]) {
    Record* r_new = clone(r);

    for (u32 i=0; i<n_updates; ++i) {
        u32 field_pos = fieldset_search(r_new->fieldset, fields[i]);
        r_new->values[field_pos] = values[i];
    }

    return r_new;
}
```

First we clone the record to create a new one. The for each field ID to be updated, we find its position in the `FieldSet`, and insert the corresponding value into the new record at that position. I've left out the details of `clone` and `fieldset_search` but they pretty much do what you'd expect. Feel free to take a look at the  [source code][src-utils].



### Records in similar languages

[OCaml][ocaml-values] has records, but not extensible record types. Without the polymorphism, a given field always refers to the same position in a record type, so all field names can safely be transformed into position offsets at compile time. In Elm we have to do that at runtime.

Haskell has extensible records, and the original paper on them can be [here][haskell-ext-records]. The focus is very much on trying to make the record system backwards-compatible with Haskell's pre-existing type system, which were positional rather than named. Unfortunately this means that most of their design decisions were driven by a constraint that Elm just doesn't have, so it wasn't directly useful.

[haskell-ext-records]: http://web.archive.org/web/20160322051608/http://research.microsoft.com/en-us/um/people/simonpj/Haskell/records.html

However the `FieldSet` concept is very much inspired by the [InfoTable][info-table] that exists for every type in a Haskell program.

[info-table]: https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects#InfoTables

