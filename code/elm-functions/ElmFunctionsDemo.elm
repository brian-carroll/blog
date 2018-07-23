module ElmFunctionsDemo exposing (..)


closureMaker : Int -> (Int -> Int -> Int)
closureMaker closedOver =
    let
        closure arg1 arg2 =
            closedOver + arg1 + arg2
    in
        closure


{-| function *definition* is effectively lifted to top level
-}
closureGenerated closedOver arg1 arg2 =
    closedOver + arg1 + arg2


closureMakerEquivalent : Int -> (Int -> Int -> Int)
closureMakerEquivalent closedOver =
    let
        -- Code generator detects closed-over values and applies them here
        closure =
            closureGenerated closedOver
    in
        closure


myClosure : Int -> Int -> Int
myClosure =
    closureMaker 1


curried : Int -> Int
curried =
    myClosure 2


higherOrder : (Int -> Int) -> Int -> Int
higherOrder function value =
    function value


answer : Int
answer =
    higherOrder curried 3
