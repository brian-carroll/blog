- Garbage collection
  - GC is too big to download with every program? I built a prototype in under 7kB!
    - I don't have performance stats yet though! The browser will very likely outperform my design, unless having it customised for pure functions and immutable data really is a major advantage. I have no idea.
  - Useful aspects of Elm for custom GC
    - Timing
      - There are obvious times when we can do GC - after every update cycle.
      - This is also largely true of JS. Each tick is a bit like an update cycle.
    - Immutablility
      - Pointers only go from new to old, never old to new.
      - Makes it easy to pick how much of the heap you want to collect. Choose a subset of values created after a certain point in time (like an Elm update cycle) and collect those. Nothing from outside that group points into that group, guaranteed. That's fast.
      - BUT you only get this if _all_ heap values are immutable, including those allocated by effect managers and the runtime. This means reworking some core modules but it's quite feasible using mutable references to immutable data.
    - Purity
      - If the entire call stack is just pure functions, you can replace every call with its return value.
      - This offers a neat solution to one of the tough problems in GC design - what to do with pointers in registers or in the stack that point to the _old_ position of a value that the GC moved in the heap. With pure functions, you can do this:
        - Interrupt execution
        - Run garbage collection, saving all the return values of completed functions
        - "Replay" the call stack from the root to get back to the point where you interrupted it. This is very fast because most of the function calls are not actually executed - we just remember the value they returned last time and use that. But it has now moved to a new location so registers and stack pointers can refer to it safely.

