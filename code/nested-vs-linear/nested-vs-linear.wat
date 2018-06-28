(module
  (import "js" "mem" (memory 0)) ;; import memory from JS
  (data (i32.const 0) "aaaa--------bbbb--------") ;; initialise memory

  ;; nested version - easy to see how many arguments each instruction takes
  (func (export "copy_nested") (param $from i32) (param $to i32)
    (i32.store offset=0    ;; store an i32 in memory. 2 args: address & value
      (get_local $to)      ;; get value of $to argument (address to copy to)
      (i32.load offset=0   ;; load an i32 from memory. Takes 1 arg, the address
        (get_local $from)))) ;; get value of '$from' (address to copy from)

  ;; linear version - identical functionality, harder to follow!
  ;; comments show stack like an Elm list (top value to the left)
  (func (export "copy_linear") (param $from i32) (param $to i32)
                             ;; stack         description
                             ;; ---------------------------------------
    (get_local $to)          ;; [$to]         push $to (for later)
    (get_local $from)        ;; [$from, $to]  push $from
    (i32.load offset=0)      ;; [data, $to]   pop $from, push data
    (i32.store offset=0)))   ;; []            pop 2 values, storing data at $to
