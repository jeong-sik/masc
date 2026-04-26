module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(** Tool_usage_log -- Durable call logging for System_internal surface tools.

    Persists tool invocations to [.masc/tool_usage/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. Only tools on the {!Tool_catalog_surfaces.System_internal}
    surface are logged, providing evidence for safe pruning decisions.

    Writes are immediate (no buffering) since System_internal call volume
    is low. All I/O failures are caught and logged (best-effort).

    @since 2.190.0 -- Issue #5120 *)

(* -- System_internal membership set (O(log n) lookup) -- *)

let system_internal_set : StringSet.t =
  let tools = Tool_catalog_surfaces.system_internal_surface_tools in
  List.fold_left (fun s name -> StringSet.add name s) StringSet.empty tools

let is_system_internal name = StringSet.mem name system_internal_set

(* -- Store management -- *)

let store_ref : Dated_jsonl.t option ref = ref None
let source_name = "tool_usage"
let source_producer = "tool_usage_log"
let dashboard_surface = "/api/v1/dashboard/tools"
(* Sparse-source SLO. Tool_usage logs only Tool_catalog_surfaces.System_internal
   surface tools, which are admin-only invocations driven by operators. Real
   workloads can legitimately go an hour or more without an admin tool call,
   so the original 900 s SLO inherited from high-volume sources caused false
   "stale" alerts on healthy fleets. 3600 s matches the operational rhythm
   without masking a true write-pipeline failure — Dated_jsonl append errors
   already record a coverage_gap that bypasses this SLO. *)
let freshness_slo_s = 3600.0

let store_dir masc_root = Filename.concat masc_root "tool_usage"

let max_ts_opt current candidate =
  match current with
  | Some existing when existing >= candidate -> current
  | _ -> Some candidate

let numeric_ts_field fields name =
  match List.assoc_opt name fields with
  | Some (`Float ts) -> Some ts
  | Some (`Int ts) -> Some (Float.of_int ts)
  | _ -> None

let ts_of_record = function
  | `Assoc fields -> (
      match numeric_ts_field fields "ts_unix" with
      | Some ts -> Some ts
      | None -> (
          match numeric_ts_field fields "ts" with
          | Some ts -> Some ts
          | None -> (
              match numeric_ts_field fields "timestamp" with
              | Some ts -> Some ts
              | None -> (
                  match List.assoc_opt "ts_iso" fields with
                  | Some (`String iso) -> Types.parse_iso8601_opt iso
                  | _ -> None))))
  | _ -> None

let latest_ts_of_entries entries =
  List.fold_left
    (fun acc json ->
      match ts_of_record json with
      | Some ts when ts > 0.0 -> max_ts_opt acc ts
      | _ -> acc)
    None entries

let freshness_fields ~now latest_ts =
  match latest_ts with
  | Some ts ->
    [
      ("latest_ts_unix", `Float ts);
      ("latest_ts_iso", `String (Types.iso8601_of_unix_seconds ts));
      ("latest_age_s", `Float (max 0.0 (now -. ts)));
    ]
  | None ->
    [
      ("latest_ts_unix", `Null);
      ("latest_ts_iso", `Null);
      ("latest_age_s", `Null);
    ]

