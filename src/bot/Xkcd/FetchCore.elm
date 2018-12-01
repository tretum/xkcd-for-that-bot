module Xkcd.FetchCore exposing (FetchError(..), FetchRelevantXkcdError, FetchXkcdError, currentXkcdInfoUrl, fetchCurrentXkcdResolver, fetchRelevantIdsResolver, fetchXkcdResolver, latestXkcdIdsFromCurrentId, relevantXkcdUrl, xkcdInfoUrl)

{-| Core functionality for Fetch.
-}

import Http
import Json.Decode as Decode
import Task exposing (Task)
import Url exposing (Url)
import Xkcd exposing (..)


xkcdInfoUrl : XkcdId -> Url
xkcdInfoUrl id =
    { protocol = Url.Https
    , host = "xkcd.com"
    , port_ = Nothing
    , path = "/" ++ String.fromInt id ++ "/info.0.json"
    , query = Nothing
    , fragment = Nothing
    }


fetchXkcdResolver : Int -> Http.Response String -> Result FetchXkcdError Xkcd
fetchXkcdResolver id response =
    let
        genericError =
            Err ("Error fetching xkcd with id " ++ String.fromInt id ++ ".")
    in
    resultFromResponse response
        |> Result.mapError
            (\error ->
                case error of
                    (BadStatus { statusCode } _) as original ->
                        if statusCode == 404 then
                            Unreleased id

                        else
                            Network original

                    networkError ->
                        Network networkError
            )
        |> Result.andThen (\( _, res ) -> parseXkcd res)


currentXkcdInfoUrl : Url
currentXkcdInfoUrl =
    { protocol = Url.Https
    , host = "xkcd.com"
    , port_ = Nothing
    , path = "/info.0.json"
    , query = Nothing
    , fragment = Nothing
    }


fetchCurrentXkcdResolver : Http.Response String -> Result FetchXkcdError Xkcd
fetchCurrentXkcdResolver response =
    resultFromResponse response
        |> Result.mapError Network
        |> Result.andThen (\( _, res ) -> parseXkcd res)


parseXkcd : String -> Result FetchXkcdError Xkcd
parseXkcd raw =
    Decode.decodeString
        decodeXkcd
        raw
        |> Result.mapError Invalid


latestXkcdIdsFromCurrentId : { amount : Int, offset : Int } -> XkcdId -> List XkcdId
latestXkcdIdsFromCurrentId { amount, offset } currentId =
    let
        sanitizedOffset =
            max 0 offset

        sanitizedAmount =
            max 0 amount

        maxId =
            currentId - sanitizedOffset

        minId =
            max 0 (maxId - sanitizedAmount)
    in
    List.range minId maxId
        |> List.reverse


relevantXkcdUrl : String -> Url
relevantXkcdUrl query =
    { protocol = Url.Https
    , host = "relevantxkcd.appspot.com"
    , port_ = Nothing
    , path = "/process"
    , query = Just ("action=xkcd&query=" ++ query)
    , fragment = Nothing
    }


fetchRelevantIdsResolver : Http.Response String -> Result FetchRelevantXkcdError (List XkcdId)
fetchRelevantIdsResolver response =
    resultFromResponse response
        |> Result.mapError Network
        |> Result.andThen (\( _, res ) -> parseRelevantXkcdResponse res)


parseRelevantXkcdResponse : String -> Result FetchRelevantXkcdError (List XkcdId)
parseRelevantXkcdResponse body =
    let
        dropFromEnd amount list =
            List.take (List.length list - amount) list

        sanitizeBody =
            -- The first two entries are statistics.
            List.drop 2
                -- The last line is a newline.
                >> dropFromEnd 1
    in
    String.lines body
        |> sanitizeBody
        |> List.map parseRelevantXkcdId
        |> List.foldl
            (\result list ->
                Result.map2 (\xkcd existing -> existing ++ [ xkcd ]) result list
            )
            (Ok [])


parseRelevantXkcdId : String -> Result FetchRelevantXkcdError XkcdId
parseRelevantXkcdId line =
    case String.words line of
        idString :: urlString :: [] ->
            case String.toInt idString of
                Just id ->
                    Ok id

                _ ->
                    Err (Invalid "Malformed line. Could not convert id.")

        malformed ->
            Err (Invalid <| "Malformed line. Expected 2 fields, got " ++ (List.length malformed |> String.fromInt) ++ ".")



-- HTTP ERRORS


type FetchError invalid
    = Network HttpError
    | Invalid invalid
    | Unreleased Xkcd.XkcdId


type alias FetchXkcdError =
    FetchError Decode.Error


type alias FetchRelevantXkcdError =
    FetchError String


type HttpError
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus Http.Metadata String


resultFromResponse : Http.Response String -> Result HttpError ( Http.Metadata, String )
resultFromResponse response =
    case response of
        Http.GoodStatus_ meta body ->
            Ok ( meta, body )

        Http.BadStatus_ meta body ->
            Err (BadStatus meta body)

        Http.BadUrl_ url ->
            Err (BadUrl url)

        Http.Timeout_ ->
            Err Timeout

        Http.NetworkError_ ->
            Err NetworkError
