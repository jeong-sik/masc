open Result.Syntax

module Event = Workspace_dataset_event

let field name fields = List.assoc_opt name fields
let string value = `String value

let scope_of_request_target target =
  let query = Uri.of_string target in
  let present name = Option.is_some (Uri.get_query_param query name) in
  if not (List.exists present [ "source"; "clientId"; "tabId"; "view"; "sceneView"; "scope" ])
  then Ok None
  else
    let integer raw =
      match int_of_string_opt raw with Some value -> `Int value | None -> `String raw
    in
    let json raw =
      match Yojson.Safe.from_string raw with value -> value | exception Yojson.Json_error _ -> `String raw
    in
    let fields =
      List.filter_map Fun.id
        [ Option.map (fun raw -> "source", string raw) (Uri.get_query_param query "source")
        ; Option.map (fun raw -> "clientId", string raw) (Uri.get_query_param query "clientId")
        ; Option.map (fun raw -> "tabId", integer raw) (Uri.get_query_param query "tabId")
        ; Option.map (fun raw -> "view", string raw) (Uri.get_query_param query "view")
        ; Option.map (fun raw -> "sceneView", string raw) (Uri.get_query_param query "sceneView")
        ; Option.map (fun raw -> "scope", json raw) (Uri.get_query_param query "scope") ]
    in
    (match field "clientId" fields with None -> Some ("clientId", `Null) | Some _ -> None)
    |> Option.fold ~none:fields ~some:(fun missing -> missing :: fields)
    |> Event.browser_scope_of_fields
    |> Result.map Option.some

let request_json (scope : Event.browser_scope) =
  `Assoc
    ([ "lane", string (Browser_lane.Lane_name.to_wire scope.source)
     ; ( "clientId"
       , match scope.client_id with Some client -> string client | None -> `Null )
     ; "tabId", `Int scope.tab_id ]
     @
     match scope.view with
     | Event.Read -> []
     | Event.Viewport -> []
     | Event.Scene { scene_view; scope = region } ->
         [ "view", string (match scene_view with Browser_lane.Content -> "content" | Regions -> "regions")
         ; ( "scope"
           , match region with
             | None -> `Null
             | Some target ->
                 `Assoc
                   [ "documentId", string target.Browser_lane.document_id
                   ; "nodeId", string target.Browser_lane.node_id ]) ])

let client_binding (scope : Event.browser_scope) fields =
  match scope.source, scope.client_id, field "clientId" fields with
  | Browser_lane.Lane_name.Live, Some expected, Some (`String actual) ->
      if String.equal expected actual then Ok () else Error "browser observation belongs to another client"
  | Browser_lane.Lane_name.Live, (None | Some _), _ -> Error "invalid browser observation identity"

let tab_identity (scope : Event.browser_scope) fields =
  let tab =
    match scope.view with
    | Event.Read ->
        (match field "page" fields with
         | Some (`Assoc page) -> field "tabId" page
         | Some _ | None -> None)
    | Event.Scene _ | Event.Viewport -> field "tabId" fields
  in
  match tab with
  | Some (`Int actual) when actual = scope.tab_id -> Ok ()
  | Some _ | None -> Error "browser observation belongs to another tab"

let scene_identity (scope : Event.browser_scope) fields =
  match scope.view with
  | Event.Read | Event.Viewport -> Ok ()
  | Event.Scene { scene_view; scope = region } ->
      let expected_view =
        match scene_view with Browser_lane.Content -> "content" | Regions -> "regions"
      in
      let actual_view = field "view" fields in
      let actual_scope = field "scope" fields in
      let expected_scope =
        match region with
        | None -> `Null
        | Some target ->
            `Assoc
              [ "documentId", string target.Browser_lane.document_id
              ; "nodeId", string target.Browser_lane.node_id ]
      in
      if actual_view = Some (string expected_view) && actual_scope = Some expected_scope then Ok ()
      else Error "browser observation belongs to another scene view or scope"

type watcher = { scope : Event.browser_scope; mutable previous : string option }

let watch scope = { scope; previous = None }

let observe watcher payload =
  match payload with
  | `Assoc fields ->
      let* () =
        match field "source" fields with
        | Some (`String source)
          when source = Browser_lane.Lane_name.to_wire watcher.scope.source -> Ok ()
        | Some _ | None -> Error "browser observation belongs to another source"
      in
      let* () = client_binding watcher.scope fields in
      let* () = tab_identity watcher.scope fields in
      let* () = scene_identity watcher.scope fields in
      let stable = `Assoc (List.remove_assoc "elapsed_ms" fields) in
      let revision =
        Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string stable)))
      in
      (match watcher.previous with
       | Some previous when String.equal previous revision -> Ok None
       | Some _ | None ->
           watcher.previous <- Some revision;
           Ok (Some { Event.scope = watcher.scope; revision }))
  | _ -> Error "browser observation must be an object"

let read ~config scope =
  let operation host =
    match scope.Event.view with
    | Event.Read -> Browser_addon_view.read host
    | Event.Scene _ -> Browser_addon_view.scene host
    | Event.Viewport -> Browser_addon_view.capture host
  in
  match
    Server_routes_http_browser_surface.view ~config
      ~principal:Lane_addon_call_context.Operator operation (request_json scope)
  with
  | Tool_result.Completed payload -> Ok payload.data
  | Tool_result.Deferred _ -> Error "browser observation is deferred"
  | Tool_result.Failed failure -> Error failure.message

let reader = ref read
let observation_interval_s = 2.0

let start ~sw ~clock ~stop_promise ~scope ~config =
  Eio.Fiber.fork ~sw (fun () ->
      let watcher = watch scope in
      let last_error = ref None in
      let report result =
        match result with
        | Ok None -> last_error := None
        | Ok (Some observation) ->
            last_error := None;
            Event.announce ~base_path:config.Workspace.base_path
              (Event.Browser_observation observation)
        | Error detail ->
            if not (Option.equal String.equal !last_error (Some detail)) then
              Log.Server.warn "browser spectator observation failed: %s" detail;
            last_error := Some detail
      in
      let rec sample () =
        report
          (match !reader ~config scope with
           | Ok payload -> observe watcher payload
           | Error detail -> Error detail);
        Eio.Time.sleep clock observation_interval_s;
        sample ()
      in
      ignore
        (Eio.Fiber.first
           (fun () -> sample ())
           (fun () -> Eio.Promise.await stop_promise; `Observer_closed)))

module For_testing = struct
  let with_reader replacement f =
    let previous = !reader in
    reader := replacement;
    Fun.protect ~finally:(fun () -> reader := previous) f
end
