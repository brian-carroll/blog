# Elm values in WebAssembly

In my [last post][fcf], I proposed some ideas for how Elm's first-class functions could work in WebAssembly in the future.

This time, let's look at some of the other value types in Elm. What do the most fundamental value types look like? Can integers and floating-point numbers just be raw machine numbers, or do they need to have some kind of wrapper? How about collections like Lists, Tuples and Union types? And what about the big one - extensible records, how would they work?

We'll cover all of that in this post. Then in future posts we'll look at some more related topics like string encoding and effect types.

By the way, WebAssembly is still an MVP and won’t really be ready for Elm until it has garbage collection, and probably also access to the DOM and other Web APIs. The [GC extension][gc] is still in ["feature proposal"][gc-proposal] stage (as of August 2018) so it could be a while before it's available. This post is about something I see as a hobby project. I'm not part of the Elm core team.


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

As usual with Elm, the clue is in the error message! Some types are appendable and others aren't.

## SuperTypes

The Elm compiler defines a few "SuperTypes", sometimes known as "built-in typeclasses". This is the mechanism that allows some functions (like `++` and `+` and `>`) to work on *more than one* value type, but *not all* value types.

The table below lists the three SuperTypes found in the core libraries, and which functions use them.

| **SuperType** | **Core library functions**                                   |
| ------------- | ------------------------------------------------------------ |
| `appendable`  | `++`                                                         |
| `number`      | `+`, `-`, `*`, `/`, `^`, `negate`, `abs`, `clamp`            |
| `comparable`  | `compare`, `<`, `>`, `<=`, `>=`, `max`, `min`, `Dict.*`, `Set.*` |

The next table shows which types belong to which SuperTypes

|          | **comparable** | **appendable** | **number** |
| :------: | :------------: | :------------: | :--------: |
|  `Int`   |       ✓        |                |     ✓      |
| `Float`  |       ✓        |                |     ✓      |
|  `Char`  |       ✓        |                |            |
| `String` |       ✓        |       ✓        |            |
|  `List`  |      ✓\*       |       ✓        |            |
| `Tuple`  |      ✓\*       |                |            |

\* Lists and tuples are only comparable if their contents are comparable

The lowest-level functions that operate on SuperTypes need to be able to look at an Elm value at *runtime*, not compile time, and decide which type it is. For example the append function `++` would need to check whether it's working with Strings or Lists, and execute different low-level code for each, since they're different data structures.

We can't actually write code like that in Elm though, it has to be Kernel code. If we try to write Elm code to distinguish a String from a List, the compiler doesn't like it.

```elm
testIfStringOrList value =
    case value of
        "" ->
            "It's an empty string!"

        [] ->
            "It's an empty list!"

        _ ->
            "It's something else!"

```

```
-- TYPE MISMATCH --------------------------------- src/RuntimeTypeInspection.elm
Tag `[]` is causing problems in this pattern match.
9|         [] ->
            ^
The pattern matches things of type:
    List a
But the values it will actually be trying to match are:
    String
Detected errors in 1 module.
```

How does this runtime type inspection work? What's happening in that Kernel code? And can we do it in WebAssembly?



## JavaScript representations 

We can take a peek at the Kernel code on [GitHub][GitHub] to see how it's done.

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

In JavaScript we can use the built-in operator `typeof` to check if `xs` is a JavaScript string. Since Elm strings are impemented directly as JavaScript strings, this is just what we need. Nice! The `typeof` operator can't tell different object shapes apart, so this wouldn't help for other Elm types, but `typeof` *can* tell an object from a string, which is what we need here.

By the way, this code assumes that the surrounding program has been type-checked by the Elm compiler. Either `xs` and `ys` are both Strings or they're both Lists, because any other combination would have been rejected by the typechecker. When it comes to implementing the equivalent in WebAssembly, we should able to make some similar assumptions.

Under the "`// append Lists`" comment, there are two blocks of code to deal with the two different constructors of the `List` type, `Nil` and `Cons`. Remember that List is equivalent to a Union type like this:

````elm
type List a
	= Nil
	| Cons a (List a)
````



The important point here is that there are **two pieces of type information** being carried around in the value `x`. The `append` function needs both of them in order to know which block of code to run.

1. Check the *type*. This can't be done in Elm, only in Kernel code. We have to ask the JavaScript runtime to give us some of its internal information about the value.
2. Check the *constructor* within the type, if there's more than one, and execute different blocks of code to handle each constructor if necessary. Amongst the basic types we're looking at, `List` is the only one that has more than one constructor.



## WebAssembly representations

Choices

- Carry around the type/constructor info in the value
- Monomorphize
- Unbox Int, Float, Char
- Typeclass dictionary
- Type layout maps? are these relevant?

A proposed representation is depicted below. Each comparable value is prepended with an ID indicating its type and constructor.

<img src="https://thepracticaldev.s3.amazonaws.com/i/jk9sncx49brdjd0x2pok.png" />




