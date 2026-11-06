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
  | Account_emails
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
let account_emails_name = "account_emails"
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

module Kind = struct
  type t =
    | Repositories
    | Verification_requests
    | Keeper_metrics
    | Harness_verdicts
    | Goals
    | Runtime_config
    | Connectors
    | Keeper_oauth_attempts
    | Skill_activations
    | Skill_catalog
    | Clients
    | Account_emails
    | Provider_usage
    | Provider_standing
    | Keeper_costs
    | Workspace_health
    | Runtime_probe
    | Runtime_metrics
    | Lanes
    | Machine_live
    | Memory_health
    | Lane_addons
    | Browser_observation

  let to_wire = function
    | Repositories -> repositories_name
    | Verification_requests -> verification_requests_name
    | Keeper_metrics -> keeper_metrics_name
    | Harness_verdicts -> harness_verdicts_name
    | Goals -> goals_name
    | Runtime_config -> runtime_config_name
    | Connectors -> connectors_name
    | Keeper_oauth_attempts -> keeper_oauth_attempts_name
    | Skill_activations -> skill_activations_name
    | Skill_catalog -> skill_catalog_name
    | Clients -> clients_name
    | Account_emails -> account_emails_name
    | Provider_usage -> provider_usage_name
    | Provider_standing -> provider_standing_name
    | Keeper_costs -> keeper_costs_name
    | Workspace_health -> workspace_health_name
    | Runtime_probe -> runtime_probe_name
    | Runtime_metrics -> runtime_metrics_name
    | Lanes -> lanes_name
    | Machine_live -> machine_live_name
    | Memory_health -> memory_health_name
    | Lane_addons -> lane_addons_name
    | Browser_observation -> browser_observation_name

  let of_wire = function
    | wire when String.equal wire repositories_name -> Some Repositories
    | wire when String.equal wire verification_requests_name -> Some Verification_requests
    | wire when String.equal wire keeper_metrics_name -> Some Keeper_metrics
    | wire when String.equal wire harness_verdicts_name -> Some Harness_verdicts
    | wire when String.equal wire goals_name -> Some Goals
    | wire when String.equal wire runtime_config_name -> Some Runtime_config
    | wire when String.equal wire connectors_name -> Some Connectors
    | wire when String.equal wire keeper_oauth_attempts_name -> Some Keeper_oauth_attempts
    | wire when String.equal wire skill_activations_name -> Some Skill_activations
    | wire when String.equal wire skill_catalog_name -> Some Skill_catalog
    | wire when String.equal wire clients_name -> Some Clients
    | wire when String.equal wire account_emails_name -> Some Account_emails
    | wire when String.equal wire provider_usage_name -> Some Provider_usage
    | wire when String.equal wire provider_standing_name -> Some Provider_standing
    | wire when String.equal wire keeper_costs_name -> Some Keeper_costs
    | wire when String.equal wire workspace_health_name -> Some Workspace_health
    | wire when String.equal wire runtime_probe_name -> Some Runtime_probe
    | wire when String.equal wire runtime_metrics_name -> Some Runtime_metrics
    | wire when String.equal wire lanes_name -> Some Lanes
    | wire when String.equal wire machine_live_name -> Some Machine_live
    | wire when String.equal wire memory_health_name -> Some Memory_health
    | wire when String.equal wire lane_addons_name -> Some Lane_addons
    | wire when String.equal wire browser_observation_name -> Some Browser_observation
    | _ -> None
end

