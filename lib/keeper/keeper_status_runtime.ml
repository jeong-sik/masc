(** Keeper_status_runtime — agent status parsing, health/diagnostic state,
    quiet-hours logic, and surface status helpers.
    Metrics summary aggregation is in Keeper_status_metrics. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Agent staleness threshold — 2 minutes. An agent that hasn't sent a
   signal within this window is considered non-live. Used for live-signal
   detection, live-work detection, startup-vs-never-started classification,
   and zombie/stale assessment. *)
let agent_staleness_threshold_s = 120.0

let unknown_model_label = "unknown_model"

let active_model_of_meta (m : keeper_meta) : string =
  match m.runtime.last_runtime_attempt with
  | Some record when String.trim record.provider_id <> "" -> record.provider_id
  | _ -> unknown_model_label

let active_model_label_of_meta (m : keeper_meta) : string =
  (* RFC-0132 PR-2: the meta surface is external (status detail); the model
     label is redacted via SSOT ([Boundary_redaction.runtime_model_label]).
     Missing runtime-attempt evidence stays explicit instead of borrowing the
     configured/default runtime. *)
  match m.runtime.last_runtime_attempt with
  | Some record when String.trim record.provider_id <> "" ->
      Boundary_redaction.to_string Boundary_redaction.runtime_model_label
  | _ -> unknown_model_label

let next_model_hint_of_meta (m : keeper_meta) : string option =
  (* NOT-YET-IMPLEMENTED (#22080 follow-up): meta carries no field recording the
     cascade's next-runtime fallback target, so there is nothing to read here.
     The real source is [Keeper_unified_turn_cascade_resolution] /
     [Keeper_error_classify] — the [next_runtime] of a degraded_retry, computed
     during turn rotation but never persisted back into meta. Producing a real
     hint requires extending the meta schema to persist next_runtime per keeper
     (a separate change). Returns [None]; the dashboard already treats null as
     "no hint" (keeper-store-normalize.ts). The emit sites stay wired so the
     hint activates automatically once a source exists.

     Unlike [models_resolved] (removed in this PR as a dead duplicate of the
     live [models] field), [next_model_hint] is retained as forward-wiring:
     same emit -> normalize -> unconsumed shape, but [models_resolved] had a
     live sibling to serve the same data, whereas [next_model_hint] has no
     source yet and lights up once [next_runtime] is persisted. *)
  let _ = m in
  None

let string_of_fiber_health = function
  | Fiber_alive -> "alive"
  | Fiber_zombie -> "zombie"
  | Fiber_dead -> "dead"
  | Fiber_unknown -> "unknown"

let keeper_health_to_string = function
  | KH_healthy -> "healthy"
  | KH_idle -> "idle"
  | KH_offline -> "offline"
  | KH_stale -> "stale"
  | KH_degraded -> "degraded"
  | KH_zombie -> "zombie"
  | KH_dead -> "dead"

(** Issue #8670: strict parser returning [None] on unknown strings so
    drift (producer typo, future variant) is visible to callers instead
    of silently masquerading as [KH_offline]. Mirrors the #8636 lenient
    parser pattern (option-typed reverse route on the parse boundary). *)
let keeper_health_of_string_opt = function
  | "healthy" -> Some KH_healthy
  | "idle" -> Some KH_idle
  | "offline" -> Some KH_offline
  | "stale" -> Some KH_stale
  | "degraded" -> Some KH_degraded
  | "zombie" -> Some KH_zombie
  | "dead" -> Some KH_dead
  | _ -> None

let keeper_health_or_offline ~source s =
  match keeper_health_of_string_opt s with
  | Some h -> h
  | None ->
      Log.Keeper.warn
        "%s: unknown keeper health wire string %S -> KH_offline fallback (#8670)"
        source
        s;
      KH_offline

let keeper_continuity_to_string = function
  | Continuity_healthy -> "healthy"
  | Continuity_recovering -> "recovering"
  | Continuity_not_running -> "not_running"

let parse_agent_status (config : Workspace.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Workspace.agents_dir config) (Workspace.safe_filename agent_name ^ ".json")
  in
  if not (Workspace.path_exists config agent_file) then
    `Assoc [ ("exists", `Bool false) ]
  else (
    match Workspace.read_json_opt config agent_file with
    | None ->
        `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_read") ]
    | Some json -> (
        match Masc_domain.agent_of_yojson json with
        | Error _ ->
            `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_parse") ]
        | Ok (agent : Masc_domain.agent) ->
            let now_ts = Time_compat.now () in
            let session_bound_ts =
              Workspace_resilience.Time.parse_iso8601_opt agent.session_bound_at
              |> Option.value ~default:0.0
            in
            let last_seen_ts =
              Workspace_resilience.Time.parse_iso8601_opt agent.last_seen
              |> Option.value ~default:0.0
            in
            let age_s = if session_bound_ts <= 0.0 then 0.0 else now_ts -. session_bound_ts in
            let last_seen_ago_s =
              if last_seen_ts <= 0.0 then 0.0 else now_ts -. last_seen_ts
            in
            `Assoc
              [
                ("exists", `Bool true);
                ("name", `String agent.name);
                ("agent_type", `String agent.agent_type);
                ("status", `String (Masc_domain.string_of_agent_status agent.status));
                ( "capabilities",
                  `List (List.map (fun s -> `String s) agent.capabilities) );
                ( "current_task", Json_util.string_opt_to_json agent.current_task );
                ("session_bound_at", `String agent.session_bound_at);
                ("last_seen", `String agent.last_seen);
                ("age_s", `Float age_s);
                ("last_seen_ago_s", `Float last_seen_ago_s);
                ("is_zombie",
                 `Bool
                   (Workspace.is_zombie_agent
                      ~agent_type:agent.agent_type
                      ?agent_meta:agent.meta
                      ~agent_name:agent.name
                      agent.last_seen));
              ]))

