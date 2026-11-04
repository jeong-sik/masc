let event_type = "workspace_dataset_changed"

type browser_view =
  | Read
  | Scene of { scene_view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
  | Viewport

type browser_scope = {
  source : Browser_lane.Lane_name.t;
  client_id : string option;
  tab_id : int;
  view : browser_view;
}

type browser_observation = { scope : browser_scope; revision : string }

type dataset =
  | Repositories
  | Verification_requests
  | Keeper_metrics of { keeper : string }
  | Harness_verdicts
  | Goals
  | Runtime_config
  | Connectors
  | Keeper_oauth_attempts of { keeper : string }
  | Skill_activations of { keeper : string }
  | Skill_catalog
  | Clients
  | Provider_usage
  | Provider_standing
  | Keeper_costs
  | Workspace_health
  | Runtime_probe
  | Runtime_metrics
  | Lanes
  | Machine_live of { machine : Machine_lane.t }
  | Memory_health of { keeper : string }
  | Lane_addons of { instance_id : string }
  | Browser_observation of browser_observation

let repositories_name = "repositories"
let verification_requests_name = "verification_requests"
let keeper_metrics_name = "keeper_metrics"
let harness_verdicts_name = "harness_verdicts"
let goals_name = "goals"
let runtime_config_name = "runtime_config"
let connectors_name = "connectors"
let keeper_oauth_attempts_name = "keeper_oauth_attempts"
let skill_activations_name = "skill_activations"
let skill_catalog_name = "skill_catalog"
let clients_name = "clients"
let provider_usage_name = "provider_usage"
let provider_standing_name = "provider_standing"
let keeper_costs_name = "keeper_costs"
let workspace_health_name = "workspace_health"
let runtime_probe_name = "runtime_probe"
let runtime_metrics_name = "runtime_metrics"
let lanes_name = "lanes"
let machine_live_name = "machine_live"
let memory_health_name = "memory_health"
let lane_addons_name = "lane_addons"
let browser_observation_name = "browser_observation"

let scene_view_name = function
  | Browser_lane.Content -> "content"
  | Browser_lane.Regions -> "regions"

let region_json (target : Browser_lane.node_ref) =
  `Assoc
    [ "documentId", `String target.document_id
    ; "nodeId", `String target.node_id ]

let browser_scope_fields (scope : browser_scope) =
  [ "source", `String (Browser_lane.Lane_name.to_wire scope.source)
  ; ( "clientId"
    , match scope.client_id with Some client -> `String client | None -> `Null )
  ; "tabId", `Int scope.tab_id ]
  @
  match scope.view with
  | Read -> [ "view", `String "read" ]
  | Viewport -> [ "view", `String "viewport" ]
  | Scene { scene_view; scope } ->
      [ "view", `String "scene"
      ; "sceneView", `String (scene_view_name scene_view)
      ; ( "scope"
        , match scope with Some target -> region_json target | None -> `Null ) ]

let browser_scope_query scope =
  let value = function
    | `String text -> text
    | `Int number -> string_of_int number
    | `Null -> ""
    | (`Assoc _ | `List _ | `Bool _ | `Float _ | `Intlit _) as json ->
        Yojson.Safe.to_string json
  in
  Uri.encoded_of_query
    (List.map (fun (name, json) -> name, [ value json ]) (browser_scope_fields scope))

