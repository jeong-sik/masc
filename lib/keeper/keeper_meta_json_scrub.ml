(** Keeper meta JSON scrub helpers.

    Kept below the codec/parser facade so persisted runtime JSON cleanup code
    can share the same TOML-owned field names without introducing a module
    cycle. *)


(* Config/policy fields owned by TOML only. Never written to JSON; scrubbed
   from existing JSON on first write. Persona and instructions are identity
   snapshot fields, not policy config: meta JSON keeps them so dashboards and
   status readers can show the effective keeper without rebuilding the prompt.

   Defined here (not in keeper_meta_json.ml) to avoid a cycle:
   keeper_meta_json.ml includes this module, so referencing a value
   defined in keeper_meta_json.ml from here would create
   Keeper_meta_json -> Keeper_meta_json_scrub -> Keeper_meta_json. *)
let config_field_names =
  [ "goal"
  ; "runtime_id"
  ; "sandbox_profile"; "sandbox_image"; "network_mode"; "allowed_paths"
  ; "tool_denylist"
  ; "mention_targets"
  ; "proactive_enabled"; "proactive_idle_sec"; "proactive_cooldown_sec"
  ; "compaction_profile"; "compaction_ratio_gate"
  ; "compaction_message_gate"; "compaction_token_gate"
  ; "compaction_cooldown_sec"
  ; "max_checkpoint_messages"; "keep_recent_tool_results"
    (* tool_heavy_* fields were removed with the tool_heavy compaction
       trigger; kept here so legacy persisted JSON sheds the dead keys. *)
  ; "tool_heavy_msg_threshold"; "tool_heavy_ratio_floor"
  ; "auto_handoff"; "handoff_threshold"; "handoff_cooldown_sec"
  ; "per_provider_timeout_s"; "always_approve"
    (* NOTE: multimodal_policy is a PERSISTED runtime field: meta_to_json emits
       it (keeper_meta_json.ml) and it is a canonical key. It must NOT be in this
       config-only scrub list: any call-site that rewrites persisted JSON with
       this list would delete "delegate", after which parsing falls back to
       Mm_inherit and the next write re-emits "inherit". The
       test/test_config_runtime_split invariant (no meta_to_json key may be in
       config_field_names) guards this. *)
  ; "autoboot_enabled"; "max_context_override"
  ; "telemetry_feedback_enabled"; "telemetry_feedback_window_hours"
  ]

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ as j -> j
;;

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) : Yojson.Safe.t * bool =
  match json with
  | `Assoc fields ->
    let removed_present =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key config_field_names then Some key else None)
    in
    if removed_present = []
    then json, false
    else (
      let scrubbed = drop_assoc_keys removed_present json in
      let content = Yojson.Safe.pretty_to_string scrubbed in
      (try
         Fs_compat.save_file path content;
         Log.Keeper.info
           "scrubbed TOML-owned keeper meta fields for %s: %s"
           path
           (String.concat ", " removed_present)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Otel_metric_store.inc_counter
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
