# Elm Wasm: Built-in types

In my [last post][fcf], I proposed some ideas for how Elm's first-class functions could work in WebAssembly in the future.

This time, let's look at some of the other value types in Elm. What do the most fundamental value types look like? Can integers and floating-point numbers just be raw machine numbers, or do they need to have some kind of wrapper? How about collections like Lists, Tuples and Union types? And what about the big one - extensible records, how would they work?

We'll cover all of that in this post. Then in future posts we'll look at some more related topics like string encoding and effect types.

By the way, WebAssembly is still an MVP and won’t really be ready for Elm until it has garbage collection (GC), and probably also direct access to Web APIs (which depends on GC). The [GC extension][gc] is still in ["feature proposal"][gc-proposal] stage (as of August 2018) so it could be a while before it's available. Also, I'm not part of the Elm core team.


[fcf]: https://dev.to/briancarroll/elm-functions-in-webassembly-50ak



## Built-in types 

Let's start with the fundamentals: `Int`, `Float`, `Char`, `String`, `List` and `Tuple`. You probably learned these during your first day or two learning Elm, but don't be deceived! There's actually a lot of subtlety under the covers here. We're going to look really closely at all this stuff that we normally take for granted, pick it all apart, and then piece it back together again.

Let's open up the REPL and take a close look at the type of the "append" operator, `++`.

```
$ elm repl
---- elm-repl 0.18.0 -----------------------------------------------------------
 :help for help, :exit to exit, more at <https://github.com/elm-lang/elm-repl>
--------------------------------------------------------------------------------
> "hello " ++ "world"
"hello world" : String
> [1.5, 2.5] ++ [3.5, 4.5]
[1.5,2.5,3.5,4.5] : List Float
> (++)
<function> : appendable -> appendable -> appendable
> 1 ++ 2
-- TYPE MISMATCH --------------------------------------------- repl-temp-000.elm
The left argument of (++) is causing a type mismatch.
3|   1 ++ 2
     ^
(++) is expecting the left argument to be a:
    appendable
But the left argument is:
    Float
Hint: Only strings, text, and lists are appendable.
> 
```

OK so firstly, Elm is telling us that `++` is a function. That shouldn't shock us too much. "It's just a function" is kind of Elm's thing. I mean OK, it *looks* different. The name `++` is a symbol rather than a normal word, and it goes in between its arguments rather than before them. But that's all just "syntax sugar" to make the source code nice. When it comes to how things *work* underneath, `++` is "just a function".

But check out that type signature. It operates on something called `appendable`. But when we actually *use* it, the REPL doesn't say it's an `appendable`! The first result is a `String` and the second is a `List Float`.

As usual with Elm, the clue is in the error message! Some types are `appendable` and others aren't.

## SuperTypes 

