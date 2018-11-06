



## Headers

We've seen that types that belong to constrained type variables need a header tag to carry some type information. But it's actually helpful to add a header to *every* Elm value.

Having type tags on all values is useful for implementing the equality function `==`. Since Elm's definition of equality is recursive, the equality function needs to know how to access the children of each value. But different container types have different memory layouts, so we need to be able to distinguish them. (This kind of recursive traversal is also useful for Garbage Collection algorithms).

All Elm types can be covered with only 11 tags, which only requires 4 bits.

```c
typedef enum {
    Tag_Int,
    Tag_Float,
    Tag_Char,
    Tag_String,
    Tag_Nil,
    Tag_Cons,
    Tag_Tuple2,
    Tag_Tuple3,
    Tag_Custom,
    Tag_Record,
    Tag_Closure,
} Tag;
```

It's also helpful to add a `size` parameter to the header, indicating the size in memory of the value in a way that is independent of its type. This is useful for memory operations like cloning and garbage collection, as well as for testing equality of strings, custom type values, and records.

Finally if we want to implement a Garbage Collector we can also add some supplementary information in the header to mark whether values are "live" or not, or implement a [tri-color marking][tri-color] scheme. I'm not going to get into GC much, I just want to make sure my design is at least *compatible* with building a custom GC for Elm, even if that won't be necessary for [WebAssembly in the future][post-mvp-wasm], once it gets access to the browser's GC.

In my [prototype][src-types-h] I've chosen the following bit assignments for the header. They add up to 32 bits in total, which is convenient for memory layout.

|          | Bits | Description                                                  |
| -------- | ---- | ------------------------------------------------------------ |
| Tag      | 4    | Elm value type. See enum definition above                    |
| Size     | 26   | Payload size in units of 32-bit ints. Max value 2<sup>26</sup>-1 => 256MB |
| GC flags | 2    | Enough bits for tri-color marking                            |

[post-mvp-wasm]: https://hacks.mozilla.org/2018/10/webassemblys-post-mvp-future/
[tri-color]: https://en.wikipedia.org/wiki/Tracing_garbage_collection#Tri-color_marking
[src-types-h]: https://github.com/brian-carroll/elm_c_wasm/blob/master/src/kernel/types.h



## Extensible Records

