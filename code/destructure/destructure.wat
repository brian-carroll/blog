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

  (func (export "destruct_and_add") (param $num_args i32)
    (block
      (block
        (block
          (block
            (br_table 0 1 2 3
              (get_local 0)))
          (unreachable))
        (return
          (call $f1
            (i32.const 1))))
      (return
        (call $f2
          (i32.const 1)
          (i32.const 1))))
    (unreachable)))