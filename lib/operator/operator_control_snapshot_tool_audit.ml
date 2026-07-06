(** Tool audit helpers (lightweight fallback + cached JSON) for operator
    control snapshot, extracted from operator_control_snapshot.ml. *)

let merge_tool_name_lists = Operator_control_snapshot_tool_names.merge_tool_name_lists
let collect_recent_tool_names = Operator_control_snapshot_tool_names.collect_recent_tool_names
let collect_recent_tool_names_with_errors =
  Operator_control_snapshot_tool_names.collect_recent_tool_names_with_errors

let tool_name_parse_error_to_json =
  Operator_control_snapshot_tool_names.recent_tool_name_parse_error_to_json

let lightweight_tool_audit_fallback_json (meta : Keeper_meta_contract.keeper_meta) =
  let last_autonomous = String.trim meta.runtime.last_autonomous_action_at in
  let has_runtime_activity =
    last_autonomous <> ""
    || meta.runtime.autonomous_turn_count > 0
    || meta.runtime.autonomous_action_count > 0
  in
  `Assoc
    [ "recent_tool_names", `List []
    ; "latest_tool_names", `List []
    ; ("latest_tool_call_count", if has_runtime_activity then `Int 0 else `Null)
    ; "latest_action_source", `Null
    ; ( "tool_audit_source"
      , if has_runtime_activity then `String "keeper_runtime_meta" else `Null )
    ; ( "tool_audit_at"
      , if last_autonomous <> ""
        then `String last_autonomous
        else if has_runtime_activity
        then `String meta.updated_at
        else `Null )
    ; "tool_audit_read_error_count", `Int 0
    ; "tool_audit_read_errors", `List []
    ]
;;

(* Decision-log tail projection.  [recent_tool_names_from_files] previously
   re-read the last 120 KB of each keeper's decision log on every snapshot;
   live measurement (reports/masc-live-perf-diagnosis-20260622.md) showed audit
   was ~56% of keepers_json cost under disk I/O contention.  The projection
   folds only newly appended lines (steady-state O(new bytes)) while returning
   the same most-recent-[decision_tail_window] lines in file order, so the
   unchanged [collect_recent_tool_names] downstream produces byte-identical
   output.  Single serving domain: audit runs inside the keepers_json
   Eio.Fiber.all on one compute domain (each fiber a distinct keeper = distinct
   key), matching Jsonl_incremental_projection's contract and mirroring
   Dashboard_http_keeper_feeds. *)
let decision_tail_window = 120
let decision_tail_bytes = 120000

let decision_lines_projection : string list Jsonl_incremental_projection.t =
  Jsonl_incremental_projection.create ()

let recent_tool_names_from_files_with_read_errors config keeper_name =
  let decision_lines =
    let path = Keeper_types_support.keeper_decision_log_path config keeper_name in
    (* file_exists guard preserves the prior "missing file -> []" behavior:
       the projection would otherwise return its last cached lines for a file
       that has since been removed. *)
    if not (Fs_compat.file_exists path)
    then []
    else
      Keeper_memory.recent_lines_or_record decision_lines_projection
        ~site:"operator_tool_audit_decisions" ~key:path ~path
        ~window:decision_tail_window ~initial_tail_bytes:decision_tail_bytes
  in
  let decision_names, decision_parse_errors =
    collect_recent_tool_names_with_errors decision_lines
  in
  let decision_read_errors =
    List.map
      (tool_name_parse_error_to_json
         ~source:"operator_tool_audit_decisions_jsonl"
         ~keeper:keeper_name
         ~path:(Keeper_types_support.keeper_decision_log_path config keeper_name))
      decision_parse_errors
  in
  let metrics_lines, metrics_source_path =
    let store = Keeper_types_support.keeper_metrics_store config keeper_name in
    let dated = Dated_jsonl.read_recent_lines store 120 in
    if dated <> []
    then dated, Dated_jsonl.base_dir store
    else (
      let path = Keeper_types_support.keeper_metrics_path config keeper_name in
      match
        Keeper_memory.read_file_tail_lines_result path
          ~max_bytes:120000 ~max_lines:120
      with
      | Ok lines -> lines, path
      | Error exn_class ->
          Keeper_memory.record_memory_recall_read_error
            ~site:"operator_tool_audit_metrics" path exn_class;
          [], path)
  in
  let metrics_names, metrics_parse_errors =
    collect_recent_tool_names_with_errors metrics_lines
  in
  let metrics_read_errors =
    List.map
      (tool_name_parse_error_to_json
         ~source:"operator_tool_audit_metrics_jsonl"
         ~keeper:keeper_name
         ~path:metrics_source_path)
      metrics_parse_errors
  in
  ( merge_tool_name_lists decision_names metrics_names
  , decision_read_errors @ metrics_read_errors )
;;

let recent_tool_names_from_files config keeper_name =
  fst (recent_tool_names_from_files_with_read_errors config keeper_name)
;;

let keeper_tool_audit_fields_with_read_errors config
      (meta : Keeper_meta_contract.keeper_meta)
  =
  let recent_tool_names, tool_audit_read_errors =
    recent_tool_names_from_files_with_read_errors config meta.name
  in
  let last_autonomous = String.trim meta.runtime.last_autonomous_action_at in
  let fallback_snapshot =
    match
      Keeper_status_metrics.latest_tool_audit_snapshot_from_files
        config
        ~keeper_name:meta.name
    with
    | Some snapshot ->
      { snapshot with
        tool_audit_at =
          (match snapshot.tool_audit_source, snapshot.tool_audit_at with
           | Some _, None when last_autonomous <> "" -> Some last_autonomous
           | Some _, None -> Some meta.updated_at
           | _ -> snapshot.tool_audit_at)
      }
    | None ->
      let has_runtime_activity =
        last_autonomous <> ""
        || meta.runtime.autonomous_turn_count > 0
        || meta.runtime.autonomous_action_count > 0
      in
      { Keeper_status_metrics.empty_tool_audit_snapshot with
        latest_tool_call_count = (if has_runtime_activity then Some 0 else None)
      ; tool_audit_source =
          (if has_runtime_activity then Some "keeper_runtime_meta" else None)
      ; tool_audit_at =
          (if last_autonomous <> ""
           then Some last_autonomous
           else if has_runtime_activity
           then Some meta.updated_at
           else None)
      }
  in
  ( recent_tool_names
  , fallback_snapshot.latest_tool_names
  , fallback_snapshot.latest_tool_call_count
  , fallback_snapshot.latest_action_source
  , fallback_snapshot.tool_audit_source
  , fallback_snapshot.tool_audit_at
  , tool_audit_read_errors )
;;

let keeper_tool_audit_fields config meta =
  let ( recent_tool_names
      , latest_tool_names
      , latest_tool_call_count
      , latest_action_source
      , tool_audit_source
      , tool_audit_at
      , _tool_audit_read_errors )
    =
    keeper_tool_audit_fields_with_read_errors config meta
  in
  ( recent_tool_names
  , latest_tool_names
  , latest_tool_call_count
  , latest_action_source
  , tool_audit_source
  , tool_audit_at )
;;

let cached_tool_audit_json
      ~lightweight
      (config : Workspace.config)
      (meta : Keeper_meta_contract.keeper_meta)
  =
  let base_hash = Digest.to_hex (Digest.string config.base_path) in
  let cache_key = "kta:" ^ base_hash ^ ":" ^ meta.name in
  let ttl = 4.0 in
  Dashboard_cache.get_or_compute cache_key ~ttl (fun () ->
    let ( recent_tool_names
        , latest_tool_names
        , latest_tool_call_count
        , latest_action_source
        , tool_audit_source
        , tool_audit_at
        , tool_audit_read_errors )
      =
      if lightweight
      then (
        let ( recent_tool_names
            , latest_tool_names
            , latest_tool_call_count
            , latest_action_source
            , tool_audit_source
            , tool_audit_at
            , tool_audit_read_errors )
          =
          keeper_tool_audit_fields_with_read_errors config meta
        in
        ( recent_tool_names
        , latest_tool_names
        , latest_tool_call_count
        , latest_action_source
        , tool_audit_source
        , tool_audit_at
        , tool_audit_read_errors ))
      else keeper_tool_audit_fields_with_read_errors config meta
    in
    `Assoc
      [ "recent_tool_names", `List (List.map (fun v -> `String v) recent_tool_names)
      ; "latest_tool_names", `List (List.map (fun v -> `String v) latest_tool_names)
      ; "latest_tool_call_count", Json_util.option_to_yojson (fun v -> `Int v) latest_tool_call_count
      ; "latest_action_source", Json_util.string_opt_to_json latest_action_source
      ; "tool_audit_source", Json_util.string_opt_to_json tool_audit_source
      ; "tool_audit_at", Json_util.string_opt_to_json tool_audit_at
      ; "tool_audit_read_error_count", `Int (List.length tool_audit_read_errors)
      ; "tool_audit_read_errors", `List tool_audit_read_errors
      ])
;;

(* Concurrency cap for parallel keeper snapshot fibers.
   Originally 4 to guard against memory bursts when many keepers are
   processed simultaneously.  Live measurement via #8829 over 48 samples
   showed this cap was the dominant cost, not the per-keeper I/O:

       wait avg=1334ms max=4424ms   (queued on semaphore)
       work avg=604ms  max=3088ms   (meta/agent/profile I/O + JSON)
       ratio wait/work = 2.21x

   Raising to 16 matches the current fleet size so no fiber queues on
   the semaphore in the common case.  The original memory concern was
   written when keepers were a new surface; modern machines absorb the
   per-fiber JSON construction (~50 fields × 16 keepers ≈ a few MB)
   without visible pressure.  Env-overridable via
   [MASC_KEEPER_SNAPSHOT_CONCURRENCY] for operators on tight memory
   envelopes (e.g. CI runners) who still want the old behaviour. *)
