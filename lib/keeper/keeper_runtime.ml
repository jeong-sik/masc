(** Keeper_runtime — keeper reconciliation and keepalive bootstrap.
    Runtime-only mutable state stays behind keeper runtime/execution modules. *)

open Keeper_types

(** #10061: compare personality text fields ignoring leading/trailing
    whitespace.  The TOML heredoc parser drops the newline before the
    closing triple-quote; the state JSON writer preserves the in-
    memory value.  That 1-byte drift drives a re-sync storm on every
    hot-reload tick unless the compare normalizes whitespace.

    Layer 1 (personality SSOT unification, see
    [planning/2026-04-25-keeper-identity-canonicalization-rfc.md]):
    [String.trim] alone is insufficient — when the persisted text
    exceeds [Keeper_config.prompt_render_max_bytes] (e.g. nick0cave's
    357-byte will), the read path normalises to ~319 bytes via
    [normalize_self_model_text], while [target_will] computed from
    [apply_default defaults.will meta.will] keeps the raw 357-byte
    value.  trim-only compare flagged that 38-byte gap as drift on
    every reconcile tick (~2880 redundant writes/day for nick0cave).
    Apply the same byte-cap normalisation on both sides so write
    preserves disk-of-record (raw bytes), but compare uses the
    capped form that the prompt actually renders.  Disk data is
    preserved; loop terminates. *)
let personality_text_equal a b =
  let one_field s : Keeper_personality_io.coerced_personality =
    { Keeper_personality_io.will = s; needs = ""; desires = ""; instructions = "" }
    |> Keeper_personality_io.to_prompt_form
         ~max_bytes:Keeper_config.prompt_render_max_bytes
    |> Keeper_personality_io.coerce
  in
  match Keeper_personality_io.compare_normalized (one_field a) (one_field b) with
  | `Equal -> true
  | `Drift _ -> false

(** #10269: when [personality_text_equal] reports a mismatch, the
    operator needs to know WHICH personality field differs and HOW
    badly.  Pre-fix the re-sync log was opaque
    ([re-syncing [personality] for <name>]) so a fleet of repeated
    re-syncs (371 events / 3000 logs on [nick0cave] alone, 12% of all
    log volume) carried no information about whether the drift was a
    1-byte trailing newline or a structural divergence between the
    TOML source and the persisted JSON.

    [personality_diff_summary] returns one entry per differing field
    formatted as [<field>(cur=<len>,tgt=<len>,diff@<pos>)] where [pos]
    is the byte index of the first character that disagrees AFTER the
    same trimming used by {!personality_text_equal}.  [pos = -1] means
    the trimmed strings agree byte-for-byte (impossible by
    construction here since the entry is only emitted when
    [personality_text_equal] is false; kept as a defensive sentinel).

    The summary is cheap: only invoked on the cycle that actually
    performs a re-sync, never on the stable steady-state path. *)
(* Layer 2 PR-B (commit 6): same delegation pattern. Log format
   "<name>(cur=N,tgt=N,diff@P)" preserved verbatim so dashboard log
   scrapers don't need to migrate. The numbers now reflect post-trim
   bytes (no truncation), so a 357-byte nick0cave will reads cur=357
   instead of cur=319 — the value the disk actually holds. *)
let personality_field_diff_entry name current target =
  let one_field s : Keeper_personality_io.coerced_personality =
    Keeper_personality_io.coerce
      { will = s; needs = ""; desires = ""; instructions = "" }
  in
  match
    Keeper_personality_io.compare_normalized (one_field current) (one_field target)
  with
  | `Equal -> None
  | `Drift diffs ->
      (* compare_normalized only inspected the [will] slot we wrapped
         around the input; the diff list therefore has at most one
         entry. *)
      (match diffs with
       | [] -> None
       | d :: _ ->
           Some
             (Printf.sprintf "%s(cur=%d,tgt=%d,diff@%d)" name
                d.current_bytes d.target_bytes d.diff_offset))

let personality_diff_summary fields =
  List.filter_map
    (fun (name, current, target) ->
      personality_field_diff_entry name current target)
    fields

(** #10269: per-call helper used at runtime re-sync sites (this PR).
    Complements [personality_diff_summary] (batch over a list) by
    emitting raw + trimmed previews on a single field at the moment a
    re-sync fires.  Different output shape from
    [personality_field_diff_entry] above:
    [field(raw_meta_len=N raw_target_len=N trim_meta=S trim_target=S)]
    so dashboards can distinguish raw-length drift from trimmed-content
    drift (TOML triple-quote drop vs JSON encoding drift vs persona
    overlay).  Returns [None] when the two trim-equal so steady-state
    keepers stay quiet.  Trimmed previews truncated to 32 bytes each
    to keep a wide [instructions] field log-friendly. *)
