(module
  (import "outPorts" "outgoingPort" (func $log (param i32 i32)))
  (memory 0)
  (data (i32.const 0) "B\00e\00f\00o\00r\00e\00") ;; At offset 0, initialize 12 bytes of text in UTF-16 little-endian
  (data (i32.const 32) "A\00f\00t\00e\00r\00") ;; At offset 32 bytes, initialize 10 bytes of text in UTF-16 little-endian
  (func (export "allocate") (param $numBytesRequested i32) (result i32)
    ;; Pretend to allocate $numBytesRequested in a Wasm-implemented Garbage Collector
    i32.const 12 ) ;; memory offset for JS to start writing, in bytes
  ;; mock incoming port. This one just calls a JS logger. A real one could do other things.
  (func (export "inPort$incomingPort") (param $offset i32) (param $bytes i32)
    get_local $offset
    get_local $bytes
    call $log ))
