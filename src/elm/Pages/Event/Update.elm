module Pages.Event.Update where

import Config exposing (cacheTtl)
import Config.Model exposing (BackendConfig)
import Company.Model as Company exposing (Model)
import Effects exposing (Effects)
import Event.Decoder exposing (decode)
import Event.Model exposing (Event)
import Http exposing (Error)
import Leaflet.Model exposing (initialModel, Marker)
import Leaflet.Update exposing (Action)
import Pages.Event.Model as Event exposing (Model)
import String exposing (length, trim)
import Task  exposing (andThen, succeed)
import TaskTutorial exposing (getCurrentTime)
import Time exposing (Time)

type alias Id = Int
type alias CompanyId = Int
type alias Model = Event.Model

init : (Model, Effects Action)
init =
  ( Event.initialModel
  , Effects.none
  )

type Action
  = NoOp
  | GetData (Maybe CompanyId)
  | GetDataFromServer (Maybe CompanyId)
  | UpdateDataFromServer (Result Http.Error (List Event)) (Maybe CompanyId) Time.Time

  -- Select event might get values from JS (i.e. selecting a leaflet marker)
  -- so we allow passing a Maybe Int, instead of just Int.
  | SelectCompany (Maybe CompanyId)
  | SelectEvent (Maybe Int)
  | UnSelectEvent
  | SelectAuthor Int
  | UnSelectAuthor
  -- @todo: Make (Maybe String)
  | FilterEvents String

  -- Child actions
  | ChildLeafletAction Leaflet.Update.Action

  -- Page
  | Activate (Maybe CompanyId)
  | Deactivate


type alias Context =
  { accessToken : String
  , backendConfig : BackendConfig
  , companies : List Company.Model
  }

update : Context -> Action -> Model -> (Model, Effects Action)
update context action model =
  case action of
    NoOp ->
      (model, Effects.none)

    GetData maybeCompanyId ->
      let
        noFx =
          (model, Effects.none)

        getFx =
          (model, getDataFromCache model.status maybeCompanyId)
      in
      case model.status of
        Event.Fetching id ->
          if id == maybeCompanyId
            -- We are already fetching this data
            then noFx
            -- We are fetching data, but for a different company ID,
            -- so we need to re-fetch.
            else getFx

        _ ->
          getFx

    GetDataFromServer maybeCompanyId ->
      let
        backendUrl =
          (.backendConfig >> .backendUrl) context

        url =
          backendUrl ++ "/api/v1.0/events"
      in
        ( { model | status <- Event.Fetching maybeCompanyId}
        , getJson url maybeCompanyId context.accessToken
        )

    UpdateDataFromServer result maybeCompanyId timestamp ->
      case result of
        Ok events ->
          ( {model
              | events <- events
              , status <- Event.Fetched maybeCompanyId timestamp
            }
          , Task.succeed (FilterEvents model.filterString) |> Effects.task
          )
        Err msg ->
          ( {model | status <- Event.HttpError msg}
          , Effects.none
          )

    SelectCompany maybeCompanyId ->
      let
        isValidCompany val =
          context.companies
            |> List.filter (\company -> company.id == val)
            |> List.length


        selectedCompany =
          case maybeCompanyId of
            Just val ->
              -- Make sure the given company ID is a valid one.
              if ((isValidCompany val) > 0)
                then Just val
                else Nothing
            Nothing ->
              Nothing
      in
        ( { model | selectedCompany <- selectedCompany }
        , Task.succeed (GetData selectedCompany) |> Effects.task
        )


    SelectEvent val ->
      case val of
        Just id ->
          ( { model | selectedEvent <- Just id }
          , Task.succeed (ChildLeafletAction <| Leaflet.Update.SelectMarker <| Just id) |> Effects.task
          )
        Nothing ->
          (model, Task.succeed UnSelectEvent |> Effects.task)

    UnSelectEvent ->
      ( { model | selectedEvent <- Nothing }
      , Task.succeed (ChildLeafletAction <| Leaflet.Update.SelectMarker Nothing) |> Effects.task
      )

    SelectAuthor id ->
      ( { model | selectedAuthor <- Just id }
      , Effects.batch
        [ Task.succeed UnSelectEvent |> Effects.task
        , Task.succeed (FilterEvents model.filterString) |> Effects.task
        ]
      )

    UnSelectAuthor ->
      ( { model | selectedAuthor <- Nothing }
      , Effects.batch
        [ Task.succeed UnSelectEvent |> Effects.task
        , Task.succeed (FilterEvents model.filterString) |> Effects.task
        ]
      )

    FilterEvents val ->
      let
        model' = { model | filterString <- val }

        leaflet = model.leaflet
        leaflet' = { leaflet | markers <- (leafletMarkers model')}

        effects =
          case model.selectedEvent of
            Just id ->
              -- Determine if the selected event is visible (i.e. not filtered
              -- out).
              let
                isSelectedEvent =
                  filterListEvents model'
                    |> List.filter (\event -> event.id == id)
                    |> List.length
              in
                if isSelectedEvent > 0 then Effects.none else Task.succeed UnSelectEvent |> Effects.task

            Nothing ->
              Effects.none
      in
        ( { model
          | filterString <- val
          , leaflet <- leaflet'
          }
        , effects
        )

    ChildLeafletAction act ->
      let
        (childModel, childEffects) = Leaflet.Update.update act model.leaflet
      in
        ( {model | leaflet <- childModel }
        , Effects.map ChildLeafletAction childEffects
        )

    Activate maybeCompanyId ->
      let
        (childModel, childEffects) = Leaflet.Update.update Leaflet.Update.ToggleMap model.leaflet

      in
        ( {model | leaflet <- childModel }
        , Effects.batch
            [ Task.succeed (SelectCompany maybeCompanyId) |> Effects.task
            , Effects.map ChildLeafletAction childEffects
            ]
        )

    Deactivate ->
      let
        (childModel, childEffects) = Leaflet.Update.update Leaflet.Update.ToggleMap model.leaflet
      in
        ( {model | leaflet <- childModel }
        , Effects.map ChildLeafletAction childEffects
        )