let browser_scope_of_fields fields =
  let ( let* ) = Result.bind in
  let* source =
    match List.assoc_opt "source" fields with
    | Some (`String source) ->
        (match Browser_lane.Lane_name.of_wire source with
         | Some source -> Ok source
         | None -> Error (event_type ^ " browser_observation names an unknown source"))
    | Some _ | None -> Error (event_type ^ " browser_observation names no source")
  in
  let* client_id =
    match List.assoc_opt "clientId" fields with
    | Some `Null -> Ok None
    | Some (`String client) ->
        Browser_lane.client_id_of_string client
        |> Result.map (fun _ -> Some client)
        |> Result.map_error (fun detail -> event_type ^ " browser_observation: " ^ detail)
    | Some _ | None -> Error (event_type ^ " browser_observation names no client identity")
  in
  let* () =
    match source, client_id with
    | Browser_lane.Lane_name.Live, Some _ -> Ok ()
    | Browser_lane.Lane_name.Live, None ->
        Error (event_type ^ " browser_observation requires a live client")
    | (Browser_lane.Lane_name.Automation | Browser_lane.Lane_name.Stagehand), None -> Ok ()
    | (Browser_lane.Lane_name.Automation | Browser_lane.Lane_name.Stagehand), Some _ ->
        Error (event_type ^ " browser_observation gives an owned browser a client")
  in
  let* tab_id =
    match List.assoc_opt "tabId" fields with
    | Some (`Int tab_id) when tab_id >= 0 -> Ok tab_id
    | Some _ | None -> Error (event_type ^ " browser_observation names no valid tab")
  in
  let* view =
    match List.assoc_opt "view" fields with
    | Some (`String "read") -> Ok Read
    | Some (`String "viewport") -> Ok Viewport
    | Some (`String "scene") ->
        let* scene_view =
          match List.assoc_opt "sceneView" fields with
          | Some (`String "content") -> Ok Browser_lane.Content
          | Some (`String "regions") -> Ok Browser_lane.Regions
          | Some _ | None -> Error (event_type ^ " browser_observation names no scene view")
        in
        let* scope =
          match List.assoc_opt "scope" fields with
          | Some `Null -> Ok None
          | Some json -> Browser_scene.scope_of_json json |> Result.map Option.some
          | None -> Error (event_type ^ " browser_observation names no scene scope")
        in
        Ok (Scene { scene_view; scope })
    | Some _ | None -> Error (event_type ^ " browser_observation names no read view")
  in
  Ok { source; client_id; tab_id; view }

let browser_observation_of_fields fields =
  let ( let* ) = Result.bind in
  let* scope = browser_scope_of_fields fields in
  let* revision =
    match List.assoc_opt "revision" fields with
    | Some (`String revision)
      when String.length revision = 64
           && String.for_all
                (fun char ->
                  (Char.compare char '0' >= 0 && Char.compare char '9' <= 0)
                  || (Char.compare char 'a' >= 0 && Char.compare char 'f' <= 0))
                revision -> Ok revision
    | Some _ | None -> Error (event_type ^ " browser_observation names no revision")
  in
  Ok { scope; revision }

let dataset_name = function
  | Repositories -> repositories_name
  | Verification_requests -> verification_requests_name
  | Keeper_metrics _ -> keeper_metrics_name
  | Harness_verdicts -> harness_verdicts_name
  | Goals -> goals_name
  | Runtime_config -> runtime_config_name
  | Connectors -> connectors_name
  | Keeper_oauth_attempts _ -> keeper_oauth_attempts_name
  | Skill_activations _ -> skill_activations_name
  | Skill_catalog -> skill_catalog_name
  | Clients -> clients_name
  | Provider_usage -> provider_usage_name
  | Provider_standing -> provider_standing_name
  | Keeper_costs -> keeper_costs_name
  | Workspace_health -> workspace_health_name
  | Runtime_probe -> runtime_probe_name
  | Runtime_metrics -> runtime_metrics_name
  | Lanes -> lanes_name
  | Machine_live _ -> machine_live_name
  | Memory_health _ -> memory_health_name
  | Lane_addons _ -> lane_addons_name
  | Browser_observation _ -> browser_observation_name
;;

let keeper_field = function
  | Repositories | Verification_requests | Harness_verdicts | Goals | Runtime_config | Connectors
  | Skill_catalog | Clients | Provider_usage | Provider_standing | Keeper_costs
  | Workspace_health | Runtime_probe | Runtime_metrics | Lanes -> []
  | Machine_live { machine } -> [ "machine", `String (Machine_lane.to_wire machine) ]
  | Lane_addons { instance_id } -> [ "instance_id", `String instance_id ]
  | Browser_observation { scope; revision } ->
      browser_scope_fields scope @ [ "revision", `String revision ]
  | Memory_health { keeper }
  | Keeper_metrics { keeper } | Keeper_oauth_attempts { keeper } | Skill_activations { keeper } ->
    [ "keeper", `String keeper ]
;;

let keeper_of_fields name fields =
  match List.assoc_opt "keeper" fields with
  | Some (`String keeper) when not (String.equal keeper "") -> Ok keeper
  | Some _ | None -> Error (event_type ^ " " ^ name ^ " names no keeper")
;;

let instance_of_fields fields =
  match List.assoc_opt "instance_id" fields with
  | Some (`String instance_id) when not (String.equal instance_id "") -> Ok instance_id
  | Some _ | None -> Error (event_type ^ " lane_addons names no instance")
;;

let machine_of_fields fields =
  match List.assoc_opt "machine" fields with
  | Some (`String "msx") -> Ok Machine_lane.Msx
  | Some (`String "dos") -> Ok Machine_lane.Dos
  | Some _ | None -> Error (event_type ^ " machine_live names no known machine")
;;

let of_fields fields =
  match List.assoc_opt "dataset" fields with
  | Some (`String name) when String.equal name repositories_name -> Ok Repositories
  | Some (`String name) when String.equal name verification_requests_name ->
    Ok Verification_requests
  | Some (`String name) when String.equal name harness_verdicts_name -> Ok Harness_verdicts
  | Some (`String name) when String.equal name goals_name -> Ok Goals
  | Some (`String name) when String.equal name runtime_config_name -> Ok Runtime_config
  | Some (`String name) when String.equal name connectors_name -> Ok Connectors
  | Some (`String name) when String.equal name skill_catalog_name -> Ok Skill_catalog
  | Some (`String name) when String.equal name clients_name -> Ok Clients
  | Some (`String name) when String.equal name provider_usage_name -> Ok Provider_usage
  | Some (`String name) when String.equal name provider_standing_name -> Ok Provider_standing
  | Some (`String name) when String.equal name keeper_costs_name -> Ok Keeper_costs
  | Some (`String name) when String.equal name workspace_health_name -> Ok Workspace_health
  | Some (`String name) when String.equal name runtime_probe_name -> Ok Runtime_probe
  | Some (`String name) when String.equal name runtime_metrics_name -> Ok Runtime_metrics
  | Some (`String name) when String.equal name lanes_name -> Ok Lanes
  | Some (`String name) when String.equal name machine_live_name ->
    Result.map (fun machine -> Machine_live { machine }) (machine_of_fields fields)
  | Some (`String name) when String.equal name lane_addons_name ->
    Result.map (fun instance_id -> Lane_addons { instance_id }) (instance_of_fields fields)
  | Some (`String name) when String.equal name browser_observation_name ->
    Result.map (fun observation -> Browser_observation observation)
      (browser_observation_of_fields fields)
  | Some (`String name) when String.equal name memory_health_name ->
    Result.map (fun keeper -> Memory_health { keeper }) (keeper_of_fields name fields)
  | Some (`String name) when String.equal name keeper_metrics_name ->
    Result.map (fun keeper -> Keeper_metrics { keeper }) (keeper_of_fields name fields)
  | Some (`String name) when String.equal name keeper_oauth_attempts_name ->
    Result.map (fun keeper -> Keeper_oauth_attempts { keeper }) (keeper_of_fields name fields)
  | Some (`String name) when String.equal name skill_activations_name ->
    Result.map (fun keeper -> Skill_activations { keeper }) (keeper_of_fields name fields)
  | Some (`String name) -> Error (event_type ^ " names an unknown dataset " ^ name)
  | Some _ | None -> Error (event_type ^ " carries no dataset name")
;;

let announce ~base_path dataset =
  let name = dataset_name dataset in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String event_type; "dataset", `String name ]
         @ keeper_field dataset
         @ [ "ts_unix", `Float (Time_compat.now ()) ]))
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", event_type ^ ":" ^ name ]
      ();
    Log.Keeper.warn "workspace_dataset_event: %s %s failed: %s" event_type name
      (Printexc.to_string exn)
;;

let install_store_observers () =
  Repo_store.install_written_observer (fun ~base_path -> announce ~base_path Repositories);
  Keeper_oauth_pending.install_change_observer (fun ~base_path ~keeper ->
    announce ~base_path (Keeper_oauth_attempts { keeper }));
  Workspace_agent_record.install_rows_changed_observer (fun config ->
    announce ~base_path:config.Workspace_utils_backend_setup.base_path Clients)
;;
