(* Telemetry_unified_source_meta — source classification, metadata, and
   directory discovery for telemetry stores.
   Extracted from telemetry_unified.ml during godfile decomposition.
   Contains error observation helpers, source path classification, freshness
   SLO constants, store discovery, and replay retention rendering. *)

open Telemetry_unified_source

let observe_source_read_failure source ~site ~error =
  let source = source_to_string source in
  Otel_metric_store_core.inc_counter
    Otel_builtin_metric_names.metric_telemetry_unified_source_read_failures
    ~labels:[ ("source", source); ("site", site) ]
    ();
  Log.Telemetry.warn
    "telemetry_unified source read failure: source=%s site=%s error=%s"
    source site error

let observe_source_read_failure_exn source ~site exn =
  observe_source_read_failure source ~site ~error:(Printexc.to_string exn)

let protect_source_read source ~site ~default f =
  match f () with
  | value -> value
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    observe_source_read_failure_exn source ~site exn;
    default

type read_result = {
  entries : Yojson.Safe.t list;
  total_matching_entries : int;
  truncated : bool;
}

(* ── Store paths ────────────────────────────────────── *)

let fixed_store_dir ~masc_root ~base_path = function
  | Agent_event  -> Some (Filename.concat masc_root "telemetry")
  | Tool_call_io -> Some (Filename.concat masc_root "tool_calls")
  | Tool_usage   -> Some (Filename.concat masc_root "tool_usage")
  | Oas_event    -> Some (Filename.concat masc_root "oas-events")
  | Tool_metric  -> Some (Filename.concat base_path "data/tool-metrics")
  | Keeper_metric | Trajectory_tool_call | Execution_receipt | Goal_event ->
      None
    (* handled separately *)

let source_freshness_slo_s = function
  | Keeper_metric -> 300.0
  | Tool_call_io -> 300.0
  | Trajectory_tool_call -> 300.0
  | Execution_receipt -> 300.0
  | Oas_event -> 300.0
  | Agent_event -> 900.0
  (* Tool_usage covers non-public registered calls, which are sparse by
     design. Match the SSOT in tool_usage_log.ml. *)
  | Tool_usage -> Masc_time_constants.hour
  | Goal_event -> Masc_time_constants.days_to_seconds 7
  | Tool_metric -> 900.0

let source_producer = function
  | Keeper_metric -> "keeper_unified_metrics"
  | Agent_event -> "telemetry_eio"
  | Tool_call_io -> "keeper_hooks_oas|mcp_server_eio_call_tool"
  | Trajectory_tool_call -> "keeper_hooks_oas|mcp_server_eio_call_tool"
  | Tool_usage -> "tool_usage_log"
  | Oas_event -> "oas_event_bus"
  | Execution_receipt -> "keeper_agent_run.execution_receipt"
  | Goal_event -> "goal_fsm"
  | Tool_metric -> "tool_metrics_persist"

let source_dashboard_surface = function
  | Keeper_metric -> "/api/v1/dashboard/telemetry/summary"
  | Agent_event -> "/api/v1/dashboard/telemetry"
  | Tool_call_io -> "/api/v1/keepers/:name/tool-calls"
  | Trajectory_tool_call -> "/api/v1/keepers/:name/tool-stats"
  | Tool_usage -> "/api/v1/dashboard/tools"
  | Oas_event -> "/api/v1/dashboard/telemetry"
  | Execution_receipt -> "/api/v1/dashboard/execution-trust"
  | Goal_event -> "/api/v1/dashboard/goals"
  | Tool_metric -> "/api/v1/tool-metrics"

let source_durable_store ~masc_root ~base_path = function
  | Keeper_metric -> Filename.concat masc_root "keepers/*/metrics"
  | Trajectory_tool_call -> Filename.concat masc_root "trajectories/*/*.jsonl"
  | Execution_receipt -> Filename.concat masc_root "keepers/*/execution-receipts"
  | Goal_event -> Filename.concat masc_root "goal_events.jsonl"
  | source -> (
      match fixed_store_dir ~masc_root ~base_path source with
      | Some dir -> dir
      | None -> "")