let personality_field_diff_summary ~field ~current ~target =
  if personality_text_equal current target then None
  else
    let preview s =
      let trimmed = String.trim s in
      if String.length trimmed <= 32 then trimmed
      else String.sub trimmed 0 32 ^ "..."
    in
    Some
      (Printf.sprintf
         "%s(raw_meta_len=%d raw_target_len=%d trim_meta=%S trim_target=%S)"
         field
         (String.length current) (String.length target)
         (preview current) (preview target))


type boot_meta_resolution = {
  meta : keeper_meta;
  materialized : bool;
}

let bootable_keeper_names config =
  configured_keeper_names config
  |> List.filter (fun name ->
         match read_meta_file_path (keeper_meta_path config name) with
         | Ok (Some meta) -> not meta.paused && meta.autoboot_enabled
         | Ok None ->
             (match (load_keeper_profile_defaults name).autoboot_enabled with
              | Some false -> false
              | Some true | None -> true)
         | Error _ -> true)

(* PR-3b1: convert a credential lookup name to its canonical
   keeper-<n>-agent form when it refers to a bootable keeper.
   Non-keeper names (dashboard, admin, codex-mcp-client, ...) are
   returned unchanged so this is safe to apply at any lookup site.
   Spec: AuthIdentityFSM.tla I1 IdentityBindsToken (a token must
   bind to one principal -- the bare-name lookup path that
   scaffolded dual-identity is starved by callers always asking for
   the canonical form). *)
let canonicalize_if_keeper config name =
  let stable = Keeper_types_profile.strip_keeper_prefix name in
  if List.mem stable (configured_keeper_names config) then
    Keeper_types_profile.keeper_agent_name stable
  else
    name

(** Apply a TOML profile default to a runtime meta value.
    [Some v] from TOML overrides; [None] keeps the current runtime value. *)
let apply_default opt current = match opt with Some v -> v | None -> current

(** Same as [apply_default] but both TOML and meta are option-typed. *)
let apply_default_opt opt current = match opt with Some _ -> opt | None -> current

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let invalid_profile_defaults_error ~keeper_name detail =
  if contains_substring detail "cascade_name" then
    Printf.sprintf
      "invalid profile.cascade_name for keeper %s: unknown cascade_name: %s"
      keeper_name detail
  else
    Printf.sprintf "invalid keeper profile for keeper %s: %s" keeper_name detail

let effective_declarative_cascade_name
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) =
  match defaults.cascade_name, defaults.manifest_path with
  | Some cascade_name, _ ->
      Keeper_cascade_profile.normalize_declared_name cascade_name
  | None, Some _ -> Keeper_config.default_cascade_name
  | None, None ->
      Keeper_cascade_profile.normalize_declared_name meta.cascade_name

let resynced_tool_access
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) =
  let current_preset =
    match meta.tool_access with
    | Preset { preset; _ } -> Some preset
    | Custom _ -> None
  in
  let current_also_allow = tool_access_also_allowlist meta.tool_access in
  let target_preset =
    match defaults.tool_preset with
    | Some raw -> tool_preset_of_string raw
    | None -> current_preset
  in
  let target_also_allow =
    apply_default defaults.tool_also_allow current_also_allow
  in
  match target_preset with
  | Some preset ->
      Preset { preset; also_allow = target_also_allow }
  | None -> meta.tool_access