let kind = function
  | Repositories -> Kind.Repositories
  | Verification_requests -> Kind.Verification_requests
  | Keeper_metrics _ -> Kind.Keeper_metrics
  | Harness_verdicts -> Kind.Harness_verdicts
  | Goals -> Kind.Goals
  | Runtime_config -> Kind.Runtime_config
  | Connectors -> Kind.Connectors
  | Keeper_oauth_attempts _ -> Kind.Keeper_oauth_attempts
  | Skill_activations _ -> Kind.Skill_activations
  | Skill_catalog -> Kind.Skill_catalog
  | Clients -> Kind.Clients
  | Account_emails -> Kind.Account_emails
  | Provider_usage -> Kind.Provider_usage
  | Provider_standing -> Kind.Provider_standing
  | Keeper_costs -> Kind.Keeper_costs
  | Workspace_health -> Kind.Workspace_health
  | Runtime_probe -> Kind.Runtime_probe
  | Runtime_metrics -> Kind.Runtime_metrics
  | Lanes -> Kind.Lanes
  | Machine_live _ -> Kind.Machine_live
  | Memory_health _ -> Kind.Memory_health
  | Lane_addons _ -> Kind.Lane_addons
  | Browser_observation _ -> Kind.Browser_observation

let dataset_to_wire dataset = Kind.to_wire (kind dataset)
let dataset_name = dataset_to_wire

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
    | `Null -> "null"
    | (`Assoc _ | `List _ | `Bool _ | `Float _ | `Intlit _) as json ->
        Yojson.Safe.to_string json
  in
  Uri.encoded_of_query
    (browser_scope_fields scope
     |> List.filter (fun (name, json) -> not (String.equal name "clientId" && json = `Null))
     |> List.map (fun (name, json) -> name, [ value json ]))

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
          | Some json -> Browser_lane.node_ref_of_json json |> Result.map Option.some
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

let keeper_field = function
  | Repositories | Verification_requests | Harness_verdicts | Goals | Runtime_config | Connectors
  | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing | Keeper_costs
  | Workspace_health | Runtime_probe | Runtime_metrics | Lanes -> []
  | Machine_live { machine } -> [ "machine", `String (Machine_lane.to_wire machine) ]
  | Lane_addons { instance_id } -> [ "instance_id", `String instance_id ]
  | Browser_observation { scope; revision } ->
      browser_scope_fields scope @ [ "revision", `String revision ]
  | Memory_health { keeper }
  | Keeper_metrics { keeper } | Keeper_oauth_attempts { keeper } | Skill_activations { keeper } ->
    [ "keeper", `String keeper ]

let keeper_of_fields name fields =
  match List.assoc_opt "keeper" fields with
  | Some (`String keeper) when not (String.equal keeper "") -> Ok keeper
  | Some _ | None -> Error (event_type ^ " " ^ name ^ " names no keeper")

let instance_of_fields fields =
  match List.assoc_opt "instance_id" fields with
  | Some (`String instance_id) when not (String.equal instance_id "") -> Ok instance_id
  | Some _ | None -> Error (event_type ^ " lane_addons names no instance")

let machine_of_fields fields =
  match List.assoc_opt "machine" fields with
  | Some (`String "msx") -> Ok Machine_lane.Msx
  | Some (`String "dos") -> Ok Machine_lane.Dos
  | Some _ | None -> Error (event_type ^ " machine_live names no known machine")

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
  | Some (`String name) when String.equal name account_emails_name -> Ok Account_emails
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

let announce_with_fields ~base_path fields dataset =
  let name = dataset_name dataset in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String event_type; "dataset", `String name ]
         @ keeper_field dataset @ fields
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

let announce ~base_path dataset = announce_with_fields ~base_path [] dataset

let announce_lane_addon ~base_path ~instance_id ~visibility =
  announce_with_fields ~base_path [ "visibility", visibility ]
    (Lane_addons { instance_id })

let install_store_observers () =
  Repo_store.install_written_observer (fun ~base_path -> announce ~base_path Repositories);
  Keeper_oauth_pending.install_change_observer (fun ~base_path ~keeper ->
    announce ~base_path (Keeper_oauth_attempts { keeper }));
  Workspace_agent_record.install_rows_changed_observer (fun config ->
    announce ~base_path:config.Workspace_utils_backend_setup.base_path Clients)
