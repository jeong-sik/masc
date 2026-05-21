(** Tool audit helpers (lightweight fallback + cached JSON) for operator
    control snapshot, extracted from operator_control_snapshot.ml. *)

module U = Yojson.Safe.Util

let lightweight_tool_audit_fallback_json (meta : Keeper_types.keeper_meta) =
  let last_autonomous = String.trim meta.runtime.last_autonomous_action_at in
  let has_runtime_activity =
    last_autonomous <> ""
    || meta.runtime.autonomous_turn_count > 0
    || meta.runtime.autonomous_action_count > 0
  in
  `Assoc
    [ "allowed_tool_names", `List []
    ; "recent_tool_names", `List []
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
    ]
;;

let cached_tool_audit_json
      ~lightweight
      (config : Coord.config)
      (meta : Keeper_types.keeper_meta)
  =
  let base_hash = Digest.to_hex (Digest.string config.base_path) in
  let cache_key = "kta:" ^ base_hash ^ ":" ^ meta.name in
  if lightweight
  then
    Dashboard_cache.seed_stale_if_missing
      cache_key
      ~stale_for:120.0
      (lightweight_tool_audit_fallback_json meta);
  let ttl = if lightweight then 30.0 else 2.0 in
  Dashboard_cache.get_or_compute cache_key ~ttl (fun () ->
    let ( allowed_tool_names
        , recent_tool_names
        , latest_tool_names
        , latest_tool_call_count
        , latest_action_source
        , tool_audit_source
        , tool_audit_at )
      =
      if lightweight
      then (
        let ( _
            , recent_tool_names
            , latest_tool_names
            , latest_tool_call_count
            , latest_action_source
            , tool_audit_source
            , tool_audit_at )
          =
          keeper_tool_audit_fields ~include_allowed_tools:false config meta
        in
        ( []
        , recent_tool_names
        , latest_tool_names
        , latest_tool_call_count
        , latest_action_source
        , tool_audit_source
        , tool_audit_at ))
      else keeper_tool_audit_fields config meta
    in
    `Assoc
      [ "allowed_tool_names", `List (List.map (fun v -> `String v) allowed_tool_names)
      ; "recent_tool_names", `List (List.map (fun v -> `String v) recent_tool_names)
      ; "latest_tool_names", `List (List.map (fun v -> `String v) latest_tool_names)
      ; "latest_tool_call_count", option_to_json (fun v -> `Int v) latest_tool_call_count
      ; "latest_action_source", string_option_to_json latest_action_source
      ; "tool_audit_source", string_option_to_json tool_audit_source
      ; "tool_audit_at", string_option_to_json tool_audit_at
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
