---
title: Elm in Wasm: Headers, Records and Custom types
published: false
description: 
tags: #elm, #webassembly

---

## Elm in WebAssembly: progress report

I've been researching and prototyping Elm in WebAssembly as a hobby project for the past 6 months or so, having read the post below on the [Elm projects page](https://github.com/elm-lang/projects/blob/master/README.md#explore-webassembly).

> [WebAssembly](http://webassembly.org/) will be maturing over the next few years. Without a garbage collector, it is not viable for languages like Elm. In the meantime, there are a few questions it would be good to answer:
>
> - What are the facilities for representing UTF-8 strings? If you make it all from bit arrays and trees, we should do a “literature review” of how strings are represented in languages like JS, Java, Go, etc.
> - How does WebAssembly code interact with the DOM? What does that mean for Elm’s virtual-dom library?
> - How does WebAssembly interact with WebGL? What does that mean for Elm’s webgl library?
>
> In all these cases, the ideal result is documentation that gets shared with [elm-dev](https://groups.google.com/d/forum/elm-dev). Before making technical decisions and investments, certain big questions must be addressed. So it probably makes sense to do some prototyping, but the actual deliverable here is knowledge.

I know absolutely nothing about WebGL in any language so I'm not going to touch on that at all. But I'll address as much of the rest as I can, and add some other information that I think is important.

It's hard to know where to start so let's go with a summary of my conclusions first! Then we can start to dive into how I got there, which will take a lot longer.

## Summary of findings

- WebAssembly roadmap
  - WebAssembly (also known as Wasm) is currently at Minimum Viable Product phase. It's pretty limited but will be getting more features as time goes on.
  - From Elm's point of view the main limitations of the MVP are:
    - It doesn't have built-in garbage collection
    - It has no direct access to Web APIs except via the JavaScript foreign function interface
  - The main impacts of these MVP limitations are:
    - Effect Managers for Web APIs must have some at least *some* JavaScript code, communicating with the Wasm part of the app using something like a port.
    - *Serialised* byte-level messages can be passed between JS and WebAssembly through a shared `ArrayBuffer`. It would work pretty similarly to ports as they currently exist, except fully serialised. (`Json.Decode.Value` can contain unserialisable fields as long as you don't actually decode them.)
  - In the long term after MVP
    - With the [host bindings proposal](https://github.com/WebAssembly/host-bindings/blob/master/proposals/host-bindings/Overview.md), we'll be able to call Web API functions to interact with "host references" - objects created and garbage-collected by the browser such as `document` and `XmlHttpRequest`.
    - When the [GC proposal](https://github.com/WebAssembly/gc/blob/master/proposals/gc/Overview.md) is implemented, a Wasm program will be able to use the browser's garbage collector for values created in Wasm itself. The platform will supply an API to create garbage collected structures and arrays.
      - Types: array, struct, etc.
- Web APIs in more detail
  - Discuss host bindings proposal
  - JSON
    - Wasm MVP
      - Fully serialised, use something like Ilias' library. Two stage JSON decode, parse and validate.
      - `Json.Decode.Value` becomes the parsed (but not validated) data structure
    - Wasm post-MVP
      - JS objects work as in current Elm
  - Ports
    - Linear memory handshaking process
  - DOM
    - Wasm MVP
      - Current approach doesn't work
        - Can't pass around DOM node references inside Wasm.
      - Need a set of patches to be serialisable
        - Very feasible, see Gampelman's library and Evan's comment in VirtualDom source code.
    - Wasm post-MVP
      - Either approach would work.
      - You'd have a long-lived mutable variable representing the root of the virtual DOM tree, and the compiled Wasm would put this in the table to make it a GC root and preserve the whole tree.
  - String encoding
    - Wasm seems to favour UTF-8 but Web APIs are UTF-16 so how does that work?
    - Will all Wasm calls be encoded/decoded between UTF-8 and UTF-16?
  - Effect Managers
    - Wasm MVP
      - Web API interface has to be in JS
      - What goes into JS and what goes into Wasm? Wherever we draw the line, only serialised data can cross it
      - Minimal JS: use the Process GUID to send serialised messages across the boundary. JS needs to maintain a dictionary of Web API instances indexed by Process GUID.
      - Scheduler in JS, keep JS runtime: Then where is the serialisable Wasm/JS boundary?
      - Process IDs and kill functions are 

- Implementation
  - How will Wasm GC and ref types work?
    - I'm speculating, but...
    - It looks like GC values, including host references, will get collected unless they are reachable from the call stack or the reference table.
    - I think the table in the GC proposal effectively represents your GC roots.
    - The proposal doesn't make it quite clear what this would look like in C or Rust source code.
      - The closest thing that Wasm MVP has is a function table. This holds C function pointers. In C source code you just take a reference to a function using normal C syntax and the compiler knows to store that in a special table for function pointers rather than in the main linear memory (this is for security).
      - The host bindings and GC proposals use data types that are not native to C or Rust. So I expect that some standard libraries would be provided, providing functions and data types in C and Rust corresponding to the new WebAssembly data types.
    - You can mark things as immutable, so maybe the GC gives them special treatment and does less checking on them
  - Process IDs and stuff
    - All