let ensure_keeper_meta config name =
  match read_meta config name with
  | Ok (Some meta) ->
    (
    (* Re-sync ALL declarative keeper fields from profile/env defaults on bootstrap.
       Persisted meta may have stale values from a previous session;
       persona config (TOML) plus explicit env overrides are the source of truth.
       Fields where TOML has [Some v] are overwritten; [None] keeps runtime value. *)
    let defaults_result =
      Keeper_types_profile.load_keeper_profile_defaults_result meta.name
    in
    match defaults_result with
    | Error detail ->
        Error (invalid_profile_defaults_error ~keeper_name:meta.name detail)
    | Ok defaults ->

    (* --- Proactive --- *)
    let target_proactive =
      apply_default defaults.proactive_enabled Keeper_config.default_proactive_enabled in
    let target_idle_sec =
      apply_default defaults.proactive_idle_sec Keeper_config.default_proactive_idle_sec in
    let target_cooldown_sec =
      apply_default defaults.proactive_cooldown_sec Keeper_config.default_proactive_cooldown_sec in
    let target_tool_access = resynced_tool_access defaults meta in
    let target_room_signal_prompt_enabled =
      match Keeper_config.keeper_room_signal_prompt_enabled_override () with
      | Some override -> override
      | None ->
          Option.value
            ~default:
              (tool_access_default_room_signal_prompt_enabled
                 ~default:Keeper_config.default_room_signal_prompt_enabled
                 target_tool_access)
            defaults.room_signal_prompt_enabled
    in
    let target_denylist = apply_default defaults.tool_denylist meta.tool_denylist in
    let target_models = apply_default defaults.models meta.models in
    let target_social_model =
      apply_default defaults.social_model meta.social_model
      |> Keeper_social_model.normalize_social_model in
    let target_cascade_name =
      effective_declarative_cascade_name defaults meta
    in
    match
      Cascade_catalog_runtime.resolve_declared_name
        ~raw_name:target_cascade_name
        ()
    with
    | Error detail ->
        let field =
          match defaults.cascade_name, defaults.manifest_path with
          | Some _, _ -> "profile.cascade_name"
          | None, Some _ -> "manifest.default_cascade_name"
          | None, None -> "meta.cascade_name"
        in
        let raw_value =
          match defaults.cascade_name, defaults.manifest_path with
          | Some cascade_name, _ -> cascade_name
          | None, Some _ -> Keeper_config.default_cascade_name
          | None, None -> meta.cascade_name
        in
        let msg =
          Printf.sprintf
            "invalid %s %S for keeper %s: %s"
            field raw_value meta.name detail
        in
        Log.Keeper.error "%s" msg;
        Error msg
    | Ok resolved_target_cascade_name ->
    let target_tool_preset_source =
      match defaults.tool_preset_source with
      | Some _ as s -> s
      | None -> meta.tool_preset_source
    in

    (* --- Personality --- *)
    let target_goal = apply_default defaults.goal meta.goal in
    let target_short_goal = apply_default defaults.short_goal meta.short_goal in
    let target_mid_goal = apply_default defaults.mid_goal meta.mid_goal in
    let target_long_goal = apply_default defaults.long_goal meta.long_goal in
    let target_will = apply_default defaults.will meta.will in
    let target_needs = apply_default defaults.needs meta.needs in
    let target_desires = apply_default defaults.desires meta.desires in
    let target_instructions = apply_default defaults.instructions meta.instructions in

    (* --- Policy --- *)
    let target_policy_voice_enabled =
      apply_default defaults.policy_voice_enabled meta.policy_voice_enabled in
    let target_autoboot_enabled =
      apply_default defaults.autoboot_enabled meta.autoboot_enabled in
    let target_mention_targets =
      match defaults.mention_targets with [] -> meta.mention_targets | xs -> xs in
    let target_active_goal_ids =
      apply_default defaults.active_goal_ids meta.active_goal_ids in
    (* Defense-in-depth (#11080 sibling): keeper sandbox_profile MUST be
       declared. The previous behaviour silently fell through to
       [default_sandbox_profile = Local] when TOML omitted the key,
       which strips docker isolation from any operator who forgets to
       set it (or copies a stale persona JSON: persona profiles are
       declared elsewhere as not allowed to own this field). Reject at
       reconcile time so the keeper visibly fails to boot rather than
       running un-sandboxed.

       Persona-only keepers cannot satisfy this check today and must
       gain a TOML wrapper that sets [sandbox_profile]. The
       [Keeper_types_profile.default_sandbox_profile] constant is left
       in place because other read paths (JSON parser, env override,
       turn_up_args) still need a value when reading already-persisted
       meta. *)
    let target_sandbox_profile_result =
      match defaults.sandbox_profile with
      | Some sp -> Ok sp
      | None ->
        let manifest_hint =
          match defaults.manifest_path with
          | Some path -> Printf.sprintf " (loaded from %s)" path
          | None -> ""
        in
        let msg =
          Printf.sprintf
            "keeper %s rejected: sandbox_profile is required (allowed: %s)%s. \
             Add e.g. `sandbox_profile = \"docker\"` to the keeper TOML."
            meta.name
            (String.concat ", "
               Keeper_types_profile.valid_sandbox_profile_strings)
            manifest_hint
        in
        Log.Keeper.warn "%s" msg;
        Error msg
    in
    (match target_sandbox_profile_result with
     | Error e -> Error e
     | Ok target_sandbox_profile ->
    let target_sandbox_image =
      apply_default_opt defaults.sandbox_image meta.sandbox_image in
    let target_network_mode =
      apply_default defaults.network_mode
        (Keeper_types_profile.default_network_mode_for_profile target_sandbox_profile) in
    let target_allowed_paths =
      apply_default defaults.allowed_paths [] in

    (* --- Work Discovery --- *)
    let target_wd_enabled =
      apply_default_opt defaults.work_discovery_enabled meta.work_discovery_enabled in
    let target_wd_sources =
      apply_default_opt defaults.work_discovery_sources meta.work_discovery_sources in
    let target_wd_interval =
      apply_default_opt defaults.work_discovery_interval_sec meta.work_discovery_interval_sec in
    let target_wd_guidance =
      apply_default_opt defaults.work_discovery_guidance meta.work_discovery_guidance in

    (* --- Telemetry Feedback --- *)
    let target_tf_enabled =
      apply_default_opt defaults.telemetry_feedback_enabled meta.telemetry_feedback_enabled in
    let target_tf_window =
      apply_default_opt defaults.telemetry_feedback_window_hours meta.telemetry_feedback_window_hours in

    (* --- Per-Provider Timeout --- *)
    let target_per_provider_timeout =
      match defaults.per_provider_timeout_state with
      | Keeper_types_profile.Per_provider_timeout_unset ->
          normalize_per_provider_timeout_opt
            ~source:(Printf.sprintf "keeper runtime %s" name)
            meta.per_provider_timeout_s
      | Keeper_types_profile.Per_provider_timeout_invalid -> None
      | Keeper_types_profile.Per_provider_timeout_set ->
          defaults.per_provider_timeout
    in

    (* --- Always Approve --- *)
    let target_always_approve =
      apply_default_opt defaults.always_approve meta.always_approve
    in
    (* --- OAS Env --- *)
    let target_oas_env =
      match defaults.oas_env with
      | [] -> meta.oas_env
      | env -> env
    in
    (* --- Change detection by category --- *)
    let proactive_changed =
      meta.proactive.enabled <> target_proactive
      || meta.proactive.idle_sec <> target_idle_sec
      || meta.proactive.cooldown_sec <> target_cooldown_sec in
    let signal_changed =
      meta.room_signal_prompt_enabled <> target_room_signal_prompt_enabled in
    let denylist_changed = meta.tool_denylist <> target_denylist in
    let models_changed = meta.models <> target_models in
    let social_model_changed = meta.social_model <> target_social_model in
    (* [meta.cascade_name] may be a raw TOML/JSON value while
       [resolved_target_cascade_name] is the validated runtime catalog
       name. Normalize the meta side only so alias cleanup does not
       register as a semantic change. *)
    let cascade_changed =
      Keeper_cascade_profile.normalize_declared_name meta.cascade_name
      <> resolved_target_cascade_name
    in
    (* #10061: persisted state vs TOML source can differ by a single
       trailing newline when OCaml string literals round-trip through
       the TOML writer (heredoc [""" … """] closing sequence drops the
       final newline) or through an older binary that wrote the field
       with extra whitespace. The semantic content of these prose
       fields does not care about trailing whitespace, yet a byte-
       level [<>] compare marks every 30 s hot-reload tick as a
       personality change, producing a re-sync storm (2880 redundant
       writes/day on nick0cave alone; other 13 keepers: 0 events).
       Normalise both sides with [String.trim] so only meaningful
       content drives resync. *)
    (* #10269: name the diverging fields so the re-sync log carries
       the diagnostic upstream (length and first-diff offset) instead
       of the opaque [personality] category. *)
    let personality_diff_entries =
      personality_diff_summary
        [
          ("goal", meta.goal, target_goal);
          ("short_goal", meta.short_goal, target_short_goal);
          ("mid_goal", meta.mid_goal, target_mid_goal);
          ("long_goal", meta.long_goal, target_long_goal);
          ("will", meta.will, target_will);
          ("needs", meta.needs, target_needs);
          ("desires", meta.desires, target_desires);
          ("instructions", meta.instructions, target_instructions);
        ]
    in
    let personality_changed = personality_diff_entries <> [] in
    let policy_changed =
      meta.policy_voice_enabled <> target_policy_voice_enabled
      || meta.autoboot_enabled <> target_autoboot_enabled
      || meta.mention_targets <> target_mention_targets
      || meta.active_goal_ids <> target_active_goal_ids
      || meta.tool_access <> target_tool_access
      || meta.tool_preset_source <> target_tool_preset_source
      || meta.sandbox_profile <> target_sandbox_profile
      || meta.network_mode <> target_network_mode
      || meta.allowed_paths <> target_allowed_paths
      || meta.always_approve <> target_always_approve in
    let discovery_changed =
      meta.work_discovery_enabled <> target_wd_enabled
      || meta.work_discovery_sources <> target_wd_sources
      || meta.work_discovery_interval_sec <> target_wd_interval
      || meta.work_discovery_guidance <> target_wd_guidance in
    let telemetry_changed =
      meta.telemetry_feedback_enabled <> target_tf_enabled
      || meta.telemetry_feedback_window_hours <> target_tf_window in
    let timeout_policy_changed =
      meta.per_provider_timeout_s <> target_per_provider_timeout in
    let oas_env_changed = meta.oas_env <> target_oas_env in
    let any_changed =
      proactive_changed || signal_changed || denylist_changed || models_changed
      || social_model_changed
      || cascade_changed
      || personality_changed || policy_changed || discovery_changed
      || telemetry_changed || timeout_policy_changed || oas_env_changed in

    if any_changed then begin
      let cats = List.filter_map Fun.id [
        (if proactive_changed then Some "proactive" else None);
        (if signal_changed then Some "signal" else None);
        (if denylist_changed then Some "denylist" else None);
        (if models_changed then Some "models" else None);
        (if social_model_changed then Some "social_model" else None);
        (if cascade_changed then Some "cascade" else None);
        (if personality_changed then
           Some
             (Printf.sprintf "personality:%s"
                (String.concat "+" personality_diff_entries))
         else None);
        (if policy_changed then Some "policy" else None);
        (if discovery_changed then Some "discovery" else None);
        (if telemetry_changed then Some "telemetry" else None);
        (if timeout_policy_changed then Some "timeout_policy" else None);
        (if oas_env_changed then Some "oas_env" else None);
      ] in
      Log.Keeper.info
        "ensure_keeper_meta: re-syncing [%s] for %s"
        (String.concat "," cats)
        meta.name;
      (* #10269: nick0cave alone re-syncs [personality] on every reconcile
         tick (~371 events / 3000 logs).  When personality is in [cats],
         emit a follow-up info line listing the specific fields that
         differ along with their raw lengths and trim-normalised
         previews so root cause (TOML triple-quote, JSON encoding drift,
         persona overlay) is visible without code-reading. *)
      if personality_changed then begin
        let diffs =
          List.filter_map Fun.id
            [
              personality_field_diff_summary ~field:"goal"
                ~current:meta.goal ~target:target_goal;
              personality_field_diff_summary ~field:"short_goal"
                ~current:meta.short_goal ~target:target_short_goal;
              personality_field_diff_summary ~field:"mid_goal"
                ~current:meta.mid_goal ~target:target_mid_goal;
              personality_field_diff_summary ~field:"long_goal"
                ~current:meta.long_goal ~target:target_long_goal;
              personality_field_diff_summary ~field:"will"
                ~current:meta.will ~target:target_will;
              personality_field_diff_summary ~field:"needs"
                ~current:meta.needs ~target:target_needs;
              personality_field_diff_summary ~field:"desires"
                ~current:meta.desires ~target:target_desires;
              personality_field_diff_summary ~field:"instructions"
                ~current:meta.instructions ~target:target_instructions;
            ]
        in
        Log.Keeper.info
          "ensure_keeper_meta: personality drift fields for %s: %s"
          meta.name
          (String.concat "; " diffs)
      end;
      let updated = { meta with
        proactive = {
          enabled = target_proactive;
          idle_sec = target_idle_sec;
          cooldown_sec = target_cooldown_sec;
        };
        room_signal_prompt_enabled = target_room_signal_prompt_enabled;
        tool_denylist = target_denylist;
        models = target_models;
        social_model = target_social_model;
        (* Preserve raw [meta.cascade_name] when the cascade itself did
           not change, even if another field (personality, policy, ...)
           triggered a re-sync.  Otherwise a reconcile caused by an
           unrelated field would silently canonicalize cascade_name and
           hide drift from the dashboard [canonical] column. *)
        cascade_name =
          if cascade_changed then resolved_target_cascade_name
          else meta.cascade_name;
        goal = target_goal;
        short_goal = target_short_goal;
        mid_goal = target_mid_goal;
        long_goal = target_long_goal;
        will = target_will;
        needs = target_needs;
        desires = target_desires;
        instructions = target_instructions;
        policy_voice_enabled = target_policy_voice_enabled;
        autoboot_enabled = target_autoboot_enabled;
        mention_targets = target_mention_targets;
        active_goal_ids = target_active_goal_ids;
        tool_access = target_tool_access;
        tool_preset_source = target_tool_preset_source;
        sandbox_profile = target_sandbox_profile;
        sandbox_image = target_sandbox_image;
        network_mode = target_network_mode;
        allowed_paths = target_allowed_paths;
        work_discovery_enabled = target_wd_enabled;
        work_discovery_sources = target_wd_sources;
        work_discovery_interval_sec = target_wd_interval;
        work_discovery_guidance = target_wd_guidance;
        telemetry_feedback_enabled = target_tf_enabled;
        telemetry_feedback_window_hours = target_tf_window;
        per_provider_timeout_s = target_per_provider_timeout;
        always_approve = target_always_approve;
        oas_env = target_oas_env;
        updated_at = now_iso ();
      } in
      match write_meta config updated with
      | Ok () -> Ok updated
      | Error e ->
        Prometheus.inc_counter
          Prometheus.metric_keeper_write_meta_failures
          ~labels:[("keeper", updated.name); ("phase", "ensure_meta_resync")]
          ();
        Log.Keeper.warn "ensure_keeper_meta: write_meta re-sync failed: %s" e;
        Ok meta
    end
    else Ok meta))
  | Ok None ->
    Log.Keeper.warn
      "ensure_keeper_meta: no persistent meta for %s — run keeper_up to initialize" name;
    Error (Printf.sprintf "no persistent meta for %s — run keeper_up to initialize" name)
  | Error msg -> Error msg

let load_or_materialize_boot_meta (ctx : _ context) name
    : (boot_meta_resolution, string) result =
  match ensure_keeper_meta ctx.config name with
  | Ok meta -> Ok { meta; materialized = false }
  | Error original_error -> (
      match Config_dir_resolver.keeper_toml_path_opt name with
      | None -> Error original_error
      | Some toml_path ->
          Log.Keeper.info
            "bootstrapping declarative keeper %s from %s"
            name toml_path;
          let ok, body =
            Keeper_turn.handle_keeper_up ctx
              (`Assoc [ ("name", `String name) ])
          in
          if not ok then
            Error
              (Printf.sprintf
                 "failed to materialize declarative keeper %s from %s: %s"
                 name toml_path body)
          else
            match read_meta ctx.config name with
            | Ok (Some meta) -> Ok { meta; materialized = true }
            | Ok None ->
                Error
                  (Printf.sprintf
                     "materialized declarative keeper %s from %s but no meta was written"
                     name toml_path)
            | Error msg ->
                Error
                  (Printf.sprintf
                     "materialized declarative keeper %s from %s but failed to reload meta: %s"
                     name toml_path msg))

