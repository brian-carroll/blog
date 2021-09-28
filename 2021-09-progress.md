# Porting Elm to WebAssembly

For a few years now, on and off, I've been working on an unofficial port of the Elm language to WebAssembly, as a hobby project. It's definitely not production ready but I'm at the stage now where I have some good working demos, and things are taking shape.

For the past year or so I've been mainly working on robustness, doing a _lot_ of debugging, which also led to some rewriting and architecture changes. I rewrote a large part of the GC, fixed lots of edge cases in the language implementation, and made the Wasm/JavaScript interop a lot more efficient.

After all that I've managed to reach my goal of being able to run Richard Feldman's [Elm SPA Example](https://github.com/rtfeldman/elm-spa-example) in my system! :smiley: Here's a working implementation [compiled to WebAssembly](https://brian-carroll.github.io/elm_c_wasm/elm-spa-example-wasm/). And for comparison, you can also check out the same code [compiled to JavaScript](https://brian-carroll.github.io/elm_c_wasm/elm-spa-example-js/). (Unfortunately the publicly available APIs don't seem to be returning very much data at the moment but there's not much I can do about that!)

## Robustness

My early attempts to get the SPA example running failed pretty badly. There were just too many compiler and core library bugs to be able to disentangle everything. I realised I needed to be patient and work on robustness. So I started by writing lots of unit tests for the low-level C code. You can [run the tests in the browser](https://brian-carroll.github.io/elm_c_wasm/unit-tests/?argv=-av).

And there was a specific part of the GC that was always throwing up hard-to-find bugs and was too complicated and hard to understand. It's the system that tracks references from the stack to the heap. I decided to just throw it out and keep trying different approaches until I found something that just felt stable and obvious and robust. I ended up rewriting it 4 times. The end result is something that's much more straightforward and a lot less scary, and I haven't had any bugs there since.

Once all that handwritten C code was solid, I needed to make sure the C generated from Elm was working properly. I found the [source](https://github.com/elm/core/tree/master/tests/tests/Test) for the core library's unit tests and decided to port them into my project and add some of my own tests. You can [run the Elm core tests](https://brian-carroll.github.io/elm_c_wasm/language-test) in your browser too. (Funnily enough, one of the biggest challenges was getting the [Elm Test](https://github.com/elm-explorations/test) framework itself to run! I still need to come back to the fuzzer tests.)

Then finally, with a bit more debugging, the SPA example came together.

## Performance

I haven't really focused on performance yet, but already it's similar to the official compiler's JS output with `--optimize` and `uglify-js`, and there's a lot of room for improvement. This is based on a quick analysis using Lighthouse from Chrome devtools.

## Pre-canned demo apps only!

So overall I think the project is in a pretty good place! But it's not ready for general use. Currently it's only set up to run on the "canned" demo apps in my repo, which all have their own build scripts with minor variations. And there's no solution for package management, so you can't have two apps with different versions of Kernel code.



## How does it work?

The system breaks down into a few different areas:

**Compiler**: I chose to use C as an intermediate language. My forked Elm compiler generates C, then I use Emscripten/Clang to go from C to WebAssembly & JS. (I can also compile C to native code, which is a much better debugging experience.)

**Kernel code**: Elm's runtime and its main data structures are implemented in handwritten JavaScript, so most of that had to be ported to C. (Again, having both the compiled code and kernel code in C is very helpful).

**Garbage Collector**: The Elm language expects its target platform to automatically manage memory for it. Browsers don't implement garbage collection for WebAssembly so I built a mark/sweep garbage collector in C. My measurements estimate it only adds 7kB of Wasm to the bundle.

**Elm/JS interop**: This is actually the toughest part of the project! Let's get into it a bit more below, because it isn't obvious.



## Targeting two languages

The single most important thing to know about targeting WebAssembly for browsers is: **WebAssembly doesn't have access to any of the Web APIs yet**. That means that if you want to do anything useful, you need to produce both WebAssembly _and_ JavaScript. This one crucial fact drives a lot of the system design.

"Web API" here means things like `document.createElement`, `XMLHttpRequest` and so on. They are the interfaces between user code and the browser's internal functionality, often with an underlying implementation written in C++.

> This is obviously a major drawback and the WebAssembly project has several proposals to work towards better host integration. One of the key issues is how to manage reference lifetimes - if a Wasm module is holding a reference to a DOM node, then it can't be garbage-collected. And if it is just a number in Wasm then it can be copied, which makes it hard to keep track of the copies. These issues are addressed in the [GC proposal](https://github.com/WebAssembly/gc/blob/master/proposals/gc/Overview.md), which has been at "stage 1" since I first looked at it in 2018.

So our app gets compiled to a mix of WebAssembly and JS, and they need to talk to each other. That in turn means we need to encode and decode values between WebAssembly and JavaScript representations of the same values. For plain numbers, that's easy. For more complex structures it means serialising and deserialising to a binary format.

This turns out to be a huge deal!

*Sure, WebAssembly "makes things fast"... but lots of serialising and deserialising "makes things slow"!*

In practice, what I've found is that the performance of the system depends almost entirely on how you design this interface between WebAssembly and JavaScript. In my initial versions, there was a lot of unnecessary converting back and forth, and the WebAssembly+JS versions of apps were much slower than the plain JS versions. That traffic was reduced a lot when I ported the Platform and Scheduler Kernel code to C.

We know the kernel code has to be split between C and JS, but *exactly* where do you draw that line? It's fast for Elm code to call into Kernel C code, but slow to to call into Kernel JS code. So for performance, you want most of it to be in C. But on the other hand, the more Kernel code we decide to leave in JavaScript, the less work we have to do to port it.

Obviously when the kernel libraries were designed, there was no slow "barrier" in between Elm code and Kernel code, or between two different parts of the Kernel code. I wonder if that constraint might have resulted in slightly different designs for some libraries? In practice, I want existing Elm apps to run in my system without modification, so I need all ported core libraries to at least retain the same APIs.



## Targeting two memory managers

The two target languages are running in two isolated memory management zones. WebAssembly doesn't have access to the browser's main garbage collector.

Unfortunately there are cases where WebAssembly code may want to hold a long-lived reference to some JS value, and vice versa. We need to make sure we don't end up with stale references to values after they've been collected.

For example if we pass a value from external JS code through a port, it will appear in Elm as a `Json.Decode.Value`. The Elm app could decide to store it in the model and keep it forever. But this is a general JavaScript value that could be unserialisable! We have to keep a long-lived reference to it in Wasm somehow. To do that, we push it into a dedicated JS array, and just pass the array index to Wasm. So the Wasm representation of `Json.Decode.Value` is just an array index that tells it where to find the value in that array. When our Wasm Garbage Collector does a collection, it also calls out to JavaScript to remove any references that are no longer needed.

Going the other direction is harder and we have to find workarounds. Most references from JS code to Wasm values are user-defined callbacks, sending a message back to the app from an effect module. Wasm functions themselves live at fixed addresses and don't get moved around by the Garbage Collector. But those functions may contain partially-applied arguments or closed-over values, which could get moved around in a major GC, so they're not safe. The current solution is to synchronously deserialise those values to JavaScript, and avoid having a JS-to-Wasm reference altogether. The values are serialised back to Wasm whenever the function is called.



## What's next?

Probably the most important practical issues are usability and scalability. I'd like to make the build system general enough and usable enough for people to try out the system on their own apps. And, related to that, I'd like to come up with a more general and scalable way to deal with packages so that all apps don't have to use the same package versions! Maybe we can get some real apps running.

There's also lots of performance ideas I'd like to try out

- Set up a benchmark for some more focused performance work (perhaps [this one](https://krausest.github.io/js-framework-benchmark/2021/table_chrome_93.0.4577.63.html))
- Port more kernel modules to C/Wasm. It looks like this could be one of the key performance drivers but there's a _lot_ of code to port.
- Finish building a VirtualDom implementation in C using cache-friendly "data-oriented design" techniques and an arena allocator
- Remove the Emscripten layer and just use clang. Emscripten was handy to get going but it bloats code size a lot.
- Implement some optimisations that should make function calls faster