let json_string_opt key json = Json_util.get_string_nonempty json key

let json_bool key json default =
  Safe_ops.json_bool ~default key json

let json_float_opt key json =
  Safe_ops.json_float_opt key json

(* RFC-0089 (String Classifier to Typed Variant). The agent-status snapshot
   blob's "status" field is produced exclusively by [parse_agent_status], which
   serializes a typed [Masc_domain.agent_status] (active | busy | listening |
   inactive). Parse it back into the closed ADT here so the liveness/surface
   consumers below match the four constructors exhaustively instead of comparing
   string literals — the compiler then rejects any arm naming a value outside
   the domain. The previous string-literal matches carried dead "idle"/"offline"
   arms (keeper_health vocabulary this producer never emits); those vanish under
   the typed match. Unknown / absent / garbage "status" parses to [None],
   preserving the old "unknown"-default semantics (neither live nor inactive). *)
let agent_runtime_status_opt agent_status : Masc_domain.agent_status option =
  match json_string_opt "status" agent_status with
  | Some s -> Masc_domain.agent_status_of_string_opt (String.lowercase_ascii s)
  | None -> None

let agent_last_seen_ts_opt agent_status =
  match json_string_opt "last_seen" agent_status with
  | Some value -> Workspace_resilience.Time.parse_iso8601_opt value
  | None -> None

let agent_last_seen_ago_s agent_status =
  json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float

let agent_runtime_has_live_signal agent_status =
  match agent_runtime_status_opt agent_status with
  | Some (Masc_domain.Active | Masc_domain.Busy | Masc_domain.Listening) ->
      agent_last_seen_ago_s agent_status <= agent_staleness_threshold_s
  | Some Masc_domain.Inactive | None -> false

let agent_runtime_has_live_work agent_status =
  match agent_runtime_status_opt agent_status with
  | Some (Masc_domain.Active | Masc_domain.Busy | Masc_domain.Listening) ->
      agent_last_seen_ago_s agent_status <= agent_staleness_threshold_s
  | Some Masc_domain.Inactive | None -> false

let string_contains_ci = String_util.contains_substring_ci

let quiet_hours_active ~now_ts =
  let current_hour =
    let tm = Unix.gmtime now_ts in
    (* KST = UTC+9; must use gmtime, not localtime *)
    (tm.Unix.tm_hour + 9) mod 24
  in
  let quiet_start = Env_config.Autonomy.quiet_start in
  let quiet_end = Env_config.Autonomy.quiet_end in
  quiet_start < quiet_end
  && current_hour >= quiet_start
  && current_hour < quiet_end