type keeper_bootstrap_stats = {
  enabled: bool;
  scanned: int;
  started: int;
  stale: int;
  recovering: int;
}

let bootstrap_existing_keepers ctx : keeper_bootstrap_stats =
  if not Env_config.KeeperBootstrap.enabled then
    { enabled = false; scanned = 0; started = 0; stale = 0; recovering = 0 }
  else
    let now_ts = Time_compat.now () in
    let proactive_warmup_sec = keeper_bootstrap_proactive_warmup_sec () in
    let stale_turn_sec =
      max 0.0 Env_config.KeeperBootstrap.stale_turn_seconds
    in
    let max_scan =
      max 0 Env_config.KeeperBootstrap.max_scan
    in
    let max_keepers = Keeper_runtime_resolved.bootstrap_max_active_keepers () in
    let remaining_slots =
      ref
        (if max_keepers > 0 then
           max 0 (max_keepers - Keeper_registry.count_running ())
         else
           max_int)
    in
    let entries = bootable_keeper_names ctx.config |> take max_scan in
    let (enabled, scanned, started, stale, recovering) =
      List.fold_left
        (fun (enabled_acc, scanned_acc, started_acc, stale_acc, recovering_acc) name ->
          match load_or_materialize_boot_meta ctx name with
          | Error _ ->
              (enabled_acc, scanned_acc + 1, started_acc, stale_acc, recovering_acc)
          | Ok { meta = m; materialized } ->
              if m.paused then
                (enabled_acc, scanned_acc + 1, started_acc, stale_acc, recovering_acc)
              else
              let stale_now =
                (not materialized)
                && stale_turn_sec > 0.0
                && (m.runtime.usage.last_turn_ts <= 0.0
                    || now_ts -. m.runtime.usage.last_turn_ts >= stale_turn_sec)
              in
              let already_running =
                Keeper_registry.is_running ~base_path:ctx.config.base_path m.name
              in
              let started_here =
                if materialized then
                  let started_now =
                    Keeper_registry.is_running
                      ~base_path:ctx.config.base_path m.name
                  in
                  if started_now && max_keepers > 0 then
                    remaining_slots := max 0 (!remaining_slots - 1);
                  started_now
                else if already_running then false
                else if max_keepers > 0 && !remaining_slots <= 0 then false
                else (
                  Keeper_supervisor.supervise_keepalive
                    ~proactive_warmup_sec ctx m;
                  let started_now =
                    Keeper_registry.is_running
                      ~base_path:ctx.config.base_path m.name
                  in
                  if started_now && max_keepers > 0 then
                    remaining_slots := !remaining_slots - 1;
                  started_now
                )
              in
              ( true,
                scanned_acc + 1,
                started_acc + (if started_here then 1 else 0),
                stale_acc + (if stale_now then 1 else 0),
                recovering_acc + (if stale_now && started_here then 1 else 0) ))
        (false, 0, 0, 0, 0)
        entries
    in
    { enabled; scanned; started; stale; recovering }

