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
  | World_memory
  | Play_seats
  | Dashboard_observation of Sse_event.Types.dashboard_observation_changed_payload
  | Play_room of { machine : Machine_lane.t }
  | Lane_addons of { instance_id : string }
  | Browser_observation of browser_observation

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
    | World_memory
    | Play_seats
    | Dashboard_observation
    | Play_room
    | Lane_addons
    | Browser_observation
  [@@deriving enumerate]

  let to_wire = function
    | Repositories -> "repositories"
    | Verification_requests -> "verification_requests"
    | Keeper_metrics -> "keeper_metrics"
    | Harness_verdicts -> "harness_verdicts"
    | Goals -> "goals"
    | Runtime_config -> "runtime_config"
    | Connectors -> "connectors"
    | Keeper_oauth_attempts -> "keeper_oauth_attempts"
    | Skill_activations -> "skill_activations"
    | Skill_catalog -> "skill_catalog"
    | Clients -> "clients"
    | Account_emails -> "account_emails"
    | Provider_usage -> "provider_usage"
    | Provider_standing -> "provider_standing"
    | Keeper_costs -> "keeper_costs"
    | Workspace_health -> "workspace_health"
    | Runtime_probe -> "runtime_probe"
    | Runtime_metrics -> "runtime_metrics"
    | Lanes -> "lanes"
    | Machine_live -> "machine_live"
    | Memory_health -> "memory_health"
    | World_memory -> "world_memory"
    | Play_seats -> "play_seats"
    | Dashboard_observation -> "dashboard_observation"
    | Play_room -> "play_room"
    | Lane_addons -> "lane_addons"
    | Browser_observation -> "browser_observation"

  (* [to_wire] is the one place a dataset name is spelled; [of_wire] reads the
     names back through [all]. *)
  let of_wire wire = List.find_opt (fun kind -> String.equal (to_wire kind) wire) all
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
  | World_memory -> Kind.World_memory
  | Play_seats -> Kind.Play_seats
  | Dashboard_observation _ -> Kind.Dashboard_observation
  | Play_room _ -> Kind.Play_room
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
  | Workspace_health | Runtime_probe | Runtime_metrics | Lanes | World_memory | Play_seats -> []
  | Machine_live { machine } | Play_room { machine } ->
      [ "machine", `String (Machine_lane.to_wire machine) ]
  | Lane_addons { instance_id } -> [ "instance_id", `String instance_id ]
  | Browser_observation { scope; revision } ->
      browser_scope_fields scope @ [ "revision", `String revision ]
  | Memory_health { keeper }
  | Keeper_metrics { keeper } | Keeper_oauth_attempts { keeper } | Skill_activations { keeper } ->
    [ "keeper", `String keeper ]
  | Dashboard_observation payload ->
      Sse_event.dashboard_observation_changed_payload_to_json payload
      |> Yojson.Safe.Util.to_assoc

let keeper_of_fields name fields =
  match List.assoc_opt "keeper" fields with
  | Some (`String keeper) when not (String.equal keeper "") -> Ok keeper
  | Some _ | None -> Error (event_type ^ " " ^ name ^ " names no keeper")

let instance_of_fields fields =
  match List.assoc_opt "instance_id" fields with
  | Some (`String instance_id) when not (String.equal instance_id "") -> Ok instance_id
  | Some _ | None -> Error (event_type ^ " lane_addons names no instance")

let machine_of_fields fields =
  let machine =
    match List.assoc_opt "machine" fields with
    | Some (`String name) -> Machine_lane.of_wire name
    | Some _ | None -> None
  in
  Option.to_result ~none:(event_type ^ " machine_live names no known machine") machine

let of_fields fields =
  match List.assoc_opt "dataset" fields with
  | Some (`String name) ->
    (match Kind.of_wire name with
     | None -> Error (event_type ^ " names an unknown dataset " ^ name)
     | Some Kind.Repositories -> Ok Repositories
     | Some Kind.Verification_requests -> Ok Verification_requests
     | Some Kind.Keeper_metrics ->
       Result.map (fun keeper -> Keeper_metrics { keeper }) (keeper_of_fields name fields)
     | Some Kind.Harness_verdicts -> Ok Harness_verdicts
     | Some Kind.Goals -> Ok Goals
     | Some Kind.Runtime_config -> Ok Runtime_config
     | Some Kind.Connectors -> Ok Connectors
     | Some Kind.Keeper_oauth_attempts ->
       Result.map (fun keeper -> Keeper_oauth_attempts { keeper }) (keeper_of_fields name fields)
     | Some Kind.Skill_activations ->
       Result.map (fun keeper -> Skill_activations { keeper }) (keeper_of_fields name fields)
     | Some Kind.Skill_catalog -> Ok Skill_catalog
     | Some Kind.Clients -> Ok Clients
     | Some Kind.Account_emails -> Ok Account_emails
     | Some Kind.Provider_usage -> Ok Provider_usage
     | Some Kind.Provider_standing -> Ok Provider_standing
     | Some Kind.Keeper_costs -> Ok Keeper_costs
     | Some Kind.Workspace_health -> Ok Workspace_health
     | Some Kind.Runtime_probe -> Ok Runtime_probe
     | Some Kind.Runtime_metrics -> Ok Runtime_metrics
     | Some Kind.Lanes -> Ok Lanes
     | Some Kind.Machine_live ->
       Result.map (fun machine -> Machine_live { machine }) (machine_of_fields fields)
     | Some Kind.Memory_health ->
       Result.map (fun keeper -> Memory_health { keeper }) (keeper_of_fields name fields)
     | Some Kind.World_memory -> Ok World_memory
     | Some Kind.Play_seats -> Ok Play_seats
     | Some Kind.Dashboard_observation ->
       Sse_event.dashboard_observation_changed_payload_of_json (`Assoc fields)
       |> Result.map (fun payload -> Dashboard_observation payload)
     | Some Kind.Play_room ->
       Result.map (fun machine -> Play_room { machine }) (machine_of_fields fields)
     | Some Kind.Lane_addons ->
       Result.map (fun instance_id -> Lane_addons { instance_id }) (instance_of_fields fields)
     | Some Kind.Browser_observation ->
       Result.map (fun observation -> Browser_observation observation)
          (browser_observation_of_fields fields))
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

let announce_dashboard_observation ~base_path ~scope topic =
  announce ~base_path
    (Dashboard_observation { topic; scope })

let announce_lane_addon ~base_path ~instance_id ~visibility =
  announce_with_fields ~base_path [ "visibility", visibility ]
    (Lane_addons { instance_id })

let install_store_observers () =
  Repo_store.install_written_observer (fun ~base_path -> announce ~base_path Repositories);
  Keeper_oauth_pending.install_change_observer (fun ~base_path ~keeper ->
    announce ~base_path (Keeper_oauth_attempts { keeper }));
  Workspace_agent_record.install_rows_changed_observer (fun config ->
    announce ~base_path:config.Workspace_utils_backend_setup.base_path Clients)