let keeper_reply_snapshot_of_history (history_items : Yojson.Safe.t list) =
  let normalize_content item =
    match json_string_opt "content" item with
    | Some value -> value
    | None -> Option.value ~default:"" (json_string_opt "preview" item)
  in
  let update_last role ts content ((last_user, last_assistant) as acc) =
    let role = String.lowercase_ascii role in
    if role = "user" then
      (Some (ts, content), last_assistant)
    else if role = "assistant" then
      (last_user, Some (ts, content))
    else acc
  in
  let last_user, last_assistant =
    List.fold_left
      (fun acc item ->
        match item with
        | `Assoc _ ->
            let role = Json_util.get_string item "role" in
            let ts_unix =
              match json_float_opt "ts_unix" item with
              | Some ts when ts > 0.0 -> Some ts
              | _ -> json_float_opt "timestamp" item
            in
            let content = normalize_content item in
            (match role, ts_unix with
            | Some role, Some ts -> update_last role ts content acc
            | _ -> acc)
        | _ -> acc)
      (None, None) history_items
  in
  match last_user, last_assistant with
  | None, None -> (`String "never", `Null, `Null)
  | Some (user_ts, _), Some (assistant_ts, preview) when assistant_ts >= user_ts ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, None -> (`String "awaiting_reply", `Null, `Null)
  | None, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)

let error_keywords =
  [ "error"
  ; "failed"
  ; "timeout"
  ; "graphql"
  ; "model"
  ; (* RFC-0132-EXEMPT: classification list, not boundary redaction *)
    "runtime"
  ; "provider"
  ]

let looks_error_like text =
  List.exists (string_contains_ci text) error_keywords

let keeper_error_hint ~agent_status ~meta =
  let agent_error = json_string_opt "error" agent_status in
  let proactive_reason =
    let reason = String.trim meta.runtime.proactive_rt.last_reason in
    if reason = "" then None else Some reason
  in
  let drift_reason = None in
  match agent_error with
  | Some _ as error -> error
  | None -> (
      match proactive_reason with
      | Some reason when looks_error_like reason -> Some reason
      | _ -> (
          match drift_reason with
          | Some reason when looks_error_like reason -> Some reason
          | _ -> None))

(* A live signal newer than the persisted error snapshot means
   [last_proactive_reason] is stale and must not surface as a current error.
   Shared by quiet-reason classification and the dashboard diagnostic so a
   running keeper that has recovered does not keep showing a dead error string
   — including across server restarts, where the persisted snapshot is reloaded
   verbatim and never reset.

   Two independent supersede paths, because the persisted error and the live
   signal can come from different sources:

   - Keeper self-progress: the error is recorded on the last *proactive* cycle
     ([proactive_rt.last_ts]). If the keeper has completed any later turn
     ([usage.last_turn_ts] strictly greater), the proactive error predates the
     keeper's current activity and is stale. Keepers do not publish an external
     agent-registry record ([.masc/agents/]), so this is the only path that
     fires for them. Equality (the erroring proactive turn *is* the latest
     turn) does not supersede — a fresh error stays visible.

   - External agent-registry signal: present for non-keeper participants that
     write an agent record. A fresh live presence newer than all recorded
     activity. Threshold preserved verbatim so non-keeper behaviour is
     unchanged. *)
let live_signal_supersedes_persisted_error ~keepalive_running ~agent_status ~meta =
  if not keepalive_running then false
  else begin
    let proactive_error_ts = meta.runtime.proactive_rt.last_ts in
    let last_turn_ts = meta.runtime.usage.last_turn_ts in
    let self_progressed_past_proactive_error =
      proactive_error_ts > 0.0 && last_turn_ts > proactive_error_ts
    in
    let external_live_signal =
      json_bool "exists" agent_status false
      && agent_runtime_has_live_signal agent_status
      &&
      match agent_last_seen_ts_opt agent_status with
      | Some last_seen_ts -> last_seen_ts > max proactive_error_ts last_turn_ts
      | None -> false
    in
    self_progressed_past_proactive_error || external_live_signal
  end

let classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts =
  let quiet_active = quiet_hours_active ~now_ts in
  let error_hint =
    if live_signal_supersedes_persisted_error ~keepalive_running ~agent_status ~meta
    then None
    else keeper_error_hint ~agent_status ~meta
  in
  if not meta.proactive.enabled then
    Some "disabled"
  else if not keepalive_running then
    Some "not_running"
  else if meta.runtime.usage.total_turns = 0 && meta.runtime.proactive_rt.count_total = 0 then
    let keeper_age_s =
      match Workspace_resilience.Time.parse_iso8601_opt meta.created_at with
      | Some created_ts when created_ts > 0.0 -> max 0.0 (now_ts -. created_ts)
      | _ -> 0.0
    in
    if keeper_age_s <= agent_staleness_threshold_s then Some "startup" else Some "never_started"
  else if quiet_active then
    Some "quiet_hours"
  else
    match error_hint with
    | Some reason when string_contains_ci reason "graphql" ->
        Some "graphql_error"
    | Some reason when looks_error_like reason ->
        Some "model_error"
    | Some _ -> Some "unknown"
    | None ->
        let last_turn_ago_s =
          if meta.runtime.usage.last_turn_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.runtime.usage.last_turn_ts))
        in
        let last_proactive_ago_s =
          if meta.runtime.proactive_rt.last_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.runtime.proactive_rt.last_ts))
        in
        let effective_activity_ago_s =
          match last_turn_ago_s with
          | Some age when agent_runtime_has_live_work agent_status ->
              Some (min age (agent_last_seen_ago_s agent_status))
          | Some _ as age -> age
          | None when agent_runtime_has_live_work agent_status ->
              Some (agent_last_seen_ago_s agent_status)
          | None -> None
        in
        if meta.proactive.enabled then
          match last_proactive_ago_s with
          | Some age when age < float_of_int meta.proactive.cooldown_sec ->
              Some "min_gap"
          | _ -> (
              match effective_activity_ago_s with
              | Some age when age < float_of_int meta.proactive.idle_sec ->
                  Some "no_recent_activity"
              | _ -> None)
        else None

let keeper_health_state ?(fiber_health = Fiber_unknown)
    ?(keepalive_interval_s = 300.0)
    ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts () : keeper_health =
  (* Supervisor-level health takes priority *)
  match fiber_health with
  | Fiber_zombie -> KH_zombie
  | Fiber_dead -> KH_dead
  | Fiber_alive | Fiber_unknown ->
  let agent_exists = json_bool "exists" agent_status false in
  let agent_runtime_status = agent_runtime_status_opt agent_status in
  let last_seen_ago_s =
    json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float
  in
  let is_zombie = json_bool "is_zombie" agent_status false in
  let stale_threshold_s = agent_staleness_threshold_s in
  let last_turn_ago_s =
    if meta.runtime.usage.last_turn_ts <= 0.0 then max_float
    else max 0.0 (now_ts -. meta.runtime.usage.last_turn_ts)
  in
  let effective_activity_ago_s =
    if agent_runtime_has_live_work agent_status then
      min last_turn_ago_s last_seen_ago_s
    else
      last_turn_ago_s
  in
  if
    (not keepalive_running)
    && (not agent_exists || agent_runtime_status = Some Masc_domain.Inactive)
  then KH_offline
  (* H-4 fix: true zombies are stale regardless of keepalive state *)
  else if is_zombie then KH_stale
  else if keepalive_running then
    if agent_exists && last_seen_ago_s > 2.0 *. keepalive_interval_s then KH_stale
    else
      (match quiet_reason with
    | Some "graphql_error" | Some "model_error" -> KH_degraded
    | _ ->
        if meta.runtime.usage.total_turns = 0 && meta.runtime.proactive_rt.count_total = 0 then KH_idle
        else if effective_activity_ago_s > float_of_int (max meta.proactive.idle_sec 900)
        then KH_idle
        else KH_healthy)
  else if last_seen_ago_s > stale_threshold_s then KH_stale
  else KH_offline

let keeper_next_action_path ~(health_state : keeper_health) ~quiet_reason =
  match health_state with
  | KH_zombie -> "auto_restart"
  | KH_dead -> "manual_restart"
  | KH_offline | KH_stale | KH_degraded -> "recover"
  | KH_healthy | KH_idle -> (
      match quiet_reason with
      | Some "quiet_hours" -> "manual_social_poke"
      | Some "not_running" | Some "agent_missing" -> "recover"
      | Some "graphql_error" | Some "model_error" | Some "startup" | Some "unknown" ->
          "probe"
      | Some "disabled" -> "recover"
      | _ -> "direct_message")

let keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts =
  match quiet_reason with
  | Some "min_gap" when meta.runtime.proactive_rt.last_ts > 0.0 ->
      let remaining =
        float_of_int meta.proactive.cooldown_sec -. (now_ts -. meta.runtime.proactive_rt.last_ts)
      in
      if remaining > 0.0 then `Float remaining else `Null
  | _ -> `Null

let keeper_diagnostic_summary ~meta ~(health_state : keeper_health) ~quiet_reason =
  match health_state with
  | KH_zombie ->
      "Keeper fiber has terminated but registry entry persists. Supervisor will auto-restart."
  | KH_dead ->
      "Keeper restart budget exhausted. Manual restart via masc_keeper_up required."
  | KH_offline | KH_stale | KH_degraded ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | KH_healthy | KH_idle -> (
      match quiet_reason with
      | Some "disabled" ->
          "Keeper proactive automation is disabled. Direct messages still work, but scheduled social ticks will stay quiet."
      | Some "not_running" ->
          "Keeper keepalive is enabled, but its loop is not running."
      | Some "agent_missing" ->
          "Keeper keepalive is running, but the live agent record is missing or offline."
      | Some "quiet_hours" ->
          "Quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep."
      | Some "min_gap" ->
          if meta.runtime.proactive_rt.last_outcome = Proactive_silent then
            "Latest autonomous proactive cycle completed silently. The next deterministic cycle will open after cooldown."
          else
            "Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait."
      | Some "never_started" ->
          "Keeper metadata exists but no reply turn has been recorded yet."
      | _ -> "Keeper is reachable. Send a direct message for an immediate response.")

let keeper_continuity_state
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(health_state : keeper_health)
    ~(now_ts : float) : keeper_continuity =
  let _ = meta in
  let healthy_like =
    match health_state with KH_healthy | KH_idle -> true | KH_offline | KH_stale | KH_degraded | KH_zombie | KH_dead -> false
  in
  let recently_started =
    match keepalive_started_at with
    | Some started_at ->
        let recovery_window_s = 60.0 in
        now_ts -. started_at < recovery_window_s
    | None -> false
  in
  if not keepalive_running then Continuity_not_running
  else if recently_started || not healthy_like then Continuity_recovering
  else Continuity_healthy

let keeper_continuity_summary = function
  | Continuity_not_running ->
      "Keeper runtime is not running. The runtime should reconcile it."
  | Continuity_recovering ->
      "Keeper runtime is reconciling back into live presence."
  | Continuity_healthy ->
      "Keeper runtime is aligned with the durable keeper state."

let augment_keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(now_ts : float)
    (diagnostic : Yojson.Safe.t) : Yojson.Safe.t =
  let health_state =
    json_string_opt "health_state" diagnostic
    |> Option.value ~default:"offline"
    |> keeper_health_or_offline ~source:"augment_keeper_diagnostic_json"
  in
  let continuity_state =
    keeper_continuity_state ~meta ~keepalive_running
      ~keepalive_started_at ~health_state ~now_ts
  in
  let continuity_summary = keeper_continuity_summary continuity_state in
  let continuity_str = keeper_continuity_to_string continuity_state in
  let summary =
    match json_string_opt "summary" diagnostic with
    | Some base when continuity_state = Continuity_healthy -> base
    | Some _ | None -> continuity_summary
  in
  match diagnostic with
  | `Assoc fields ->
      let filtered =
        fields
        |> List.filter (fun (key, _) ->
               not
                 (String.equal key "summary"
                 || String.equal key "continuity_state"
                 || String.equal key "continuity_summary"))
      in
      `Assoc
        (("summary", `String summary)
        :: ("continuity_state", `String continuity_str)
        :: ("continuity_summary", `String continuity_summary)
        :: filtered)
  | other -> other

(* RFC-0089 — the keeper "surface status" is the display status that
   [keeper_surface_status] derives from (keeper_health × agent_status). It is
   carried on the wire as a string and re-classified by literal in the operator
   align step, the server row patcher, and the dashboard pressure ranker. Close
   it into a sum so the producer builds it exhaustively and those consumers
   match it via [surface_status_of_string_opt] instead of comparing literals.
   "paused" is NOT part of this domain — it is a control-plane override
   (meta.paused) applied one layer above, at operator_control_snapshot. *)
type surface_status =
  | Surface_active
  | Surface_busy
  | Surface_listening
  | Surface_inactive
  | Surface_offline
  | Surface_idle

let surface_status_to_string = function
  | Surface_active -> "active"
  | Surface_busy -> "busy"
  | Surface_listening -> "listening"
  | Surface_inactive -> "inactive"
  | Surface_offline -> "offline"
  | Surface_idle -> "idle"

let surface_status_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "active" -> Some Surface_active
  | "busy" -> Some Surface_busy
  | "listening" -> Some Surface_listening
  | "inactive" -> Some Surface_inactive
  | "offline" -> Some Surface_offline
  | "idle" -> Some Surface_idle
  | _ -> None

let keeper_surface_status
    ~(agent_status : Yojson.Safe.t)
    ~(diagnostic : Yojson.Safe.t) =
  let health_state =
    json_string_opt "health_state" diagnostic
    |> Option.value ~default:"offline"
    |> keeper_health_or_offline ~source:"keeper_surface_status"
  in
  let agent_runtime_status = agent_runtime_status_opt agent_status in
  let surface =
    match health_state with
    | KH_healthy -> (
        match agent_runtime_status with
        | Some Masc_domain.Active -> Surface_active
        | Some Masc_domain.Busy -> Surface_busy
        | Some Masc_domain.Listening -> Surface_listening
        | Some Masc_domain.Inactive -> Surface_offline
        | None -> Surface_active)
    | KH_idle -> Surface_idle
    | KH_stale | KH_degraded | KH_zombie | KH_dead -> Surface_inactive
    | KH_offline -> Surface_offline
  in
  surface_status_to_string surface

let keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(agent_status : Yojson.Safe.t)
    ~(keepalive_running : bool)
    ~(history_items : Yojson.Safe.t list)
    ~(now_ts : float) : Yojson.Safe.t =
  let quiet_reason =
    classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts
  in
  let health_state =
    keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts ()
  in
  let next_action_path = keeper_next_action_path ~health_state ~quiet_reason in
  let last_reply_status, last_reply_at, last_reply_preview =
    keeper_reply_snapshot_of_history history_items
  in
  let last_error =
    (* Mirror classify_keeper_quiet_reason: a recovered running keeper whose
       live signal postdates the persisted error must not surface the stale
       reason. Without this guard the dashboard "이전 오류" badge survives
       server restarts because the snapshot is reloaded verbatim. *)
    if live_signal_supersedes_persisted_error ~keepalive_running ~agent_status ~meta
    then `Null
    else Json_util.string_opt_to_json (keeper_error_hint ~agent_status ~meta)
  in
  `Assoc
    [
      ("health_state", `String (keeper_health_to_string health_state));
      ( "quiet_reason", Json_util.string_opt_to_json quiet_reason );
      ("next_action_path", `String next_action_path);
      ("recoverable", `Bool (String.equal next_action_path "recover"));
      ("summary", `String (keeper_diagnostic_summary ~meta ~health_state ~quiet_reason));
      ("last_reply_status", last_reply_status);
      ("last_reply_at", last_reply_at);
      ("last_reply_preview", last_reply_preview);
      ("last_error", last_error);
      ("keepalive_running", `Bool keepalive_running);
      ("next_eligible_at_s", keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts);
    ]

(** Derive pipeline stage directly from the 13-state phase (RFC-0002,
    post-Zombie #14707). Deterministic mapping — no 30s recency heuristic. *)
let pipeline_stage_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "offline"
  | Keeper_state_machine.Running -> "idle"
  | Keeper_state_machine.Failing -> "failing"
  | Keeper_state_machine.Overflowed -> "overflowed"
  | Keeper_state_machine.Compacting -> "compacting"
  | Keeper_state_machine.HandingOff -> "handoff"
  | Keeper_state_machine.Draining -> "draining"
  | Keeper_state_machine.Paused -> "paused"
  | Keeper_state_machine.Stopped -> "offline"
  | Keeper_state_machine.Crashed -> "crashed"
  | Keeper_state_machine.Restarting -> "restarting"
  | Keeper_state_machine.Dead | Keeper_state_machine.Zombie -> "offline"

(** Explain the lossy [pipeline_stage] label without changing its wire value.
    Consumers that need exact lifecycle authority should read [lifecycle_phase];
    this field explains why two phases can share a single stage label. *)
let pipeline_stage_detail_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "launch_pending_no_fiber"
  | Keeper_state_machine.Running -> "phase_running_idle"
  | Keeper_state_machine.Failing -> "health_or_turn_failure_probe"
  | Keeper_state_machine.Overflowed -> "context_overflow_pending_compaction"
  | Keeper_state_machine.Compacting -> "context_compaction_in_progress"
  | Keeper_state_machine.HandingOff -> "generation_handoff_in_progress"
  | Keeper_state_machine.Draining -> "graceful_shutdown_draining"
  | Keeper_state_machine.Paused -> "operator_or_policy_paused"
  | Keeper_state_machine.Stopped -> "clean_stop_terminal"
  | Keeper_state_machine.Crashed -> "crashed_restart_candidate"
  | Keeper_state_machine.Restarting -> "supervisor_restart_backoff_elapsed"
  | Keeper_state_machine.Dead -> "restart_budget_exhausted_terminal"
  | Keeper_state_machine.Zombie -> "structural_failure_terminal"