The Elm compiler defines a few "SuperTypes". (Other languages call them "typeclasses", but the Elm compiler source code calls them SuperTypes, so I'm going to go with that.) This is the mechanism that allows some functions like `++`, `+` and `>`, to work on *more than one but not all* value types.

The table below lists the three SuperTypes found in the core libraries, and which functions use them.

| **SuperType** | **Core library functions**                                   |
| ------------- | ------------------------------------------------------------ |
| `appendable`  | `++`                                                         |
| `number`      | `+`, `-`, `*`, `/`, `^`, `negate`, `abs`, `clamp`            |
| `comparable`  | `compare`, `<`, `>`, `<=`, `>=`, `max`, `min`, `Dict.*`, `Set.*` |

Here's a breakdown of which types belong to which SuperTypes

|          | **comparable** | **appendable** | **number** |
| :------: | :------------: | :------------: | :--------: |
|  `Int`   |       ✓        |                |     ✓      |
| `Float`  |       ✓        |                |     ✓      |
|  `Char`  |       ✓        |                |            |
| `String` |       ✓        |       ✓        |            |
|  `List`  |      ✓\*       |       ✓        |            |
| `Tuple`  |      ✓\*       |                |            |

\* Lists and tuples are only comparable if their contents are comparable

Low-level functions that operate on SuperTypes need to be able to look at an Elm value at *runtime*, and decide which type it is. For example the append function `++` needs to check whether it's working with Strings or Lists, and execute different low-level code for each, since they're different data structures.

We can't actually write code like that in Elm though, it has to be done in Kernel code. That's a deliberate choice in the language design. You can only use pattern matches to distinguish between values of the same type, not between values of different types.

How does this runtime type inspection work? What's happening in that Kernel code? And can we do it in WebAssembly?



## JavaScript representations 

Well we can just take a peek at the [Elm Kernel code on GitHub][GitHub] to see how it's done.

[GitHub]: https://github.com/elm-lang/core/blob/5.1.1/src/Native/Utils.js#L241-L276

```js
var Nil = { ctor: '[]' };

function Cons(hd, tl)
{
	return {
		ctor: '::',
		_0: hd,
		_1: tl
	};
}

function append(xs, ys)
{
	// append Strings
	if (typeof xs === 'string')
	{
		return xs + ys;
	}

	// append Lists
	if (xs.ctor === '[]')
	{
		return ys;
	}
    /* ... 'Cons' code ... */
```

Notice the JavaScript `typeof` operator in the `append` function. This is one of the techniques Elm uses to distinguish between the different types within a SuperType. It sometimes uses `instanceof` too.

And what's going on with `.ctor`? It's an abbreviation for 'constructor' and it exists on almost all of the Elm types that are represented as JavaScript objects. For example the List type has two constructors, `[]` (Nil) and `::` (Cons).

`ctor` is mostly used to distinguish constructors within a type, but in some places it's also used to distinguish between Elm types. For example if `ctor` is `::` then we know we're looking at Cons cell in a List, but we also know we're not looking at a tuple, whose `ctor` would begin with `_Tuple`. So there's both constructor and type information in `ctor`. This fact is used in the [implementation of `compare`](https://github.com/elm-lang/core/blob/5.1.1/src/Native/Utils.js#L165), which operates on lots of types.

So what have we learned that we can use when thinking about WebAssembly?

Well, our data structures for Elm values need to contain enough information to distinguish between

- types of the same SuperType
- constructors of the same type

However, in the case of WebAssembly we'll want to find a way of doing this with raw bytes as the `ctor`, rather than strings. (Strings are an abstraction we'll have to actually build ourselves from bytes.)



## Proposed WebAssembly representations

A proposed set of representations is depicted below. Each value amongst the basic types is prepended with a single byte that behaves similarly to the `ctor` field in JavaScript.

(Note that I'm only considering tuples of size 2 and 3 in this scheme. This could be extended later with an extra field, but 2 and 3 are the most common cases.)

<img src="./value-representations.png" />



Using these representations, we can distinguish between any of the values that are members of `comparable`,  `appendable`, or`number`.

For example, to add two Elm `number`values, the algorithm would be:

- If constructor is 5 (`Float`)
  - Do floating-point addition
- else
  - Do integer addition

This is great because in WebAssembly, integer and floating-point addition are different instructions. We're not allowed to be ambiguous about it like in JavaScript.

We can use similar algorithms to distinguish String (7) from List (0 or 1) for `appendable`.

And finally, the implementation of `compare` will handle all cases from 0-7, which is sufficient to cover all the possible values it can operate on. Although it will need to check recursively on lists and tuples.



-----



Great! This system works! We can implement all of Elm's basic types at the byte level, and we have a good approach to implement all of the relevant Kernel code in WebAssembly!

But wait, this is just one solution. Is it a good solution? Are there other ways? Are there tradeoffs?

Of course there are tradeoffs! Let's have a look at some of the main ones before we wrap up.



## What do other languages do differently?

OCaml is a great language to compare Elm with. It's from the same language family. And like Elm, but unlike Haskell, it's eagerly evaluated.



## What about Strings and Unicode and stuff?

That topic is big enough that I want to leave it for another post! It's very much intertwined with effects and the runtime implementation, because encoding matters when you're talking to the "outside world".



## What about monomorphizing?

"Monomorphizing", what a word! Just... gaze at it. Magnificent.

OK, so I made an assumption above. I assumed that the type information we discussed needs to be available in the value representation at runtime. But just because that's how it's done in the current JavaScript implementation of Elm doesn't mean it's the only way to do it! It's also possible to generate several implementations of each SuperType function, one for each type. There's a compiler called [MLton][mlton] that does this for the Standard ML language, and they call it "monomorphizing". Evan mentions it as one of the [potential projects][projects] for people interested in contributing to Elm.

For me personally, I felt that investigating WebAssembly was more than big enough for a hobby project, so I haven't gone down that road. If I took on that much, I'd  end up getting nothing done. So I'm sticking with the approach of having some type information available at runtime. If you want to have a go, I'm sure it would be interesting.

[projects]: https://github.com/elm/projects#explore-monomorphizing-compilers
[mlton]: http://mlton.org/

## 


