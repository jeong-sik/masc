(** Current metrics-ledger tool audit for operator control snapshots. *)

let collect_recent_tool_names = Operator_control_snapshot_tool_names.collect_recent_tool_names

let recent_tool_names_from_files config keeper_name =
  let metrics_lines =
    let store = Keeper_types_support.keeper_metrics_store config keeper_name in
    Dated_jsonl.read_recent_lines store 120
  in
  collect_recent_tool_names metrics_lines
;;

let keeper_tool_audit_fields config (meta : Keeper_meta_contract.keeper_meta) =
  let recent_tool_names = recent_tool_names_from_files config meta.name in
  let snapshot =
    match
      Keeper_status_metrics.latest_tool_audit_snapshot_from_files
        config
        ~keeper_name:meta.name
    with
    | Some snapshot -> snapshot
    | None -> Keeper_status_metrics.empty_tool_audit_snapshot
  in
  ( recent_tool_names
  , snapshot.latest_tool_names
  , snapshot.latest_tool_call_count
  , snapshot.latest_action_source
  , snapshot.tool_audit_source
  , snapshot.tool_audit_at )
;;

let cached_tool_audit_json
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
        , tool_audit_at ) =
      keeper_tool_audit_fields config meta
    in
    `Assoc
      [ "recent_tool_names", `List (List.map (fun v -> `String v) recent_tool_names)
      ; "latest_tool_names", `List (List.map (fun v -> `String v) latest_tool_names)
      ; "latest_tool_call_count", Json_util.option_to_yojson (fun v -> `Int v) latest_tool_call_count
      ; "latest_action_source", Json_util.string_opt_to_json latest_action_source
      ; "tool_audit_source", Json_util.string_opt_to_json tool_audit_source
      ; "tool_audit_at", Json_util.string_opt_to_json tool_audit_at
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