let source_health_fields ~now ~exists ~entry_count ~latest_ts ?coverage_gap () =
  let health, stale_reason =
    match coverage_gap with
    | Some gap ->
      ( "coverage_gap",
        Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
    | None ->
      if not exists then ("missing", "store_missing")
      else if entry_count = 0 then ("empty", "no_entries")
      else
        match latest_ts with
        | None -> ("empty", "no_entries")
        | Some ts ->
          let latest_age_s = max 0.0 (now -. ts) in
          if latest_age_s > freshness_slo_s then
            ("stale", "freshness_slo_exceeded")
          else
            ("ok", "")
  in
  [
    ("health", `String health);
    ( "stale_reason",
      if stale_reason = "" then `Null else `String stale_reason );
  ]

let coverage_gaps masc_root =
  Telemetry_coverage_gap.read_recent ~masc_root ~n:50
  |> List.filter (fun gap ->
       String.equal source_name
         (Safe_ops.json_string ~default:"" "source" gap))

let latest_coverage_gap gaps =
  List.rev gaps |> List.find_opt (fun _ -> true)

let synthetic_store_gap ~durable_store ~stale_reason ~error =
  let now = Time_compat.now () in
  `Assoc
    [
      ("ts_unix", `Float now);
      ("ts_iso", `String (Types.iso8601_of_unix_seconds now));
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
      | Some value when String.trim value <> "" -> Some value
      | _ -> None)
    |> String.concat "/"
  in
  let error =
    if context = "" then Printexc.to_string exn
    else Printf.sprintf "%s: %s" context (Printexc.to_string exn)
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
      ()
  with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | gap_exn ->
    Log.Misc.warn "tool_usage_log: coverage gap append failed: %s"
      (Printexc.to_string gap_exn)

let count_entries store =
  try Dated_jsonl.count_entries store with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | exn ->
    Log.Misc.warn "tool_usage_log: count failed for %s: %s"
      (Dated_jsonl.base_dir store)
      (Printexc.to_string exn);
    0

let latest_ts store =
  try latest_ts_of_entries (Dated_jsonl.read_recent store 64) with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | exn ->
    Log.Misc.warn "tool_usage_log: latest read failed for %s: %s"
      (Dated_jsonl.base_dir store)
      (Printexc.to_string exn);
    None

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let masc_root = Coord_utils.masc_root_dir_from ~base_path ~cluster_name in
  let dir = store_dir masc_root in
  (try
     Fs_compat.mkdir_p dir;
     let store = Dated_jsonl.create ~base_dir:dir () in
     store_ref := Some store
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     store_ref := None;
     Log.Misc.warn "tool_usage_log: init failed: %s" (Printexc.to_string exn);
     record_coverage_gap
       ~masc_root
       ~durable_store:dir
       ~stale_reason:"tool_usage_init_failed"
       exn)

(* -- Record format -- *)

let record_to_json ~tool_name ~success ~caller =
  let fields =
    [ ("tool_name", `String tool_name)
    ; ("ts", `Float (Time_compat.now ()))
    ; ("success", `Bool success)
    ]
  in
  let fields = match caller with
    | Some c when c <> "" && c <> "unknown" ->
        fields @ [("caller", `String c)]
    | _ -> fields
  in
  `Assoc fields

(* -- Write -- *)

let log_call ~tool_name ~success ~caller =
  match !store_ref with
  | None ->
      Log.Misc.debug "tool_usage_log: store not initialized, skipping %s" tool_name
  | Some store ->
      let json = record_to_json ~tool_name ~success ~caller in
      (try Dated_jsonl.append store json
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Misc.warn "tool_usage_log: append failed for %s: %s"
           tool_name (Printexc.to_string exn);
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
    The caller (agent_name) is not in Tool_result.t directly, so we
    extract it from the structured data if present, or default to None. *)
let extract_caller (result : Tool_result.t) : string option =
  match result.data with
  | `Assoc fields ->
      (match List.assoc_opt "agent_name" fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let install () =
  Tool_dispatch.register_post_hook (fun (result : Tool_result.t) ->
    if is_system_internal result.tool_name then
      log_call
        ~tool_name:result.tool_name
        ~success:result.success
        ~caller:(extract_caller result);
    result)

(* -- Read utilities (for analysis) -- *)

let read_recent ?(n = 10_000) () : Yojson.Safe.t list =
  match !store_ref with
  | None -> []
  | Some store -> Dated_jsonl.read_recent store n

let summary () : (string * int) list =
  let entries = read_recent ~n:100_000 () in
  let counts =
    List.fold_left (fun counts json ->
      match Safe_ops.json_string_opt "tool_name" json with
      | Some name ->
          let c = match StringMap.find_opt name counts with
            | Some n -> n | None -> 0 in
          StringMap.add name (c + 1) counts
      | None -> counts
    ) StringMap.empty entries
  in
  let pairs = StringMap.bindings counts in
  List.sort (fun (_, a) (_, b) -> Int.compare b a) pairs

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
  let coverage_gap = latest_coverage_gap coverage_gaps in
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
