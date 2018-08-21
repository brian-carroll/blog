module RuntimeTypeInspection exposing (..)


testIfStringOrList value =
    case value of
        "" ->
            "It's an empty string!"

        [] ->
            "It's an empty list!"

        _ ->
            "It's something else!"