(** Start the supervisor sweep Pulse loop.
    Runs alongside existing keepalive bootstrap, scanning for
    zombie fibers and restarting them with exponential backoff.
    Called once from start_existing_keepalives after bootstrap. *)
let supervisor_sweeps : (string, Pulse.t) Hashtbl.t =
  Hashtbl.create 4
let supervisor_sweeps_mu = Eio.Mutex.create ()

let with_sweeps_ro f = Eio_guard.with_mutex_ro supervisor_sweeps_mu f
let with_sweeps_rw f = Eio_guard.with_mutex supervisor_sweeps_mu f

let supervisor_sweep_running base_path =
  with_sweeps_ro (fun () ->
    match Hashtbl.find_opt supervisor_sweeps base_path with
    | Some pulse -> Pulse.is_alive pulse
    | None -> false)

let stop_supervisor_sweep base_path =
  with_sweeps_rw (fun () ->
    match Hashtbl.find_opt supervisor_sweeps base_path with
    | Some pulse ->
      Pulse.shutdown pulse;
      Hashtbl.remove supervisor_sweeps base_path
    | None -> ())

let update_supervisor_sweep_interval base_path interval_sec =
  with_sweeps_ro (fun () ->
    match Hashtbl.find_opt supervisor_sweeps base_path with
    | Some pulse ->
      let rhythm : Pulse.rhythm =
        { base_s = interval_sec; min_s = interval_sec;
          max_s = interval_sec; quiet = (0, 0) }
      in
      Pulse.set_rhythm pulse rhythm;
      true
    | None -> false)