-- Build the Leaflet's markers data from the events
leafletMarkers : Model -> List Leaflet.Model.Marker
leafletMarkers model =
  filterListEvents model
    |> List.map (\event -> Leaflet.Model.Marker event.id event.marker.lat event.marker.lng)


-- EFFECTS

getDataFromCache : Event.Status -> Maybe CompanyId -> Effects Action
getDataFromCache status maybeCompanyId =
  let
    getFx =
      Task.succeed <| GetDataFromServer maybeCompanyId

    actionTask =
      case status of
        Event.Fetched id fetchTime ->
          if id == maybeCompanyId
            then
              Task.map (\currentTime ->
                if fetchTime + Config.cacheTtl > currentTime
                  then NoOp
                  else GetDataFromServer maybeCompanyId
              ) getCurrentTime
            else
              getFx

        _ ->
          getFx

  in
    Effects.task actionTask


getJson : String -> Maybe CompanyId -> String -> Effects Action
getJson url maybeCompanyId accessToken =
  let
    params =
      [ ("access_token", accessToken) ]

    params' =
      case maybeCompanyId of
        Just id ->
          -- Filter by company
          ("filter[company]", toString id) :: params

        Nothing ->
          params


    encodedUrl =
      Http.url url params'

    httpTask =
      Task.toResult <|
        Http.get Event.Decoder.decode encodedUrl

    actionTask =
      httpTask `andThen` (\result ->
        Task.map (\timestamp ->
          UpdateDataFromServer result maybeCompanyId timestamp
        ) getCurrentTime
      )

  in
    Effects.task actionTask

-- In case an author or string-filter is selected, filter the events.
filterListEvents : Model -> List Event
filterListEvents model =
  let
    authorFilter : List Event -> List Event
    authorFilter events =
      case model.selectedAuthor of
        Just id ->
          List.filter (\event -> event.author.id == id) events

        Nothing ->
          events

    stringFilter : List Event -> List Event
    stringFilter events =
      if String.length (String.trim model.filterString) > 0
        then
          List.filter (\event -> String.contains (String.trim (String.toLower model.filterString)) (String.toLower event.label)) events

        else
          events

  in
    authorFilter model.events
     |> stringFilter