[Records](https://elm-lang.org/docs/records) are one of the most interesting parts of Elm's type system. It's important to notice that only record *types* that are extensible. Individual *records* (the values themselves) are not extensible - they always have a definite set of fields that can never change, because everything is immutable. In other words, extensible record types are a form of polymorphism. (It's called *row polymorphism* if you want to look it up.)

For example, in this code, each function takes an extensible record type, which allows us to pass it a value of either type `Rec1` or `Rec2`. But values are either definitely `Rec1` or definitely `Rec2`.

```elm
type alias Rec1 = { myField : Int }
type alias Rec2 = { myField : Int, otherField : Bool }

sumMyField : List { r | myField : Int } -> Int
sumMyField recList =
	List.sum .myField recList   -- accessor .myField is an Elm function

incrementMyField : { r | myField : Int } -> r
incrementMyField r =
	{ r | myField = r.myField + 1 }  -- record update expression
```

The basic operators that work on extensible record types are accessor functions and update expressions. In both cases we need to *find* the relevant field in a particular record before we can do anything with it. So there needs to be some mechanism to look up the position of a field within a record.

I've developed a [working prototype][src-utils] of these features in C that compiles to WebAssembly, so I'll explain how that works and we'll look at some snippets of code along the way.

### Field IDs as integers

In Elm source code, a field is a human-friendly label for a parameter. But the 0.19 compiler is able to convert them to shortened names in the generated JavaScript, using its `--optimize` mode. To achieve this, it keeps track of all the field names in a program so that it can [generate unique shortened names][shortnames] for each.

[shortnames]: https://github.com/elm/compiler/blob/0.19.0/compiler/src/Generate/JavaScript/Mode.hs#L79

For WebAssembly we need a way to represent fields as numbers rather than short names. But luckily it's relatively easy to adapt 0.19's name-shortening code to do that. We can just take the same set of field names and map them to integer field IDs instead.

### Data structures

Let's see how we can represent records, using the following value as an example

```elm
type alias ExampleRecordType =
    { field123 : Int
    , field456 : Float
    }

example : ExampleRecordType
example =
    { field123 = 42
    , field456 = 3.14159
    }
```

This can be represented by the collection of low-level structures below. For illustration, we assume the compiler has converted the field name `field123` to the integer 123, and `field456` to 456. In this diagram, the headers are denoted as `(Elm type, payload size in integers)`. Floats are 64 bits. Integers and pointers are 32.

<img height="400px" src ="./records-fieldset-numbers-headers.svg" />

The `FieldSet` data structure is an array of integers with a size. It is a static piece of metadata about the record type `ExampleRecordType`. The Elm compiler would generate one instance for each record type, and populate it with the relevant integer field IDs. All records of the same type point to a single shared `FieldSet`. The `FieldSet` does not need a `header` field since it is never cloned or garbage-collected. It can only be accessed through a `Record` so we don't need to give it a type tag either.

The `Record` itself is a collection of pointers, referencing its `FieldSet` and its parameter values. The value pointers are arranged in the same order as the field IDs in the `FieldSet`, so that accessor functions and update expressions can easily find the value corresponding to a particular field ID.



### Accessor functions

An accessor for a particular field is an Elm function that does the following:

- For a predetermined field ID
  - Given a `Record`
  - Find the index of the field ID in the record's `FieldSet`
  - Return the value at the same index in the record's `values` array

In Elm, accessor functions only operate on a specific field name. The simplest way to implement this is to define a kernel function whose first argument is the field ID. In the generated code we can partially apply it to any field ID to get an accessor function for that field ID. This means the accessor has exactly the same representation as any other Elm function and can be passed around as a value.

A snippet from the C implementation is shown below. `fieldset_search` implements a binary search and returns the position of a given field ID in a `FieldSet`. If you're interested in more details, check out the [full source][src-utils], and perhaps read my previous post on [Elm functions in Wasm][first-class-functions].

```c
u32 index = fieldset_search(record->fieldset, field->value);
return record->values[index];
```

[src-utils]: https://github.com/brian-carroll/elm_c_wasm/blob/master/src/kernel/utils.c



### Update expressions

Elm update expressions look like this:

```elm
updatedRecord =
    { originalRecord
          | updatedField1 = newValue1
          , updatedField2 = newValue2
    }
```

In Elm 0.19 this is implemented by [a JavaScript function](https://github.com/elm/core/blob/1.0.0/src/Elm/Kernel/Utils.js#L151-L166) that clones the old record, and then updates each of the selected fields in the new record.

```js
function _Utils_update(oldRecord, updatedFields) {
	var newRecord = {};
	for (var key in oldRecord) {
		newRecord[key] = oldRecord[key];
	}
	for (var key in updatedFields) {
		newRecord[key] = updatedFields[key];
	}
	return newRecord;
}
```

We can do something similar in C as follows:

```c
Record* Utils_update(Record* r, u32 n_updates, u32 fields[], void* values[]) {
    Record* r_new = clone(r);
    for (u32 i=0; i<n_updates; ++i) {
        u32 field_pos = fieldset_search(r_new->fieldset, fields[i]);
        r_new->values[field_pos] = values[i];
    }
    return r_new;
}
```

I've chosen to use 3 separate parameters for the update information, which is not as neat as the single object in the JavaScript version. But in C syntax, constructing a record at the call-site is not as convenient as it is in JS, and seems a waste when we're just going to deconstruct immediately anyway.

I've left out the details of `clone` and `fieldset_search` but they pretty much do what you'd expect. Feel free to take a look at the [full source code][src-utils], which includes [tests][src-utils-test] that mimic generated code from the compiler.

[src-utils-test]: https://github.com/brian-carroll/elm_c_wasm/blob/master/src/kernel/utils_test.c



### Differences from JavaScript

JavaScript already has the concept of accessing a named field of an object, so current versions of Elm build on top of this.

C also has `structs` with named fields, and the C compiler can work out the relevant byte offsets to access them. But we can't use that to implement Elm accessors. It's not feasible to create a system where a single function can operate on *any* `struct` with a given field name regardless of its offset within that `struct`, and where the particular `struct` type is determined dynamically at runtime.



### Records in similar languages

[OCaml][ocaml-values] has records, but not extensible record types. That means a given field always refers to the same position in a record type, so there's no need to search for it at runtime. All field names can safely be transformed into position offsets at compile time.

Haskell has extensible records, and the original paper on them is [here][haskell-ext-records]. The focus is very much on trying to make the record system backwards-compatible with Haskell's pre-existing types, which were all positional rather than named. Unfortunately this means that most of their design decisions were driven by a constraint that Elm just doesn't have, so I didn't find it directly useful.

However the `FieldSet` concept is very much inspired by the [InfoTable][info-table] that is generated for every type in a Haskell program.

[haskell-ext-records]: http://web.archive.org/web/20160322051608/http://research.microsoft.com/en-us/um/people/simonpj/Haskell/records.html
[info-table]: https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects#InfoTables



## Custom types

Custom types work similarly to Records, but they're simpler because the parameters are positional rather than named. We don't need a separate `FieldSet` structure, and we don't need to search for the position of a parameter because it's known at compile time.

Let's take a simple example where one constructor takes no parameters and the other takes two.

```elm
type MyCustomType
  = Ctor0
  | Ctor1 Int Float

myCtor1 = Ctor1 42 3.14159
```

The data structures for this example are illustrated below.

<img height="267px" src="C:/Users/brian/Code/wasm/blog/articles/custom-types-headers.svg" />

Custom types need a type tag so that the equality function `==` can distinguish them from other Elm values.

The `Custom` structure needs a field `ctor` to identify with variant or constructor it came from. This value needs to be unique *within* a given type so that we can implement pattern matching. But there is no need for it to be unique within the *program* because the Elm compiler ensures that we can never compare or pattern-match values of different types.

Variants that take parameters need an associated constructor function, generated by the compiler.

Variants that take no parameters are static constants in the program. They have no constructor function and there only needs to be one instance of the value per program. For example the list `[Ctor0, Ctor0, Ctor0]` would just contain three pointers to the same memory address where `Ctor0` is located.



## Bool

`Bool` can be implemented as a custom type with two constructors. It's not exactly "custom", it's built-in, but it works the same way. (The only thing in Elm that treats `Bool` specially is the `if` expression.)

```elm
type Bool
	= True
	| False
```

`True` and `False` are constructors without any parameters, so they can be global constant values, defined once per program at a fixed memory location.

An alternative way to implement `Bool` would be to use the unboxed integers 1 and 0. But we'd still need a way to create a `List Bool`, and if `Bool` were unboxed, the list would contain integers instead of pointers.This means that unboxing `Bool` requires the same machinery as unboxing `Int`. (In fact, that's how [OCaml][ocaml-values] implements Booleans.) As mentioned previously, I don't intend to implement unboxed integers for now.

## Unit

The Unit type, written as `()`, is just a "custom" type with a single constructor. It's equivalent to the definition below, except that it has its own special symbol `()`.

```elm
type Unit = Unit
```

Again, its runtime representation can either be a global constant or an unboxed integer, and again I'm choosing the "boxed" version to keep the implementation simple.

