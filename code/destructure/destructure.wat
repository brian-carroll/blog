(module
  (import "js" "log" (func $log (param i32))) ;; import logger from JS

  (func $f1 (param i32)
    (call $log
      (get_local 0)))

  (func $f2 (param i32) (param i32)
    (call $log
      (i32.add
        (get_local 0)
        (get_local 1))))

  (func (export "destruct_and_add") (param $num_args i32) (local $tmp i32)
    (set_local $tmp
      (get_local $num_args))

    (block
      (block
        (i32.const 1)

        ;; if (!(--tmp)) break;
        (br_if 0
          (tee_local $tmp
            (i32.sub (get_local $tmp) (i32.const 1))))
        (call $f1))

      (i32.const 1)
      (i32.const 2)
      (br_if 0
        (tee_local $tmp
          (i32.sub (get_local $tmp) (i32.const 1))))
      (call $f2))))

;; each block starts with a fresh stack
;; can't access outer level stack
;; Therefore can't make code smaller by gradually building up a stack
;; for different arity functions
