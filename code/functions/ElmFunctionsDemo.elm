module ElmFunctionsDemo exposing (..)


closureMaker : Int -> (Int -> Int -> Int)
closureMaker closedOver =
    \arg1 arg2 ->
        closedOver + arg1 + arg2


closure : Int -> Int -> Int
closure =
    closureMaker 1


curried : Int -> Int
curried =
    closure 2


higherOrder : (Int -> Int) -> Int -> Int
higherOrder function value =
    function value


answer : Int
answer =
    higherOrder curried 3
