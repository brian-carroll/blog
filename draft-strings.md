
## String Encoding

WebAssembly has no string primitives, so they have to be implemented at the byte level. That makes sense because different source languages targeting WebAssembly may have different string representations, and WebAssembly needs to support that. There are lots of ways to represent strings so let's review what other languages are doing.


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

### Summary

Most languages seem to grapple with a tradeoff between Unicode compliance, convenience, and memory density. It seems to be the best practice to present the application programmer with an API that treats strings as sequences of Unicode characters, while trying to have an underlying representation that is as dense as possible.

The modern *de facto* standard is UTF-8. Most recently-developed languages use it as their default encoding (Go, Rust, etc.).

For Elm, the main drawback of using UTF-8 is that it would break backward-compatibility with existing Elm apps, since `String.length` and other functions are built on top of JavaScript's UTF-16 representation. If we break existing apps, then how do we even test and debug our Wasm implementation? For this reason I don't think it's viable to change the string encoding in the _first version_ of the Wasm platform, but perhaps it can be done at some later stage.