let start_supervisor_sweep ctx =
  let base_path = ctx.config.base_path in
  if supervisor_sweep_running base_path then ()
  else begin
    let consumer : (module Pulse.Consumer) =
      (module struct
        let name = "keeper-supervisor-sweep"
        let should_act _beat = true
        let on_beat _beat =
          (try Keeper_supervisor.sweep_and_recover ctx
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Prometheus.inc_counter
               Prometheus.metric_keeper_supervisor_sweep_failures
               ~labels:[("origin", "keeper_runtime")]
               ();
             Log.Keeper.error "supervisor sweep failed: %s"
               (Printexc.to_string exn));
          (* #12801 Liveness Recovery Supervisor: attempt to auto-recover Dead
             keepers whose root cause has cleared.  Runs after sweep_and_recover
             so any newly-crashed keepers are processed by sweep first. *)
          (try Keeper_supervisor.liveness_recovery_scan ctx
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Prometheus.inc_counter
               Prometheus.metric_keeper_supervisor_sweep_failures
               ~labels:[("origin", "liveness_recovery")]
               ();
             Log.Keeper.error "liveness recovery scan failed: %s"
               (Printexc.to_string exn));
          (* TOML hot-reload: re-sync declarative fields for running keepers.
             Runs after sweep_and_recover so TOML edits take effect within
             one sweep cycle (~30s) without server restart. *)
          (try
            Keeper_registry.all ~base_path ()
            |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
              match entry.phase with
              | Keeper_state_machine.Running ->
                  (match ensure_keeper_meta ctx.config entry.name with
                   | Ok updated_meta ->
                       (* Propagate the updated meta back into the registry so
                          subsequent turns observe the new cascade_name (and
                          any other reconciled fields) immediately.  Without
                          this the file is updated but the in-memory
                          [registry_entry.meta] stays stale until restart. *)
                       Keeper_registry.update_meta ~base_path entry.name updated_meta
                   | Error e ->
                       Log.Keeper.warn "TOML reconcile failed for %s: %s"
                         entry.name e)
              | _ -> ())
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             Prometheus.inc_counter
               Prometheus.metric_keeper_toml_reconcile_sweep_failures
               ~labels:[("origin", "keeper_runtime")]
               ();
             Log.Keeper.error "TOML reconcile sweep failed: %s"
               (Printexc.to_string exn));
          (* #10125: advance the supervisor liveness gauge after a
             completed beat.  Stale gauge (now - last > 2 × interval)
             tells operators the sweep stopped. *)
          Prometheus.set_gauge
            Prometheus.metric_keeper_supervisor_last_sweep_unixtime
            ~labels:[ ("base_path", base_path) ]
            (Unix.gettimeofday ());
          Ok ()
      end)
    in
    let sweep_sec = Runtime_params.get Governance_registry.keeper_supervisor_sweep_sec in
    let p = Pulse.create
      ~clock:ctx.clock
      ~rhythm:{ Pulse.base_s = sweep_sec;
                 min_s = sweep_sec;
                 max_s = sweep_sec;
                 quiet = (0, 0) }
      ~lifecycle:Always_on
      ~consumers:[consumer]
    in
    with_sweeps_rw (fun () ->
      Hashtbl.replace supervisor_sweeps base_path p);
    Pulse.run ~sw:ctx.sw p;
    (* #10125: counter increments once per actual Pulse start.
       After a server restart, if this stays at 0 the supervisor
       never came up — operators alert on absence of advancement. *)
    Prometheus.inc_counter
      Prometheus.metric_keeper_supervisor_sweep_starts
      ~labels:[ ("base_path", base_path) ]
      ();
    (* Initialize the liveness gauge to "now" so dashboards do not
       start at unixtime=0 (which would look infinitely stale).  The
       on_beat will overwrite this on every subsequent sweep. *)
    Prometheus.set_gauge
      Prometheus.metric_keeper_supervisor_last_sweep_unixtime
      ~labels:[ ("base_path", base_path) ]
      (Unix.gettimeofday ());
    Log.Keeper.info "keeper supervisor sweep started (interval %.0fs)" sweep_sec
  end

