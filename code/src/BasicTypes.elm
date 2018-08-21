module BasicTypes exposing (..)


main =
    Platform.worker
        { init = \() -> ( model, Cmd.none )
        , update = \_ _ -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


model =
    { tuple2 = tuple2
    , tuple3 = tuple3
    , list = list
    , int = int
    , float = float
    , string = string
    , char = char
    }


tuple2 =
    ( 1, 2 )


tuple3 =
    ( 1, 2, 3 )


list =
    [ 1, 2, 3 ]


int : Int
int =
    5


float : Float
float =
    1.2


string =
    "my string"


char =
    'c'