let source_metadata_fields ~base_path ~masc_root source =
  [
    ("freshness_slo_s", `Float (source_freshness_slo_s source));
    ("producer", `String (source_producer source));
    ( "durable_store",
      `String (source_durable_store ~masc_root ~base_path source) );
    ("dashboard_surface", `String (source_dashboard_surface source));
  ]

let replay_retention_json ~base_path ~masc_root ~sources : Yojson.Safe.t =
  `Assoc
    [
      ("scope", `String "dashboard_telemetry_replay");
      ("workspace_root", `String masc_root);
      ("base_path", `String base_path);
      ( "selected_sources",
        `List
          (List.map
             (fun source -> `String (source_to_string source))
             sources) );
      ( "durable_stores",
        `List
          (List.map
             (fun source ->
               `Assoc
                 (("source", `String (source_to_string source))
                 :: source_metadata_fields ~base_path ~masc_root source))
             sources) );
      ( "cache_policy",
        `String
          "uncached; reads persisted JSONL rows; sorts newest first; n<=0 returns the full filtered window"
      );
    ]

type store_dir_state =
  | Store_missing
  | Store_directory
  | Store_invalid

let classify_store_dir source ~site dir =
  match Sys.file_exists dir with
  | false -> Store_missing
  | true ->
    (match Sys.is_directory dir with
     | true -> Store_directory
     | false ->
       observe_source_read_failure source ~site
         ~error:(Printf.sprintf "%s exists but is not a directory" dir);
       Store_invalid)
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    observe_source_read_failure_exn source ~site exn;
    Store_invalid

(** Discover all keeper metric directories under [masc_root/keepers/]. *)
let discover_keeper_metric_dirs masc_root : (string * string) list =
  let keepers_dir = Filename.concat masc_root "keepers" in
  match classify_store_dir Keeper_metric ~site:"discover_keeper_metric_root"
          keepers_dir with
  | Store_missing | Store_invalid -> []
  | Store_directory ->
    let entries =
      protect_source_read Keeper_metric ~site:"discover_keeper_metric_dirs"
        ~default:[] (fun () -> Array.to_list (Sys.readdir keepers_dir))
    in
    List.filter_map (fun name ->
      let metrics_dir = Filename.concat keepers_dir (name ^ "/metrics") in
      if Sys.file_exists metrics_dir then Some (name, metrics_dir)
      else None
    ) entries

let is_directory source ~site path =
  protect_source_read source ~site ~default:false (fun () ->
    Sys.file_exists path && Sys.is_directory path)

let is_jsonl_file source ~site path =
  protect_source_read source ~site ~default:false (fun () ->
    Sys.file_exists path && (not (Sys.is_directory path))
    && Filename.check_suffix path ".jsonl")

let discover_trajectory_keeper_dirs_in_root trajectories_root =
  protect_source_read Trajectory_tool_call
    ~site:"discover_trajectory_keeper_dirs" ~default:[] (fun () ->
    Sys.readdir trajectories_root
    |> Array.to_list
    |> List.filter_map (fun name ->
         let dir = Filename.concat trajectories_root name in
         if
           is_directory Trajectory_tool_call
             ~site:"discover_trajectory_keeper_dir_stat" dir
         then Some (name, dir)
         else None))

let discover_trajectory_keeper_dirs masc_root : (string * string) list =
  let trajectories_root = Filename.concat masc_root "trajectories" in
  match classify_store_dir Trajectory_tool_call
          ~site:"discover_trajectory_root" trajectories_root with
  | Store_missing | Store_invalid -> []
  | Store_directory -> discover_trajectory_keeper_dirs_in_root trajectories_root

let discover_execution_receipt_dirs masc_root : (string * string) list =
  let keepers_dir = Filename.concat masc_root "keepers" in
  match classify_store_dir Execution_receipt
          ~site:"discover_execution_receipt_root" keepers_dir with
  | Store_missing | Store_invalid -> []
  | Store_directory ->
    protect_source_read Execution_receipt
      ~site:"discover_execution_receipt_dirs" ~default:[] (fun () ->
      Sys.readdir keepers_dir
      |> Array.to_list
      |> List.filter_map (fun name ->
           let dir =
             Filename.concat (Filename.concat keepers_dir name)
               "execution-receipts"
           in
           if
             is_directory Execution_receipt
               ~site:"discover_execution_receipt_dir_stat" dir
           then Some (name, dir)
           else None))
