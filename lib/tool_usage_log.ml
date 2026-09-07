module StringMap = Set_util.StringMap

(** Tool_usage_log -- Durable call logging for non-public registered tools.

    Persists tool invocations to [.masc/tool_usage/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. External MCP discovery membership is not reused as a
    Keeper visibility or authorization policy.

    Writes are immediate (no buffering) since non-public call volume
    is low. All I/O failures are caught and logged (best-effort).

    @since 2.190.0 -- Issue #5120 *)

let is_non_public name = not (Tool_catalog.is_public_mcp name)

(* -- Store management -- *)

let store_ref : Dated_jsonl.t option Atomic.t = Atomic.make None
let source_name = "tool_usage"
let source_producer = "tool_usage_log"
let dashboard_surface = "/api/v1/dashboard/tools"
(* Sparse-source SLO. Tool_usage logs non-public registered calls. Real
   workloads can legitimately go an hour or more without an admin tool call,
   so the original 900 s SLO inherited from high-volume sources caused false
   "stale" alerts on healthy fleets. 3600 s matches the operational rhythm
   without masking a true write-pipeline failure — Dated_jsonl append errors
   already record a coverage_gap that bypasses this SLO. *)
let freshness_slo_s = Masc_time_constants.hour

let store_dir masc_root = Filename.concat masc_root "tool_usage"

(* Opt-in: unset keeps everything. A malformed value now means the same here
   as in every other store (#27110). *)
let retention_days () =
  match
    Env_config_core.get_retention_days
      ~default:Env_config_core.Retain_forever
      "MASC_TOOL_USAGE_LOG_RETENTION_DAYS"
  with
  | Env_config_core.Retain_forever -> None
  | Env_config_core.Prune_after_days days -> Some days

let ts_of_record = Dashboard_tool_source_freshness.latest_ts_of_record

let latest_ts_of_entries entries =
  List.fold_left
    (fun acc json ->
      match ts_of_record json with
      | Some ts when Stdlib.Float.compare ts 0.0 > 0 -> (match acc with | None -> Some ts | Some prev -> Some (Stdlib.Float.max prev ts))
      | _ -> acc)
    None entries

let freshness_fields = Dashboard_tool_source_freshness.freshness_fields

(* The last of four bodies this file kept alongside
   Dashboard_tool_source_freshness. They were identical but for freshness_slo_s
   being a constant here and a parameter there, so one vocabulary had two
   producers and adding a state to either left the other untouched (#27157). *)
let source_health_fields ~now ~exists ~entry_count ~latest_ts ?coverage_gap () =
  Dashboard_tool_source_freshness.health_fields
    ~now
    ~exists
    ~entry_count
    ~latest_ts
    ~freshness_slo_s
    ?coverage_gap
    ()

let coverage_gaps masc_root =
  Telemetry_coverage_gap.read_recent ~masc_root ~n:50
  |> List.filter (fun gap ->
       String.equal source_name
         (Safe_ops.json_string ~default:"" "source" gap))

let latest_coverage_gap gaps =
  List.rev gaps |> List.find_opt (fun _ -> true)

(* Was re-typed here; the kit owns it (#27157). coverage_gap_recovered goes
   with it — this file only ever called it through active_coverage_gaps. *)
let active_coverage_gaps = Dashboard_tool_source_freshness.active_coverage_gaps

let synthetic_store_gap ~durable_store ~stale_reason ~error =
  let now = Time_compat.now () in
  `Assoc
    [
      ("ts_unix", `Float now);
      ("ts_iso", `String (Masc_domain.iso8601_of_unix_seconds now));
      ("source", `String source_name);
      ("producer", `String source_producer);
      ("durable_store", `String durable_store);
      ("dashboard_surface", `String dashboard_surface);
      ("stale_reason", `String stale_reason);
      ("error", `String error);
    ]

let record_coverage_gap ~masc_root ~durable_store ~stale_reason ?caller
    ?tool_name exn =
  let context =
    [ tool_name; caller ]
    |> List.filter_map (function
      | Some value when not (String.equal (String.trim value) "") -> Some value
      | _ -> None)
    |> String.concat "/"
  in
  let error =
    if String.equal context "" then Stdlib.Printexc.to_string exn
    else Printf.sprintf "%s: %s" context (Stdlib.Printexc.to_string exn)
  in
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:source_name
      ~producer:source_producer
      ~durable_store
      ~dashboard_surface
      ~stale_reason
      ~error
      ~exn
      ()
  with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | gap_exn ->
    Log.Misc.warn "tool_usage_log: coverage gap append failed: %s"
      (Stdlib.Printexc.to_string gap_exn)

let count_entries store =
  try Dated_jsonl.count_entries store with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | exn ->
    Log.Misc.warn "tool_usage_log: count failed for %s: %s"
      (Dated_jsonl.base_dir store)
      (Stdlib.Printexc.to_string exn);
    0

let latest_ts store =
  try latest_ts_of_entries (Dated_jsonl.read_recent store 64) with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | exn ->
    Log.Misc.warn "tool_usage_log: latest read failed for %s: %s"
      (Dated_jsonl.base_dir store)
      (Stdlib.Printexc.to_string exn);
    None

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let masc_root = Workspace_utils.masc_root_dir_from ~base_path ~cluster_name in
  let dir = store_dir masc_root in
  (try
     Fs_compat.mkdir_p dir;
     let retention_days = retention_days () in
     let store = Dated_jsonl.create ~base_dir:dir ?retention_days () in
     Atomic.set store_ref (Some store)
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Atomic.set store_ref None;
     Log.Misc.warn "tool_usage_log: init failed: %s" (Stdlib.Printexc.to_string exn);
     record_coverage_gap
       ~masc_root
       ~durable_store:dir
       ~stale_reason:"tool_usage_init_failed"
       exn)

(* -- Record format -- *)

let record_to_json ~tool_name ~disposition ~caller =
  let fields =
    [ ("tool_name", `String tool_name)
    ; ("ts", `Float (Time_compat.now ()))
    ; ("disposition", `String (Tool_result.string_of_disposition disposition))
    ]
  in
  let fields = match caller with
    | Some c when not (String.equal c "") && not (String.equal c "unknown") ->
        fields @ [("caller", `String c)]
    | _ -> fields
  in
  `Assoc fields

(* -- Write -- *)

(* [on_io_failure] is injected by the installer (server bootstrap) so this
   generic tool-usage logger does not reference the keeper FD/disk pressure
   subsystem directly. Tool->Keeper dependency direction: a tool-surface module
   must not name keeper internals (generalizes RFC-0084's dispatch-path rule to
   the whole surface). Keeper-facing IO-failure handling is supplied at the
   install boundary (lib/server/server_bootstrap_maintenance.ml). *)
let log_call ~on_io_failure ~tool_name ~disposition ~caller =
  match Atomic.get store_ref with
  | None ->
      Log.Misc.debug "tool_usage_log: store not initialized, skipping %s" tool_name
  | Some store ->
      let json = record_to_json ~tool_name ~disposition ~caller in
      (try Dated_jsonl.append store json
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         on_io_failure ~site:"tool_usage_log.append" exn;
         Log.Misc.warn "tool_usage_log: append failed for %s: %s"
           tool_name (Stdlib.Printexc.to_string exn);
         let durable_store = Dated_jsonl.base_dir store in
         record_coverage_gap
           ~masc_root:(Filename.dirname durable_store)
           ~durable_store
           ~stale_reason:"tool_usage_append_failed"
           ~tool_name
           ?caller
           exn)

(* -- Post-hook installation -- *)

(** Caller extraction from tool result data.
    The caller (agent_name) is not in Tool_result.result directly, so we
    extract it from the structured data if present, or default to None. *)
let extract_caller (result : Tool_result.result) : string option =
  match Tool_result.data result with
  | `Assoc fields ->
      (match List.assoc_opt "agent_name" fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

(* Log only handled non-public dispatches. Non-handled outcomes are
   represented by dispatch telemetry, not tool-usage rows. *)
let install ~on_io_failure =
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some (result : Tool_result.result) ->
      let tool_name = Tool_result.tool_name result in
      if is_non_public tool_name then
        log_call
          ~on_io_failure
          ~tool_name
          ~disposition:result
          ~caller:(extract_caller result)
    | _ -> ())

(* -- Read utilities (for analysis) -- *)

let read_recent ?(n = 10_000) () : Yojson.Safe.t list =
  match Atomic.get store_ref with
  | None -> []
  | Some store -> Dated_jsonl.read_recent store n

let source_metadata_json ~masc_root =
  let now = Time_compat.now () in
  let durable_store = store_dir masc_root in
  let exists = Sys.file_exists durable_store in
  let store_not_directory =
    exists
    &&
    try not (Sys.is_directory durable_store) with
    | Sys_error _ -> true
  in
  let entry_count, latest_ts =
    if exists && not store_not_directory then
      let store = Dated_jsonl.create ~base_dir:durable_store () in
      (count_entries store, latest_ts store)
    else
      (0, None)
  in
  let coverage_gaps =
    let gaps = coverage_gaps masc_root in
    if store_not_directory then
      gaps
      @ [
          synthetic_store_gap
            ~durable_store
            ~stale_reason:"tool_usage_store_not_directory"
            ~error:"tool_usage durable store path exists but is not a directory";
        ]
    else
      gaps
  in
  let active_coverage_gaps = active_coverage_gaps ~latest_ts coverage_gaps in
  let coverage_gap = latest_coverage_gap active_coverage_gaps in
  `Assoc
    ([
       ("source", `String source_name);
       ("producer", `String source_producer);
       ("durable_store", `String durable_store);
       ("dashboard_surface", `String dashboard_surface);
       ("freshness_slo_s", `Float freshness_slo_s);
       ("entry_count", `Int entry_count);
       ("exists", `Bool exists);
       ("coverage_gaps", `List coverage_gaps);
       ("coverage_gap_count", `Int (List.length coverage_gaps));
       ("active_coverage_gap_count", `Int (List.length active_coverage_gaps));
     ]
    @ freshness_fields ~now latest_ts
    @ source_health_fields
        ~now ~exists ~entry_count ~latest_ts ?coverage_gap ())

let attach_source_metadata ~masc_root json =
  let metadata_fields =
    match source_metadata_json ~masc_root with
    | `Assoc fields -> fields
    | _ -> []
  in
  match json with
  | `Assoc fields ->
    `Assoc
      (List.fold_left
         (fun acc (key, value) -> (key, value) :: List.remove_assoc key acc)
         fields
         metadata_fields)
  | other -> other
