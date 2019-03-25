module Search.State exposing (init, subscriptions, update, updateUserInfo)

import Array exposing (Array)
import BigInt exposing (BigInt)
import BigIntHelpers
import CommonTypes exposing (UserInfo)
import Contracts.Types
import Contracts.Wrappers
import Eth.Sentry.Event as EventSentry exposing (EventSentry)
import Eth.Types exposing (Address)
import EthHelpers
import FiatValue exposing (FiatValue)
import Flip exposing (flip)
import PaymentMethods exposing (PaymentMethod)
import Routing
import Search.Types exposing (..)
import Time
import TimeHelpers
import TokenValue exposing (TokenValue)


init : EthHelpers.EthNode -> Address -> Int -> Maybe Contracts.Types.OpenMode -> Maybe UserInfo -> ( Model, Cmd Msg )
init ethNode factoryAddress tokenDecimals maybeOpenMode userInfo =
    let
        openMode =
            maybeOpenMode |> Maybe.withDefault Contracts.Types.SellerOpened

        ( eventSentry, sentryCmd ) =
            EventSentry.init
                EventSentryMsg
                ethNode.http
    in
    ( { ethNode = ethNode
      , eventSentry = eventSentry
      , userInfo = userInfo
      , factoryAddress = factoryAddress
      , tokenDecimals = tokenDecimals
      , numTrades = Nothing
      , openMode = openMode
      , trades = Array.empty
      , inputs = initialInputs
      , query = initialQuery
      , filterFunc = initialFilterFunc openMode
      , sortFunc = initialSortFunc
      }
    , Cmd.batch
        [ Contracts.Wrappers.getNumTradesCmd ethNode factoryAddress NumTradesFetched
        , sentryCmd
        ]
    )


initialFilterFunc : Contracts.Types.OpenMode -> (Time.Posix -> Contracts.Types.FullTradeInfo -> Bool)
initialFilterFunc openMode =
    \time trade ->
        (trade.state.phase == Contracts.Types.Open)
            && (trade.parameters.openMode == openMode)
            && (TimeHelpers.compare trade.derived.phaseEndTime time == GT)


initialSortFunc : Contracts.Types.FullTradeInfo -> Contracts.Types.FullTradeInfo -> Order
initialSortFunc a b =
    compare a.creationInfo.blocknum b.creationInfo.blocknum


initialInputs : SearchInputs
initialInputs =
    { minDai = ""
    , maxDai = ""
    , fiatType = ""
    , minFiat = ""
    , maxFiat = ""
    , paymentMethod = ""
    , paymentMethodTerms = []
    , showCurrencyDropdown = False
    }


initialQuery : SearchQuery
initialQuery =
    SearchQuery
        (TokenRange Nothing Nothing)
        (FiatTypeAndRange Nothing Nothing Nothing)
        []


