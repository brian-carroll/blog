(module
  (import "js" "mem" (memory 0)) ;; import memory from JS
  (data (i32.const 0) "aaaa----bbbb----cccc----") ;; initialise memory

  ;; Nested version
  ;; Most like a 'normal' language
  (func (export "copy_nested") (param $from i32) (param $to i32)
    (i32.store          ;; store an i32 in memory. 2 args: address & value
      (get_local $to)   ;; get value of '$to' argument (address to copy to)
      (i32.load         ;; load an i32 from memory. Takes 1 arg, the address
        (get_local $from)))) ;; get value of '$from' (address to copy from)

  ;; Sequential version
  ;; Comments show the stack like an Elm list (top value to the left)
  (export "copy_seq" (func $copy_seq)) ;; declare the export
  (func $copy_seq (param $from i32) (param $to i32)
                      ;; stack         description
                      ;; ---------------------------------------
    (get_local $to)   ;; [$to]         push $to (for later)
    (get_local $from) ;; [$from, $to]  push $from
    (i32.load)        ;; [data, $to]   pop $from, push data
    (i32.store))      ;; []            pop 2 values, storing data at $to

  ;; Fully de-sugared version
  ;; All labels turned into indices
  (export "copy_sugarfree" (func 2)) ;; export 3rd function in module (index 2)
  (func (param i32) (param i32)
    (get_local 1)   ;; push second argument
    (get_local 0)   ;; push first argument
    (i32.load)
    (i32.store)))
