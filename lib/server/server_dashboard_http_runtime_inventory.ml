open Dashboard_http_helpers

let runtime_endpoint_url_of_transport = function
  | Runtime_schema.Http url -> Some url
  | Runtime_schema.Cli _ -> None
;;

let runtime_transport_string = function
  | Runtime_schema.Http _ -> "http"
  | Runtime_schema.Cli _ -> "cli"
;;

let runtime_http_transport_is_loopback url =
  Uri.of_string url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let runtime_kind_of_transport = function
  | Runtime_schema.Cli _ -> "cli"
  | Runtime_schema.Http url when runtime_http_transport_is_loopback url -> "local"
  | Runtime_schema.Http _ -> "http"
;;

let runtime_dashboard_kind_of_runtime_kind = function
  | "local" -> "local"
  | "cli" -> "cli"
  | _ -> "cloud"
;;

let runtime_auth_kind_of_credential = function
  | None -> "none"
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  | Some (Runtime_schema.Inline _) -> "inline"
;;

let runtime_default_runtime_id () =
  Runtime.get_default_runtime () |> Option.map (fun (rt : Runtime.t) -> rt.id)
;;

let runtime_inventory_entry_json ~default_id (rt : Runtime.t) =
  let runtime_kind = runtime_kind_of_transport rt.provider.transport in
  let models = [ rt.model.api_name ] in
  `Assoc
    [ "provider", `String rt.id
    ; "runtime_id", `String rt.id
    ; "provider_id", `String rt.provider.id
    ; "provider_display_name", `String rt.provider.display_name
    ; "model_id", `String rt.model.id
    ; "model_api_name", `String rt.model.api_name
    ; "protocol", `String rt.provider.protocol
    ; "transport", `String (runtime_transport_string rt.provider.transport)
    ; "kind", `String (runtime_dashboard_kind_of_runtime_kind runtime_kind)
    ; "runtime_kind", `String runtime_kind
    ; "auth_kind", `String (runtime_auth_kind_of_credential rt.provider.credentials)
    ; "status", `String "configured"
    ; "available", `Bool true
    ; "is_default_runtime", `Bool (Option.equal String.equal default_id (Some rt.id))
    ; "max_context", `Int rt.model.max_context
    ; "tools_support", `Bool rt.model.tools_support
    ; "thinking_support", `Bool rt.model.thinking_support
    ; "streaming", `Bool rt.model.streaming
    ; "model_count", `Int (List.length models)
    ; "models", Json_util.json_string_list models
    ; "source", `String Server_runtime_probe.runtime_inventory_source
    ; "endpoint_url", Json_util.string_opt_to_json (runtime_endpoint_url_of_transport rt.provider.transport)
    ; "note", `Null
    ]
;;

let runtime_unique_count values =
  values |> List.sort_uniq String.compare |> List.length
;;

let runtime_assignment_governance_json ~default_id =
  let assignments =
    Runtime.keeper_assignments ()
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let assignment_count = List.length assignments in
  let assigned_runtime_ids = List.map snd assignments in
  let assigned_runtimes = List.sort_uniq String.compare assigned_runtime_ids in
  let assigned_runtime_count = List.length assigned_runtimes in
  let default_assignment_count =
    match default_id with
    | None -> 0
    | Some default_id ->
      assignments
      |> List.filter (fun (_, runtime_id) -> String.equal runtime_id default_id)
      |> List.length
  in
  let librarian_runtime_id = Runtime.librarian_runtime_id () in
  let single_runtime_pin = assignment_count > 1 && assigned_runtime_count = 1 in
  let assignments_match_default =
    assignment_count > 0 && default_assignment_count = assignment_count
  in
  let add_if condition warning warnings =
    if condition then warning :: warnings else warnings
  in
  let warnings =
    []
    |> add_if (assignment_count > 0) "explicit_assignments_present"
    |> add_if single_runtime_pin "single_runtime_assignment_pin"
    |> add_if assignments_match_default "assignments_match_default_runtime"
    |> add_if (Option.is_some librarian_runtime_id) "librarian_runtime_override"
    |> List.rev
  in
  let status =
    if warnings = []
    then "ok"
    else if single_runtime_pin || assignments_match_default || Option.is_some librarian_runtime_id
    then "degraded"
    else "watch"
  in
  `Assoc
    [ "schema", `String "masc.runtime_assignment_governance.v1"
    ; "source", `String Server_runtime_probe.runtime_inventory_source
    ; "status", `String status
    ; "degraded", `Bool (String.equal status "degraded")
    ; "operator_action_required", `Bool (warnings <> [])
    ; "blast_radius",
      `String
        (if assignment_count = 0
         then "default_runtime_only"
         else if single_runtime_pin
         then "single_runtime_assignment_pin"
         else "mixed_runtime_assignments")
    ; "assignment_count", `Int assignment_count
    ; "assigned_runtime_count", `Int assigned_runtime_count
    ; "default_assignment_count", `Int default_assignment_count
    ; "default_runtime_id", Json_util.string_opt_to_json default_id
    ; "librarian_runtime_id", Json_util.string_opt_to_json librarian_runtime_id
    ; "warnings", Json_util.json_string_list warnings
    ; "assigned_runtimes", Json_util.json_string_list assigned_runtimes
    ; ( "assignments"
      , `List
          (List.map
             (fun (keeper_name, runtime_id) ->
                `Assoc
                  [ "keeper", `String keeper_name
                  ; "runtime_id", `String runtime_id
                  ; ( "matches_default"
                    , `Bool (Option.equal String.equal default_id (Some runtime_id)) )
                  ])
             assignments) )
    ]
;;

let runtime_inventory_json () =
  let runtimes = Runtime.get_runtimes () in
  let default_id = runtime_default_runtime_id () in
  let kind_of_runtime (rt : Runtime.t) =
    runtime_kind_of_transport rt.provider.transport
    |> runtime_dashboard_kind_of_runtime_kind
  in
  let count_models kind =
    runtimes
    |> List.filter (fun rt -> String.equal (kind_of_runtime rt) kind)
    |> List.length
  in
  let provider_ids = List.map (fun (rt : Runtime.t) -> rt.provider.id) runtimes in
  `Assoc
    [ "updated_at", `String (Masc_domain.now_iso ())
    ; "source", `String Server_runtime_probe.runtime_inventory_source
    ; "config_path", Json_util.string_opt_to_json (Runtime.config_path ())
    ; ( "summary"
      , `Assoc
          [ "providers", `Int (runtime_unique_count provider_ids)
          ; "runtimes", `Int (List.length runtimes)
          ; "local_models", `Int (count_models "local")
          ; "cloud_models", `Int (count_models "cloud")
          ; "cli_models", `Int (count_models "cli")
          ; "default_runtime_id", Json_util.string_opt_to_json default_id
          ] )
    ; "assignment_governance", runtime_assignment_governance_json ~default_id
    ; "providers", `List (List.map (runtime_inventory_entry_json ~default_id) runtimes)
    ]
;;