update : Msg -> Model -> ( Model, Cmd Msg, Maybe Routing.Route )
update msg model =
    case msg of
        NumTradesFetched fetchResult ->
            case fetchResult of
                Ok bigInt ->
                    case BigIntHelpers.toInt bigInt of
                        Just numTrades ->
                            let
                                fetchCreationInfoCmd =
                                    Cmd.batch
                                        (List.range 0 (numTrades - 1)
                                            |> List.map
                                                (\id ->
                                                    Contracts.Wrappers.getCreationInfoFromIdCmd model.ethNode model.factoryAddress (BigInt.fromInt id) (CreationInfoFetched id)
                                                )
                                        )

                                trades =
                                    List.range 0 (numTrades - 1)
                                        |> List.map Contracts.Types.partialTradeInfo
                                        |> Array.fromList
                            in
                            ( { model
                                | numTrades = Just numTrades
                                , trades = trades
                              }
                            , fetchCreationInfoCmd
                            , Nothing
                            )

                        Nothing ->
                            let
                                _ =
                                    Debug.log "can't convert the numTrades bigInt value to an int"
                            in
                            ( model, Cmd.none, Nothing )

                Err errstr ->
                    let
                        _ =
                            Debug.log "can't fetch numTrades:" errstr
                    in
                    ( model, Cmd.none, Nothing )

        CreationInfoFetched id fetchResult ->
            case fetchResult of
                Ok encodedCreationInfo ->
                    let
                        creationInfo =
                            Contracts.Types.TradeCreationInfo
                                encodedCreationInfo.address_
                                (BigIntHelpers.toIntWithWarning encodedCreationInfo.blocknum)

                        newModel =
                            model
                                |> updateTradeCreationInfo id creationInfo

                        ( newSentry, sentryCmd ) =
                            Contracts.Wrappers.getOpenedEventDataSentryCmd model.eventSentry creationInfo (OpenedEventDataFetched id)

                        cmd =
                            Cmd.batch
                                [ Contracts.Wrappers.getParametersAndStateCmd model.ethNode model.tokenDecimals creationInfo.address (ParametersFetched id) (StateFetched id)
                                , sentryCmd
                                ]
                    in
                    ( { newModel | eventSentry = newSentry }
                    , cmd
                    , Nothing
                    )

                Err errstr ->
                    let
                        _ =
                            Debug.log ("Error fetching address on id" ++ String.fromInt id) errstr
                    in
                    ( model, Cmd.none, Nothing )

        ParametersFetched id fetchResult ->
            case fetchResult of
                Ok (Ok parameters) ->
                    ( model |> updateTradeParameters id parameters
                    , Cmd.none
                    , Nothing
                    )

                badResult ->
                    let
                        _ =
                            Debug.log "bad parametersFetched result" badResult
                    in
                    ( model, Cmd.none, Nothing )

        StateFetched id fetchResult ->
            case fetchResult of
                Ok (Just state) ->
                    ( model |> updateTradeState id state
                    , Cmd.none
                    , Nothing
                    )

                _ ->
                    let
                        _ =
                            EthHelpers.logBadFetchResultMaybe fetchResult
                    in
                    ( model, Cmd.none, Nothing )

        OpenedEventDataFetched id fetchResult ->
            case fetchResult of
                Ok openedEventData ->
                    let
                        paymentMethods =
                            PaymentMethods.decodePaymentMethodList
                                openedEventData.fiatTransferMethods
                    in
                    ( model |> updateTradePaymentMethods id paymentMethods
                    , Cmd.none
                    , Nothing
                    )

                Err decodeError ->
                    let
                        _ =
                            Debug.log "Error decoding the fetched result of OpenEvent data" decodeError
                    in
                    ( model
                    , Cmd.none
                    , Nothing
                    )

        Refresh _ ->
            let
                cmd =
                    model.trades
                        |> Array.toList
                        |> List.indexedMap
                            (\id trade ->
                                case trade of
                                    Contracts.Types.PartiallyLoadedTrade _ ->
                                        Cmd.none

                                    Contracts.Types.LoadedTrade info ->
                                        let
                                            address =
                                                info.creationInfo.address
                                        in
                                        Contracts.Wrappers.getStateCmd model.ethNode model.tokenDecimals address (StateFetched id)
                            )
                        |> Cmd.batch
            in
            ( model
            , cmd
            , Nothing
            )

        MinDaiChanged input ->
            ( { model | inputs = model.inputs |> updateMinDaiInput input }
            , Cmd.none
            , Nothing
            )

        MaxDaiChanged input ->
            ( { model | inputs = model.inputs |> updateMaxDaiInput input }
            , Cmd.none
            , Nothing
            )

        MinFiatChanged input ->
            ( { model | inputs = model.inputs |> updateMinFiatInput input }
            , Cmd.none
            , Nothing
            )

        MaxFiatChanged input ->
            ( { model | inputs = model.inputs |> updateMaxFiatInput input }
            , Cmd.none
            , Nothing
            )

        FiatTypeInputChanged input ->
            ( { model | inputs = model.inputs |> updateFiatTypeInput input }
            , Cmd.none
            , Nothing
            )

        ShowCurrencyDropdown flag ->
            ( { model | inputs = model.inputs |> updateShowCurrencyDropdown flag }
            , Cmd.none
            , Nothing
            )

        PaymentMethodInputChanged input ->
            ( { model | inputs = model.inputs |> updatePaymentMethodInput input }
            , Cmd.none
            , Nothing
            )

        AddSearchTerm ->
            ( model |> addPaymentInputTerm
            , Cmd.none
            , Nothing
            )

        RemoveTerm term ->
            ( model |> removePaymentInputTerm term
            , Cmd.none
            , Nothing
            )

        ApplyInputs ->
            ( model |> applyInputs
            , Cmd.none
            , Nothing
            )

        ResetSearch ->
            ( model |> resetSearch
            , Cmd.none
            , Nothing
            )

        TradeClicked id ->
            ( model, Cmd.none, Just (Routing.Interact (Just id)) )

        SortBy colType ascending ->
            let
                newSortFunc =
                    (\a b ->
                        case colType of
                            Expiring ->
                                TimeHelpers.compare a.derived.phaseEndTime b.derived.phaseEndTime

                            TradeAmount ->
                                TokenValue.compare a.parameters.tradeAmount b.parameters.tradeAmount

                            Fiat ->
                                FiatValue.compare a.parameters.fiatPrice b.parameters.fiatPrice

                            Margin ->
                                Maybe.map2
                                    (\marginA marginB -> compare marginA marginB)
                                    a.derived.margin
                                    b.derived.margin
                                    |> Maybe.withDefault EQ

                            PaymentMethods ->
                                let
                                    _ =
                                        Debug.log "Can't sort by payment methods. What does that even mean??" ""
                                in
                                initialSortFunc a b

                            AutoabortWindow ->
                                TimeHelpers.compare a.parameters.autoabortInterval b.parameters.autoabortInterval

                            AutoreleaseWindow ->
                                TimeHelpers.compare a.parameters.autoreleaseInterval b.parameters.autoreleaseInterval
                    )
                        |> (if ascending then
                                flip

                            else
                                identity
                           )
            in
            ( { model | sortFunc = newSortFunc }
            , Cmd.none
            , Nothing
            )

        EventSentryMsg eventMsg ->
            let
                ( newEventSentry, cmd ) =
                    EventSentry.update
                        eventMsg
                        model.eventSentry
            in
            ( { model
                | eventSentry =
                    newEventSentry
              }
            , cmd
            , Nothing
            )

        NoOp ->
            noUpdate model


