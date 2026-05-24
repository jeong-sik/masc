(** Operator query-JSON metadata helpers, extracted from
    [server_dashboard_http_core.ml]. Pure builders for the
    [/api/v1/operator] + [/api/v1/operator/digest] response envelopes
    (retention metadata, query echo, surface wrapping, default queries).
    No side effects, no I/O. *)

open Masc_domain

(* Sibling dependencies — already extracted in earlier godfile decomp PRs. *)
let operator_generated_at_iso = Server_dashboard_http_core_json.operator_generated_at_iso
let operator_cache_json = Server_dashboard_http_core_json.operator_cache_json

let operator_refresh_interval_s = Server_dashboard_http_core_operator.operator_refresh_interval_s
let dashboard_request_timeout_s = Server_dashboard_http_core_cache.dashboard_request_timeout_s

let operator_retention_json ~(config : Coord.config) ~scope ~producer =
  `Assoc
    [ "scope", `String scope
    ; "coordination_root", `String config.base_path
    ; "workspace_path", `String config.workspace_path
    ; "producer", `String producer
    ; "store_kind", `String "process_cache"
    ; "cache_surface", `String "Server_dashboard_http_core.cached_surface"
    ; "http_swr_ttl_s", `Float 5.0
    ; "background_refresh_interval_s", `Float operator_refresh_interval_s
    ; "request_timeout_s", `Float dashboard_request_timeout_s
    ; ( "cache_policy"
      , `String
          "default route uses proactive cached_surface; parameterized route uses HTTP stale-while-revalidate"
      )
    ]
;;

let operator_snapshot_query_json ~actor ~view ~include_messages ~include_keepers
    ~lightweight_summary ~default_summary_request =
  let effective_view =
    match view with
    | Some value -> value
    | None -> if default_summary_request then "summary" else "full"
  in
  `Assoc
    [ "actor", Json_util.string_opt_to_json actor
    ; "view", Json_util.string_opt_to_json view
    ; "effective_actor", `String (Option.value ~default:"dashboard" actor)
    ; "effective_view", `String effective_view
    ; "include_messages", `Bool include_messages
    ; "include_keepers", `Bool include_keepers
    ; "lightweight_summary", `Bool lightweight_summary
    ; "default_summary_request", `Bool default_summary_request
    ]
;;

let operator_digest_query_json ~actor ~target_type ~target_id ~include_workers
    ~effective_target_type ~default_namespace_request =
  `Assoc
    [ "actor", Json_util.string_opt_to_json actor
    ; "target_type", Json_util.string_opt_to_json target_type
    ; "target_id", Json_util.string_opt_to_json target_id
    ; "effective_target_type", `String effective_target_type
    ; "include_workers", Json_util.bool_opt_to_json include_workers
    ; "default_namespace_request", `Bool default_namespace_request
    ]
;;

let with_operator_surface_metadata
    ~config
    ?cache_key
    ~dashboard_surface
    ~source
    ~scope
    ~producer
    ~query
    json =
  match json with
  | `Assoc fields ->
    let generated_at = operator_generated_at_iso json in
    let metadata =
      [ "dashboard_surface", `String dashboard_surface
      ; "source", `String source
      ; "generated_at_iso", `String generated_at
      ; "retention", operator_retention_json ~config ~scope ~producer
      ; "query", query
      ; "cache", operator_cache_json ?cache_key ~scope json
      ]
    in
    let metadata_keys =
      [ "dashboard_surface"
      ; "source"
      ; "generated_at_iso"
      ; "retention"
      ; "query"
      ; "cache"
      ]
    in
    let fields =
      List.filter (fun (key, _) -> not (List.mem key metadata_keys)) fields
    in
    `Assoc (metadata @ fields)
  | other -> other
;;

let with_operator_snapshot_metadata ~config ?cache_key ~query json =
  with_operator_surface_metadata
    ~config
    ?cache_key
    ~dashboard_surface:"/api/v1/operator"
    ~source:"operator_snapshot_read_model"
    ~scope:"operator_snapshot"
    ~producer:"Operator_control.snapshot_json"
    ~query
    json
;;

let with_operator_digest_metadata ~config ?cache_key ~query json =
  with_operator_surface_metadata
    ~config
    ?cache_key
    ~dashboard_surface:"/api/v1/operator/digest"
    ~source:"operator_digest_read_model"
    ~scope:"operator_digest"
    ~producer:"Operator_control.digest_json"
    ~query
    json
;;

let operator_snapshot_default_query () =
  operator_snapshot_query_json
    ~actor:None
    ~view:None
    ~include_messages:true
    ~include_keepers:true
    ~lightweight_summary:true
    ~default_summary_request:true
;;

let operator_digest_default_query () =
  operator_digest_query_json
    ~actor:None
    ~target_type:None
    ~target_id:None
    ~include_workers:None
    ~effective_target_type:"root"
    ~default_namespace_request:true
;;
