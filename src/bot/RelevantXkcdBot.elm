module RelevantXkcdBot exposing (Model, Msg, init, newUpdateMsg, update)

import Elmegram
import Http
import Json.Decode as Decode
import String.Extra as String
import Task exposing (Task)
import Telegram
import Url
import Xkcd
import Xkcd.Fetch as Xkcd
import Xkcd.FetchError as XkcdError


type alias Response =
    Elmegram.Response Model Msg


type alias Model =
    { self : Telegram.User }


init : Telegram.User -> Model
init user =
    { self = user }


type Msg
    = NewUpdate Telegram.Update
    | SendMessage Telegram.Chat String
    | SendXkcdMessage Telegram.Chat Xkcd.Xkcd
    | AnswerQuery Telegram.InlineQuery String (List Xkcd.Xkcd)
    | AnswerCallback Telegram.CallbackQuery Xkcd.Xkcd
    | AnswerCallbackFail Telegram.CallbackQuery


newUpdateMsg : Telegram.Update -> Msg
newUpdateMsg =
    NewUpdate


update : Msg -> Model -> Response
update msg model =
    let
        handleUpdate : Telegram.Update -> Response
        handleUpdate newUpdate =
            case newUpdate.content of
                -- Message
                Telegram.MessageUpdate message ->
                    -- Help Command
                    if Elmegram.matchesCommand "start" message || Elmegram.matchesCommand "help" message then
                        simply [ helpMessage model.self message.chat ] model
                        -- Invalid Command

                    else if Elmegram.containsCommand message then
                        simply [ commandNotFoundMessage model.self message ] model
                        -- xkcd Query

                    else
                        let
                            getXkcd =
                                fetchSuitableXkcd
                                    message.text
                                    |> Task.attempt
                                        (\result ->
                                            case result of
                                                Ok xkcd ->
                                                    SendXkcdMessage message.chat xkcd

                                                Err err ->
                                                    SendMessage message.chat err
                                        )
                        in
                        do [] model getXkcd

                -- Inline Query
                Telegram.InlineQueryUpdate inlineQuery ->
                    let
                        offset =
                            String.toInt inlineQuery.offset |> Maybe.withDefault 0

                        getXkcd =
                            fetchSuitableXkcds
                                inlineQuery.query
                                { amount = 10, offset = offset }
                                |> Task.attempt
                                    (\result ->
                                        case result of
                                            Ok xkcds ->
                                                let
                                                    newOffset =
                                                        List.length xkcds |> String.fromInt
                                                in
                                                AnswerQuery inlineQuery newOffset xkcds

                                            Err _ ->
                                                AnswerQuery inlineQuery "" []
                                    )
                    in
                    do [] model getXkcd

                -- Callback Query (from inline keyboard button)
                Telegram.CallbackQueryUpdate callbackQuery ->
                    case String.toInt callbackQuery.data of
                        Just id ->
                            do []
                                model
                                (Xkcd.fetchXkcd
                                    id
                                    |> Task.attempt
                                        (\result ->
                                            case result of
                                                Ok xkcd ->
                                                    AnswerCallback callbackQuery xkcd

                                                Err _ ->
                                                    AnswerCallbackFail callbackQuery
                                        )
                                )

                        Nothing ->
                            simply [ answerCallbackFail callbackQuery ] model
    in
    case msg of
        NewUpdate telegramUpdate ->
            handleUpdate telegramUpdate

        SendMessage to text ->
            simply [ Elmegram.answer to text ] model

        AnswerQuery to newOffset xkcds ->
            let
                results =
                    List.map
                        (\xkcd ->
                            let
                                article =
                                    Elmegram.makeMinimalInlineQueryResultArticle
                                        { id = String.fromInt <| Xkcd.getId xkcd
                                        , title = xkcdHeading xkcd
                                        , message = Elmegram.makeInputMessageFormatted <| xkcdText xkcd
                                        }
                            in
                            { article
                                | description = Xkcd.getTranscript xkcd
                                , url = Just <| Telegram.Hide (Xkcd.getComicUrl xkcd)
                                , thumb_url = Just (Xkcd.getPreviewUrl xkcd)
                                , reply_markup = Just (xkcdKeyboard xkcd)
                            }
                                |> Elmegram.inlineQueryResultFromArticle
                        )
                        xkcds

                incompleteInlineQueryAnswer =
                    Elmegram.makeAnswerInlineQuery to results

                rawInlineQueryAnswer =
                    { incompleteInlineQueryAnswer
                        | next_offset = Just newOffset
                    }
            in
            simply [ rawInlineQueryAnswer |> Elmegram.methodFromInlineQuery ] model

        AnswerCallback to xkcd ->
            let
                incompleteAnswer =
                    Elmegram.makeAnswerCallbackQuery to

                answer =
                    { incompleteAnswer
                        | text = Just <| (Xkcd.getMouseOver xkcd |> String.ellipsis 200)
                        , show_alert = True
                    }
            in
            simply [ answer |> Elmegram.methodFromAnswerCallbackQuery ] model

        AnswerCallbackFail to ->
            simply [ answerCallbackFail to ] model

        SendXkcdMessage to xkcd ->
            let
                incompleteAnswer =
                    Elmegram.makeAnswerFormatted to (xkcdText xkcd)

                answer =
                    { incompleteAnswer
                        | reply_markup = Just <| Telegram.InlineKeyboardMarkup (xkcdKeyboard xkcd)
                    }
            in
            simply [ answer |> Elmegram.methodFromMessage ] model