addPaymentInputTerm : Model -> Model
addPaymentInputTerm model =
    if model.inputs.paymentMethod == "" then
        model

    else
        let
            searchTerm =
                model.inputs.paymentMethod

            newSearchTerms =
                List.append
                    model.inputs.paymentMethodTerms
                    [ searchTerm ]
        in
        { model
            | inputs =
                model.inputs
                    |> updatePaymentMethodInput ""
                    |> updatePaymentMethodTerms newSearchTerms
        }


removePaymentInputTerm : String -> Model -> Model
removePaymentInputTerm term model =
    let
        newTermList =
            model.inputs.paymentMethodTerms
                |> List.filter ((/=) term)
    in
    { model | inputs = model.inputs |> updatePaymentMethodTerms newTermList }


applyInputs : Model -> Model
applyInputs model =
    let
        newModel =
            model |> addPaymentInputTerm

        query =
            inputsToQuery newModel.inputs

        searchTest time trade =
            case query.paymentMethodTerms of
                [] ->
                    True

                terms ->
                    testTextMatch terms trade.paymentMethods

        daiTest trade =
            (case query.dai.min of
                Nothing ->
                    True

                Just min ->
                    TokenValue.compare trade.parameters.tradeAmount min /= LT
            )
                && (case query.dai.max of
                        Nothing ->
                            True

                        Just max ->
                            TokenValue.compare trade.parameters.tradeAmount max /= GT
                   )

        fiatTest trade =
            (case query.fiat.type_ of
                Nothing ->
                    True

                Just fiatType ->
                    trade.parameters.fiatPrice.fiatType == fiatType
            )
                && (case query.fiat.min of
                        Nothing ->
                            True

                        Just min ->
                            BigInt.compare trade.parameters.fiatPrice.amount min /= LT
                   )
                && (case query.fiat.max of
                        Nothing ->
                            True

                        Just max ->
                            BigInt.compare trade.parameters.fiatPrice.amount max /= GT
                   )

        newFilterFunc time trade =
            initialFilterFunc model.openMode time trade
                && searchTest time trade
                && daiTest trade
                && fiatTest trade
    in
    { newModel
        | query = query
        , filterFunc = newFilterFunc
    }


resetSearch : Model -> Model
resetSearch model =
    { model
        | sortFunc = initialSortFunc
        , filterFunc = initialFilterFunc model.openMode
        , inputs = initialInputs
        , query = initialQuery
    }


testTextMatch : List String -> Result String (List PaymentMethod) -> Bool
testTextMatch terms paymentMethodsDecodeResult =
    let
        searchForAllTerms searchable =
            terms
                |> List.all
                    (\term ->
                        String.contains term searchable
                    )
    in
    case paymentMethodsDecodeResult of
        Err searchable ->
            -- Here we use a Result to contain the undecoded string upon decode failure
            searchForAllTerms searchable

        Ok paymentMethods ->
            paymentMethods
                |> List.any
                    (\method ->
                        searchForAllTerms <|
                            case method of
                                PaymentMethods.CashDrop s ->
                                    s

                                PaymentMethods.CashHandoff s ->
                                    s

                                PaymentMethods.BankTransfer identifier ->
                                    identifier.info

                                PaymentMethods.Custom s ->
                                    s
                    )


noUpdate : Model -> ( Model, Cmd Msg, Maybe Routing.Route )
noUpdate model =
    ( model, Cmd.none, Nothing )


updateUserInfo : Maybe UserInfo -> Model -> Model
updateUserInfo userInfo model =
    { model | userInfo = userInfo }


subscriptions : Model -> Sub Msg
subscriptions model =
    Time.every 5000 Refresh