(** #10125: supervisor sweep age helper.  Returns the wall-clock
    seconds since the last successful sweep beat, or [None] if the
    gauge was never set (i.e., the sweep never started in this
    process).  Dashboards use this to render a [stale] badge when
    the sweep stalls; tests use it to verify the gauge advances. *)
let supervisor_sweep_age_seconds ~(base_path : string) : float option =
  match
    Prometheus.get_metric_value
      Prometheus.metric_keeper_supervisor_last_sweep_unixtime
      ~labels:[ ("base_path", base_path) ]
      ()
  with
  | None -> None
  | Some last ->
    let now = Unix.gettimeofday () in
    Some (now -. last)

let existing_keepalive_bootstrap_done : (string, unit) Hashtbl.t =
  Hashtbl.create 4

let has_boot_entries config =
  bootable_keeper_names config <> []

(* #10125: extracted predicate so it can be unit-tested without
   spinning up an Eio + Pulse runtime.  See [maybe_start_supervisor_sweep]
   for the WHY. *)
let should_start_supervisor_sweep
    ~(config : Coord.config)
    ~(stats : keeper_bootstrap_stats) : bool =
  let _ = stats.enabled in
  stats.started > 0
  || Keeper_registry.count_running ~base_path:config.base_path () > 0
  || has_boot_entries config

