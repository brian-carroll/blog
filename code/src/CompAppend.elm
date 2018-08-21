module CompAppend exposing (..)


main =
    Platform.worker
        { init = \() -> ( model, Cmd.none )
        , update = \_ _ -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


model =
    ( testFun "hello " "world"
    , testFun [ 1, 2 ] [ 3, 4 ]
    )


testFun : compappend -> compappend -> compappend
testFun a b =
    if a > b then
        a
    else
        a ++ b
