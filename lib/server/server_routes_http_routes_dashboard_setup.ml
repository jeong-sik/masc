
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

(** Broadcast handler: parse JSON body, extract "message" string field, and
    relay via Workspace.broadcast.  Error responses are encoded through Yojson so
    exception messages cannot break JSON framing via embedded quotes. *)
(* Dashboard request handlers extracted to
   [Server_routes_http_dashboard_handlers] (godfile decomp). *)
let handle_broadcast = Server_routes_http_dashboard_handlers.handle_broadcast
let handle_dashboard_link_previews = Server_routes_http_dashboard_handlers.handle_dashboard_link_previews
let handle_dashboard_task_history = Server_routes_http_dashboard_handlers.handle_dashboard_task_history
let handle_dashboard_workspace = Server_routes_http_dashboard_handlers.handle_dashboard_workspace

(* Default page sizes for /api/v1/dashboard/telemetry when the client
   omits [n]. A windowed request (since_ms/until_ms) previously defaulted
   to n=0 (unbounded): a single Observatory poll
   ([observatory.ts] fetchTelemetry with since_ms/until_ms and no n) then
   Yojson-parsed up to the telemetry read clamp (50k, #20659) entries per
   source across all sources — enough to peg the single Eio domain on a
   non-yielding parse and freeze the keeper fleet. Bound the DEFAULT here;
   an explicit n=0 still honours the all-in-window contract from #20659. *)
let default_telemetry_limit = 100
let default_windowed_telemetry_limit = 2000

(* Resolve the effective entry limit for /api/v1/dashboard/telemetry.
   Absent or unparseable [n_param] falls back to a bounded default
   (windowed: [default_windowed_telemetry_limit], else
   [default_telemetry_limit]) so no request defaults to an unbounded read.
   An explicit n=0 parses to [Some 0] and is preserved (all-in-window,
   clamped downstream by #20659). Pure + exposed so the freeze guard
   (no permissive 0 default) is unit-testable. *)
let resolve_telemetry_n ~has_time_window ~(n_param : string option) =
  let default_n =
    if has_time_window
    then default_windowed_telemetry_limit
    else default_telemetry_limit
  in
  match n_param with
  | Some raw -> Option.value ~default:default_n (int_of_string_opt raw) |> max 0
  | None -> default_n

(* Telemetry unified view handler — extracted from add_routes pipeline
   as part of godfile near-threshold split. *)
let handle_telemetry request reqd =
  with_public_read (fun state req reqd ->
    let config = (Mcp_server.workspace_config state) in
    let base_path = config.base_path in
    let masc_root = Workspace.masc_root_dir config in
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
      resolve_telemetry_n ~has_time_window
        ~n_param:(Server_utils.query_param req "n")
    in
    let offset =
      match Server_utils.query_param req "offset" with
      | Some raw ->
        Option.value ~default:0 (int_of_string_opt raw)
        |> max 0 |> min 5000
      | None -> 0
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
        Json_util.string_opt_to_json (Server_utils.query_param req "source")
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
          ("offset", `Int offset);
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
        "telemetry:%s:%s:src=%s:n=%d:off=%d:k=%s:s=%s:o=%s:w=%s:since=%s:until=%s"
        base_path masc_root sources_key n offset
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
            ?worker_run_id ?since_ts ?until_ts ~n ~offset ())
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
          ("offset", `Int offset);
          ("has_more", `Bool (offset + List.length result.entries < result.total_matching_entries));
          ("truncated", `Bool result.truncated);
          ("entries", `List result.entries);
        ])
    in
    let json =
      Server_timing.measure timing Cache_lookup (fun () ->
        Dashboard_cache.get_or_compute cache_key
          ~ttl:dashboard_telemetry_cache_ttl_sec compute)
    in
    Http.Response.json_value ~compress:true ~request:req
      ~extra_headers:(Server_timing.extra_header timing) json reqd
  ) request reqd