let maybe_start_supervisor_sweep ctx (stats : keeper_bootstrap_stats) =
  (* #10125: drop the [stats.enabled] precondition.  The previous
     gate required bootstrap to have processed at least one keeper
     successfully ([enabled = true] only when [bootable_keeper_names]
     was non-empty AND at least one entry got past
     [load_or_materialize_boot_meta]).  In the 2026-04-24 production
     incident every bootstrap entry hit a transient
     [load_or_materialize_boot_meta] error after a server restart,
     so [stats.enabled] stayed [false] even though 14 keeper meta
     files were on disk — supervisor never started, fleet stayed
     dead for 4h+.

     Decouple supervisor startup from bootstrap success: if there
     are bootable keepers on disk OR any are already running OR
     any started this boot, run the sweep.  The supervisor can
     recover keepers that bootstrap failed to load, which is
     exactly what the sweep is for.  Without this change, a
     transient load failure during bootstrap silently disables
     auto-recovery for the rest of the server lifetime. *)
  if should_start_supervisor_sweep ~config:ctx.config ~stats
  then start_supervisor_sweep ctx

let start_existing_keepalives ctx =
  let base_path = ctx.config.base_path in
  (* Atomic check-and-set: eliminates TOCTOU race on the gate. *)
  let should_run =
    if Hashtbl.mem existing_keepalive_bootstrap_done base_path then false
    else begin
      Hashtbl.replace existing_keepalive_bootstrap_done base_path ();
      true
    end
  in
  if not should_run then ()
  else begin
    try
      let stats = bootstrap_existing_keepers ctx in
      if keeper_debug then
        Log.Keeper.debug "bootstrap_existing_keepers enabled=%b scanned=%d started=%d stale=%d recovering=%d"
          stats.enabled stats.scanned stats.started stats.stale
          stats.recovering;
      maybe_start_supervisor_sweep ctx stats
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      (* Retry bootstrap on next keeper tool call if this attempt failed. *)
      Hashtbl.remove existing_keepalive_bootstrap_done base_path;
      raise exn
  end

let stop_keepalive ?base_path name =
  Keeper_keepalive.stop_keepalive ?base_path name

let reset_test_state base_path =
  stop_supervisor_sweep base_path;
  Hashtbl.remove existing_keepalive_bootstrap_done base_path
