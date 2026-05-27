(** Keeper meta JSON removed-field scrub helpers.

    Kept below the codec/parser facade so persisted runtime JSON can be
    normalized before strict [keeper_meta] decoding. *)

open Keeper_types_profile
open Keeper_meta_contract

(* Config fields owned by TOML only.  Never written to JSON; scrubbed
   from existing JSON on first write.  The parser still accepts them
   for backward compatibility and seed round-trip.

   Defined here (not in keeper_meta_json.ml) to avoid a cycle:
   keeper_meta_json.ml includes this module, so referencing a value
   defined in keeper_meta_json.ml from here would create
   Keeper_meta_json -> Keeper_meta_json_scrub -> Keeper_meta_json. *)
let config_field_names =
  [ "goal"; "short_goal"; "mid_goal"; "long_goal"
  ; "social_model"; "cascade_name"; "cascade_ref"
  ; "will"; "needs"; "desires"; "instructions"
  ; "sandbox_profile"; "sandbox_image"; "network_mode"; "allowed_paths"
  ; "tool_access"; "tool_preset_source"; "tool_denylist"
  ; "mention_targets"; "room_signal_prompt_enabled"
  ; "joined_room_ids"
  ; "proactive_enabled"; "proactive_idle_sec"; "proactive_cooldown_sec"
  ; "compaction_profile"; "compaction_ratio_gate"
  ; "compaction_message_gate"; "compaction_token_gate"
  ; "continuity_compaction_cooldown_sec"
  ; "max_checkpoint_messages"; "keep_recent_tool_results"
  ; "tool_heavy_msg_threshold"; "tool_heavy_ratio_floor"
  ; "auto_handoff"; "handoff_threshold"; "handoff_cooldown_sec"
  ; "per_provider_timeout_s"; "always_approve"
  ; "autoboot_enabled"; "max_context_override"
  ; "telemetry_feedback_enabled"; "telemetry_feedback_window_hours"
  ]

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ as j -> j
;;

let reject_removed_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error (Printf.sprintf "removed keeper meta fields: %s" (String.concat ", " fields))
;;

let legacy_keeper_meta_tool_policy_key_names =
  [ "tool_preset"; "tool_also_allow"; "tool_custom_allowlist"; "tool_allowlist" ]
;;

let legacy_keeper_meta_key_names =
  [ "allowed_providers"; "last_blocker_class"; "repo_cli_identity" ]
  @ legacy_keeper_meta_tool_policy_key_names
;;

let persisted_retired_keeper_meta_key_names =
  [
    "repo_cli_identity";
    "last_work_discovery_ts";
    "work_discovery_count";
    "work_discovery_enabled";
    "work_discovery_sources";
    "work_discovery_interval_sec";
    "work_discovery_guidance";
  ]
;;

let reject_legacy_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper meta fields are no longer supported: %s"
         (String.concat ", " fields))
;;

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) : Yojson.Safe.t * bool =
  match json with
  | `Assoc fields ->
    let scrub_candidate_key_names =
      removed_keeper_meta_key_names
      @ persisted_retired_keeper_meta_key_names
      @ config_field_names
    in
    let removed_present =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key scrub_candidate_key_names then Some key else None)
    in
    let removed_to_scrub =
      removed_present
      |> List.filter (fun key ->
        (not (List.mem key legacy_keeper_meta_key_names))
        || List.mem key persisted_retired_keeper_meta_key_names)
    in
    if removed_to_scrub = []
    then json, false
    else (
      let migrate_legacy_disabled_keepalive =
        (match List.assoc_opt "presence_keepalive" fields with
         | Some (`Bool false) -> true
         | Some _ | None -> false)
        && not (List.mem_assoc "paused" fields)
      in
      let scrubbed =
        let base = drop_assoc_keys removed_to_scrub json in
        match base with
        | `Assoc base_fields when migrate_legacy_disabled_keepalive ->
          `Assoc (("paused", `Bool true) :: List.remove_assoc "paused" base_fields)
        | `Assoc _ -> base
        | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> base
      in
      let content = Yojson.Safe.pretty_to_string scrubbed in
      (try
         Fs_compat.save_file path content;
         Log.Keeper.info
           "scrubbed legacy keeper meta fields for %s: %s%s"
           path
           (String.concat ", " removed_to_scrub)
           (if migrate_legacy_disabled_keepalive
            then " (migrated presence_keepalive=false to paused=true)"
            else "")
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Prometheus.inc_counter
           Keeper_metrics.(to_string MetaJsonFailures)
           ~labels:[("site", "scrub")]
           ();
         Log.Keeper.warn
           "failed to scrub removed keeper meta fields for %s: %s"
           path
           (Printexc.to_string exn));
      scrubbed, true)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ as j -> j, false
;;
