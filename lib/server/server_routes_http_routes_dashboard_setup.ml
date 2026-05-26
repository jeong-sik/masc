
open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream
module Keeper_api = Server_dashboard_http_keeper_api

(* Cascade profile gate extracted to
   [Server_dashboard_cascade_profile_gate] (godfile decomp PR #18027).
   PR #18027 deleted this surface but left 3 unqualified call sites in
   the parent dashboard route file (lines 1173, 1208, 1209). Restored
   via module alias + local function aliases that map the old
   unqualified names to the new [_profile_gate] surface. *)
module Cascade_profile_gate = Server_dashboard_cascade_profile_gate

let cascade_profile_gate = Cascade_profile_gate.compute
let available_cascade_profiles = Cascade_profile_gate.available_profiles
let invalid_cascade_profiles = Cascade_profile_gate.invalid_profiles
let invalid_cascade_assignment_profiles =
  Cascade_profile_gate.invalid_assignment_profiles

let option_int_json = function
  | Some value -> `Int value
  | None -> `Null

let option_string_json = function
  | Some value -> `String value
  | None -> `Null

(* Dashboard /logs JSON builder extracted to
   [Server_dashboard_logs_json] (godfile decomp). *)
let dashboard_logs_store_path = Server_dashboard_logs_json.store_path
let dashboard_logs_json = Server_dashboard_logs_json.build

module Provider_logs = Server_routes_http_dashboard_provider_logs


(* RFC-0138 Phase 3 Step 5 — [telemetry_summary_cache_key] deleted
   along with [Dashboard_cache.get_or_compute] from the cold-start
   fallback path.  After Step 1/2/3 wired snapshot reads in front of
   compute, the fallback runs at most once per process and a cache
   slot is not worth keeping live.  See
   [Server_dashboard_snapshot_select.select_telemetry_summary_json]. *)

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some value when value <> "" -> Some value
  | _ -> None

let oas_telemetry_limit_param req =
  Server_utils.int_query_param req "limit" ~default:50
  |> Server_utils.clamp ~min_v:1 ~max_v:200

let oas_telemetry_provider_param req = trimmed_query_param req "provider"

(* sync_keeper_cascade_meta extracted to
   [Server_routes_http_routes_dashboard_cascade_meta] (godfile decomp). *)
let sync_keeper_cascade_meta = Server_routes_http_routes_dashboard_cascade_meta.sync_keeper_cascade_meta
(* Dashboard dev-token cluster extracted to
   [Server_routes_http_dashboard_dev_token] (godfile decomp). *)

let dashboard_dev_actor_name = Server_routes_http_dashboard_dev_token.dashboard_dev_actor_name
let dashboard_dev_token_path = Server_routes_http_dashboard_dev_token.dashboard_dev_token_path
let legacy_dashboard_dev_token_path = Server_routes_http_dashboard_dev_token.legacy_dashboard_dev_token_path
let remove_dashboard_dev_token_file_if_exists = Server_routes_http_dashboard_dev_token.remove_dashboard_dev_token_file_if_exists

type dashboard_dev_token_candidate = Server_routes_http_dashboard_dev_token.dashboard_dev_token_candidate =
  | Reusable of string
  | Rotate

let classify_dashboard_dev_token_candidate = Server_routes_http_dashboard_dev_token.classify_dashboard_dev_token_candidate
let read_reusable_dashboard_dev_token = Server_routes_http_dashboard_dev_token.read_reusable_dashboard_dev_token
let persist_dashboard_dev_token = Server_routes_http_dashboard_dev_token.persist_dashboard_dev_token
let mint_dashboard_dev_token = Server_routes_http_dashboard_dev_token.mint_dashboard_dev_token
let ensure_dashboard_dev_token = Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token

let executable_file_exists path =
  try
    Sys.file_exists path
    && not (Sys.is_directory path)
    &&
    (Unix.access path [ Unix.X_OK ];
     true)
  with _ -> false

let append_unique candidate acc =
  match candidate with
  | None | Some "" -> acc
  | Some path when List.mem path acc -> acc
  | Some path -> acc @ [ path ]

let dashboard_doctor_self_bin () =
  let argv0 =
    if Array.length Sys.argv = 0 then None else Some Sys.argv.(0)
  in
  let argv0_absolute =
    match argv0 with
    | Some path when not (Filename.is_relative path) -> Some path
    | Some path -> Some (Filename.concat (Sys.getcwd ()) path)
    | None -> None
  in
  let build = Build_identity.current () in
  let build_root_bin =
    build.repo_root
    |> Option.map (fun root ->
      Filename.concat root "_build/default/bin/main_eio.exe")
  in
  []
  |> append_unique (Sys.getenv_opt "MASC_MAIN_EIO_EXE")
  |> append_unique argv0
  |> append_unique argv0_absolute
  |> append_unique (Some build.executable_path)
  |> append_unique build_root_bin
  |> List.find_opt executable_file_exists
  |> Option.value ~default:(Option.value argv0 ~default:build.executable_path)

let dashboard_doctor_degraded_json ~self_bin ~exn =
  let message = Printexc.to_string exn in
  Yojson.Safe.to_string
    (`Assoc
      [ "title", `String "MASC Doctor (dashboard degraded)"
      ; ( "doctors"
        , `List
            [ `Assoc
                [ "name", `String "dashboard-route"
                ; "kind", `String "config"
                ; "exit_code", `Int 2
                ; ( "payload"
                  , Tool_args.error_assoc
                      [ "title", `String "Dashboard Doctor Route"
                      ; ( "checks"
                        , `List
                            [ Tool_args.error_assoc
                                [ "name", `String "self-binary"
                                ; "message", `String message
                                ; "path", `String self_bin
                                ] ] )
                      ; ( "summary"
                        , `Assoc
                            [ "total", `Int 1
                            ; "ok", `Int 0
                            ; "warn", `Int 0
                            ; "error", `Int 1
                            ] )
                      ] )
                ] ] )
      ; ( "summary"
        , `Assoc
            [ "total", `Int 1
            ; "ok", `Int 0
            ; "warn", `Int 0
            ; "error", `Int 1
            ] )
      ; "exit_code", `Int 2
      ])

(** Broadcast handler: parse JSON body, extract "message" string field, and
    relay via Coord.broadcast.  Error responses are encoded through Yojson so
    exception messages cannot break JSON framing via embedded quotes. *)
(* Dashboard request handlers extracted to
   [Server_routes_http_dashboard_handlers] (godfile decomp). *)
let handle_broadcast = Server_routes_http_dashboard_handlers.handle_broadcast
let handle_dashboard_link_previews = Server_routes_http_dashboard_handlers.handle_dashboard_link_previews
let handle_dashboard_task_history = Server_routes_http_dashboard_handlers.handle_dashboard_task_history
let handle_dashboard_rooms = Server_routes_http_dashboard_handlers.handle_dashboard_rooms

(* Telemetry unified view handler — extracted from add_routes pipeline
   as part of godfile near-threshold split. *)
let handle_telemetry request reqd =
  with_public_read (fun state req reqd ->
    let config = state.Mcp_server.room_config in
    let base_path = config.base_path in
    let masc_root = Coord.masc_root_dir config in
    let float_query_param req key =
      match Server_utils.query_param req key with
      | None -> None
      | Some raw -> float_of_string_opt raw
    in
    let keeper_name = Server_utils.query_param req "keeper" in
    let session_id = Server_utils.query_param req "session_id" in
    let operation_id = Server_utils.query_param req "operation_id" in
    let worker_run_id = Server_utils.query_param req "worker_run_id" in
    let since_ts = Option.map (fun ms -> ms /. 1000.0)
        (float_query_param req "since_ms")
    in
    let until_ts = Option.map (fun ms -> ms /. 1000.0)
        (float_query_param req "until_ms")
    in
    let has_time_window = Option.is_some since_ts || Option.is_some until_ts in
    let n =
      match Server_utils.query_param req "n" with
      | Some raw ->
        Option.value ~default:(if has_time_window then 0 else 100)
          (int_of_string_opt raw)
        |> max 0
      | None -> if has_time_window then 0 else 100
    in
    let sources =
      match Server_utils.query_param req "source" with
      | None -> Telemetry_unified.all_sources
      | Some s ->
        (match Telemetry_unified.source_of_string s with
         | Some src -> [src]
         | None -> Telemetry_unified.all_sources)
    in
    let query_json =
      let source_query =
        match Server_utils.query_param req "source" with
        | Some value -> `String value
        | None -> `Null
      in
      `Assoc
        [
          ("source", source_query);
          ( "resolved_sources",
            `List
              (List.map
                 (fun source ->
                   `String (Telemetry_unified.source_to_string source))
                 sources) );
          ("n", `Int n);
          ( "keeper",
            Option.fold ~none:`Null
              ~some:(fun value -> `String value)
              keeper_name );
          ( "session_id",
            Option.fold ~none:`Null
              ~some:(fun value -> `String value)
            session_id );
          ( "operation_id",
            Option.fold ~none:`Null
              ~some:(fun value -> `String value)
            operation_id );
          ( "worker_run_id",
            Option.fold ~none:`Null
              ~some:(fun value -> `String value)
            worker_run_id );
          ( "since_ms",
            Option.fold ~none:`Null
              ~some:(fun value -> `Float (value *. 1000.0))
              since_ts );
          ( "until_ms",
            Option.fold ~none:`Null
              ~some:(fun value -> `Float (value *. 1000.0))
            until_ts );
        ]
    in
    let timing = Server_timing.create () in
    let sources_key =
      sources
      |> List.map Telemetry_unified.source_to_string
      |> List.sort String.compare
      |> String.concat ","
    in
    let opt_str = function None -> "" | Some s -> s in
    let opt_ts = function None -> "" | Some f -> Printf.sprintf "%.3f" f in
    let cache_key =
      Printf.sprintf
        "telemetry:%s:%s:src=%s:n=%d:k=%s:s=%s:o=%s:w=%s:since=%s:until=%s"
        base_path masc_root sources_key n
        (opt_str keeper_name) (opt_str session_id)
        (opt_str operation_id) (opt_str worker_run_id)
        (opt_ts since_ts) (opt_ts until_ts)
    in
    let dashboard_telemetry_cache_ttl_sec = 1.0 in
    let compute () =
      let result =
        Server_timing.measure timing Telemetry_query (fun () ->
          Telemetry_unified.read_unified_result ~base_path ~masc_root
            ~sources ?keeper_name ?session_id ?operation_id
            ?worker_run_id ?since_ts ?until_ts ~n ())
      in
      let generated_at = Masc_domain.now_iso () in
      Server_timing.measure timing Json_serialize (fun () ->
        `Assoc [
          ("generated_at", `String generated_at);
          ("generated_at_iso", `String generated_at);
          ("dashboard_surface", `String "/api/v1/dashboard/telemetry");
          ("source", `String "telemetry_unified");
          ( "retention",
            Telemetry_unified.replay_retention_json ~base_path ~masc_root
              ~sources );
          ("query", query_json);
          ("count", `Int (List.length result.entries));
          ("total_matching_entries", `Int result.total_matching_entries);
          ("truncated", `Bool result.truncated);
          ("entries", `List result.entries);
        ])
    in
    let json =
      Server_timing.measure timing Cache_lookup (fun () ->
        Dashboard_cache.get_or_compute cache_key
          ~ttl:dashboard_telemetry_cache_ttl_sec compute)
    in
    Http.Response.json ~compress:true ~request:req
      ~extra_headers:(Server_timing.extra_header timing)
      (Yojson.Safe.to_string json) reqd
  ) request reqd