xkcdHeading : Xkcd.Xkcd -> String
xkcdHeading xkcd =
    ("#" ++ (String.fromInt <| Xkcd.getId xkcd) ++ ": ")
        ++ Xkcd.getTitle xkcd


xkcdText : Xkcd.Xkcd -> Elmegram.FormattedText
xkcdText xkcd =
    Elmegram.format Telegram.Html
        (("<b>" ++ xkcdHeading xkcd ++ "</b>\n")
            ++ (Url.toString <| Xkcd.getComicUrl xkcd)
        )


xkcdKeyboard : Xkcd.Xkcd -> Telegram.InlineKeyboard
xkcdKeyboard xkcd =
    [ [ Telegram.CallbackButton (Xkcd.getId xkcd |> String.fromInt) "Show mouse-over" ]
    , [ Telegram.UrlButton (Xkcd.getExplainUrl xkcd) "Explain xkcd" ]
    ]


answerCallbackFail : Telegram.CallbackQuery -> Elmegram.Method
answerCallbackFail to =
    Elmegram.makeAnswerCallbackQuery to
        |> Elmegram.methodFromAnswerCallbackQuery


helpMessage : Telegram.User -> Telegram.Chat -> Elmegram.Method
helpMessage self chat =
    Elmegram.answerFormatted
        chat
        (Elmegram.format
            Telegram.Markdown
            (helpText self)
        )


helpText : Telegram.User -> String
helpText self =
    "Type `@"
        ++ Elmegram.getDisplayName self
        ++ " <query>` in any chat to search for [relevant xkcd](https://relevantxkcd.appspot.com/) comics."
        ++ "To get the latest comics, just enter nothing as the query.\n"
        ++ "\n"
        ++ "You can also just send me messages here. I will answer with the xkcd most relevant to what you sent me."


commandNotFoundMessage : Telegram.User -> Telegram.TextMessage -> Elmegram.Method
commandNotFoundMessage self message =
    Elmegram.replyFormatted
        message
        (Elmegram.format
            Telegram.Markdown
            ("I did not understand that command.\n\n" ++ helpText self)
        )



-- LOGIC


fetchSuitableXkcd : String -> Task String Xkcd.Xkcd
fetchSuitableXkcd query =
    let
        fetchCurrent =
            Xkcd.fetchCurrentXkcd
    in
    if String.isEmpty query then
        fetchCurrent
            |> Task.mapError XkcdError.stringFromFetchXkcdError

    else
        case String.toInt query of
            Just id ->
                Xkcd.fetchXkcd id
                    |> Task.mapError XkcdError.stringFromFetchXkcdError

            Nothing ->
                Xkcd.fetchRelevantXkcdIds query
                    |> Task.mapError XkcdError.stringFromFetchRelevantXkcdError
                    |> Task.andThen
                        (\ids ->
                            case ids of
                                bestMatch :: _ ->
                                    Xkcd.fetchXkcd bestMatch
                                        |> Task.mapError XkcdError.stringFromFetchXkcdError

                                _ ->
                                    Task.fail ("No relevant xkcd for query '" ++ query ++ "'.")
                        )


fetchSuitableXkcds : String -> { amount : Int, offset : Int } -> Task String (List Xkcd.Xkcd)
fetchSuitableXkcds query { amount, offset } =
    let
        fetchLatest =
            Xkcd.fetchLatestXkcdIds { amount = max 0 amount, offset = offset }
                |> Task.andThen Xkcd.fetchXkcds
    in
    if String.isEmpty query then
        fetchLatest
            |> Task.mapError XkcdError.stringFromFetchXkcdError

    else
        case String.toInt query of
            Just id ->
                Xkcd.fetchXkcd id
                    |> Task.mapError XkcdError.stringFromFetchXkcdError
                    |> Task.andThen
                        (\exactMatch ->
                            fetchRelevantXkcds (max 0 (amount - 1)) query
                                |> Task.map
                                    (\xkcds ->
                                        let
                                            cleanedXkcds =
                                                List.filter (\xkcd -> xkcd /= exactMatch) xkcds
                                        in
                                        exactMatch :: cleanedXkcds
                                    )
                        )
                    |> Task.onError
                        (\_ -> fetchRelevantXkcds (max 0 amount) query)

            Nothing ->
                fetchRelevantXkcds amount query


fetchRelevantXkcds : Int -> String -> Task String (List Xkcd.Xkcd)
fetchRelevantXkcds amount query =
    Xkcd.fetchRelevantXkcdIds query
        |> Task.mapError XkcdError.stringFromFetchRelevantXkcdError
        |> Task.andThen
            (Xkcd.fetchXkcds
                >> Task.mapError XkcdError.stringFromFetchXkcdError
            )
        |> Task.map (List.take amount)



-- HELPERS


do : List Elmegram.Method -> Model -> Cmd Msg -> Response
do methods model cmd =
    { methods = methods
    , model = model
    , command = cmd
    }


simply : List Elmegram.Method -> Model -> Response
simply methods model =
    { methods = methods
    , model = model
    , command = Cmd.none
    }


keep : Model -> Response
keep model =
    { methods = []
    , model = model
    , command = Cmd.none
    }
