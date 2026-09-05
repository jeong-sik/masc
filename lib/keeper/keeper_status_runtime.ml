(** Keeper_status_runtime — keeper health/diagnostic state,
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

(* Slack over the slower of the two producer cadences, for the scheduling and
   transport delay between a heartbeat being written and being read. The .mli
   calls it "one minute of scheduling / transport jitter"; it was spelled 60.0
   inside the expression, where nothing said which of the two windows below it
   belonged to. *)
let heartbeat_transport_jitter_s = 60.0

(* A turn record is emitted after a cycle completes, so its freshness window
   carries the cycle's own execution time on top of the configured sleep. Two
   separate numbers: how long a cycle may take, and the floor the window never
   drops below however short the cadence is configured. *)
let turn_cycle_execution_slack_s = 120.0
let turn_record_freshness_floor_s = 300.0

(* A keepalive loop that has only just started has not had time to write the
   evidence the health read looks for, so it reads as recovering rather than
   unhealthy until this window passes. Distinct from the jitter above: that one
   widens a staleness window, this one suppresses a verdict. *)
let keepalive_recovery_window_s = 60.0

let keeper_heartbeat_stale_after_s ~keepalive_interval_s ~snapshot_interval_s =
  Float.max
    agent_staleness_threshold_s
    (Float.max keepalive_interval_s snapshot_interval_s +. heartbeat_transport_jitter_s)
;;

let keeper_turn_record_freshness_slo_s ~keepalive_interval_s =
  Float.max
    turn_record_freshness_floor_s
    (keepalive_interval_s +. turn_cycle_execution_slack_s)
;;

let keeper_turn_record_source_health
      ~skipped_rows
      ~live_turn_in_progress
      ~latest_age_s
      ~freshness_slo_s
  =
  match latest_age_s, live_turn_in_progress with
  | None, _ when skipped_rows > 0 -> "incompatible", "incompatible_rows"
  (* A turn is running, so the age of the newest finished record says nothing
     about whether this store is keeping up — the record for the running turn
     has not been written yet. This used to report "ok", which also means "the
     newest record is inside the SLO", and the dashboard could not tell the two
     apart: it recomputed the age, found it over the SLO, read the response as
     a contract violation and dropped the whole payload (#28720). *)
  | _, true -> "live", ""
  | None, false -> "empty", "no_entries"
  | Some age, false when age > freshness_slo_s ->
    "stale", "freshness_slo_exceeded"
  | Some _, false -> "ok", ""
;;

(* The tool-call sources answer the same question one rung higher up. A
   telemetry coverage gap is a fact about the pipeline that wrote the rows,
   so it outranks how fresh the newest row is: a store can be perfectly
   current about the window it did record and still be missing an hour.

   This existed twice, copied byte for byte into two handlers in
   server_dashboard_http_keeper_api.ml, each carrying its own inner ladder
   that was this module's ladder minus the two cases it does not reach. Three
   copies meant a consumer saw a vocabulary no single place listed. *)
let keeper_tool_call_source_health ~gap_reason ~latest_age_s ~freshness_slo_s =
  match gap_reason with
  | Some reason -> ("coverage_gap", reason)
  | None ->
    (* No skipped rows and no live turn: those two answers belong to the
       turn-record store, which knows about them. A tool-call source that
       has rows and is inside the window is plainly "ok". *)
    keeper_turn_record_source_health ~skipped_rows:0
      ~live_turn_in_progress:false ~latest_age_s ~freshness_slo_s
;;

let keeper_metric_producer_active ~base_path =
  Keeper_registry.all ~base_path ()
  |> List.exists (fun (entry : Keeper_registry.registry_entry) ->
       Option.is_some entry.current_turn_observation
       ||
       match entry.phase with
       | Keeper_state_machine.Failing -> Atomic.get entry.cadence_sleeping
       | Keeper_state_machine.Offline
       | Keeper_state_machine.Running
       | Keeper_state_machine.Draining
       | Keeper_state_machine.Paused
       | Keeper_state_machine.Stopped
       | Keeper_state_machine.Crashed
       | Keeper_state_machine.Restarting -> false)
;;

let unknown_model_label =
  Boundary_redaction.to_string Boundary_redaction.unknown_model_label

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

let json_string_opt key json = Json_util.get_string_nonempty json key

let json_float_opt key json = Safe_ops.json_float_opt key json

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

(* Wire vocabularies shared with the dashboard. Both are closed here so a new
   case cannot reach the wire without the compiler naming every consumer. *)
type keeper_quiet_reason =
  | Proactive_disabled
  | Keepalive_not_running
  | Starting_up
  | Never_started

let keeper_quiet_reason_to_string = function
  | Proactive_disabled -> "disabled"
  | Keepalive_not_running -> "not_running"
  | Starting_up -> "startup"
  | Never_started -> "never_started"

type keeper_next_action_path =
  | Auto_restart
  | Recover
  | Probe
  | Direct_message

(* Strict inverse of {!keeper_next_action_path_to_string}. [None] outside the
   published vocabulary: a reader that cannot spell an action must say so
   rather than resolve it to whichever action happens to be first. *)
let keeper_next_action_path_of_string_opt = function
  | "auto_restart" -> Some Auto_restart
  | "recover" -> Some Recover
  | "probe" -> Some Probe
  | "direct_message" -> Some Direct_message
  | _ -> None

let keeper_next_action_path_to_string = function
  | Auto_restart -> "auto_restart"
  | Recover -> "recover"
  | Probe -> "probe"
  | Direct_message -> "direct_message"

let classify_keeper_quiet_reason ~meta ~keepalive_running ~now_ts =
  if not meta.proactive.enabled then
    Some Proactive_disabled
  else if not keepalive_running then
    Some Keepalive_not_running
  else if meta.runtime.usage.total_turns = 0 && meta.runtime.proactive_rt.count_total = 0 then
    let keeper_age_s =
      match Workspace_resilience.Time.parse_iso8601_opt meta.created_at with
      | Some created_ts when created_ts > 0.0 -> max 0.0 (now_ts -. created_ts)
      | _ -> 0.0
    in
    if keeper_age_s <= agent_staleness_threshold_s then Some Starting_up
    else Some Never_started
  else None

let keeper_health_state ?(fiber_health = Fiber_unknown)
    ?(keepalive_interval_s =
      float_of_int
        (Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec))
    ?(snapshot_interval_s =
      float_of_int (Runtime_params.get Runtime_settings.keeper_snapshot_sec))
    ?last_heartbeat_age_s
    ~meta ~keepalive_running () : keeper_health =
  (* Supervisor-level health takes priority *)
  match fiber_health with
  | Fiber_zombie -> KH_zombie
  | Fiber_dead -> KH_zombie
  | Fiber_alive | Fiber_unknown ->
  if not keepalive_running then KH_offline
  else
    if Option.exists
         (fun heartbeat_age_s ->
           heartbeat_age_s
           > keeper_heartbeat_stale_after_s
               ~keepalive_interval_s
               ~snapshot_interval_s)
         last_heartbeat_age_s
    then KH_stale
    else
      if meta.runtime.usage.total_turns = 0
         && meta.runtime.proactive_rt.count_total = 0
      then KH_idle
      else KH_healthy

let keeper_next_action_path ~(health_state : keeper_health) ~quiet_reason =
  match health_state with
  | KH_zombie -> Auto_restart
  | KH_offline | KH_stale | KH_degraded -> Recover
  | KH_healthy | KH_idle -> (
      match quiet_reason with
      | Some Keepalive_not_running -> Recover
      | Some Proactive_disabled -> Recover
      | Some Starting_up -> Probe
      | Some Never_started | None -> Direct_message)

let keeper_diagnostic_summary ~meta ~(health_state : keeper_health) ~quiet_reason =
  match health_state with
  | KH_zombie ->
      "Keeper fiber has terminated but registry entry persists. Supervisor will auto-restart."
  | KH_offline | KH_stale | KH_degraded ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | KH_healthy | KH_idle -> (
      match quiet_reason with
      | Some Proactive_disabled ->
          "Keeper proactive automation is disabled. Direct messages still work, but scheduled social ticks will stay quiet."
      | Some Keepalive_not_running ->
          "Keeper keepalive is enabled, but its loop is not running."
      | Some Never_started ->
          "Keeper metadata exists but no reply turn has been recorded yet."
      | Some Starting_up | None ->
          "Keeper is reachable. Send a direct message for an immediate response.")

let keeper_continuity_state
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(health_state : keeper_health)
    ~(now_ts : float) : keeper_continuity =
  let healthy_like =
    match health_state with
    | KH_healthy | KH_idle -> true
    | KH_offline | KH_stale | KH_degraded | KH_zombie -> false
  in
  let recently_started =
    match keepalive_started_at with
    | Some started_at -> now_ts -. started_at < keepalive_recovery_window_s
    | None -> false
  in
  if not keepalive_running then Continuity_not_running
  else if recently_started || not healthy_like then Continuity_recovering
  else Continuity_healthy

let keeper_lifecycle_summary = function
  | Continuity_not_running ->
      "Keeper runtime is not running. The runtime should reconcile it."
  | Continuity_recovering ->
      "Keeper runtime is reconciling back into live presence."
  | Continuity_healthy ->
      "Keeper runtime is aligned with the durable keeper state."

let augment_keeper_diagnostic_json
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
    keeper_continuity_state ~keepalive_running
      ~keepalive_started_at ~health_state ~now_ts
  in
  let lifecycle_summary = keeper_lifecycle_summary continuity_state in
  let continuity_str = keeper_continuity_to_string continuity_state in
  let summary =
    match json_string_opt "summary" diagnostic with
    | Some base when continuity_state = Continuity_healthy -> base
    | Some _ | None -> lifecycle_summary
  in
  match diagnostic with
  | `Assoc fields ->
      let filtered =
        fields
        |> List.filter (fun (key, _) ->
               not
                 (String.equal key "summary"
                 || String.equal key "continuity_state"))
      in
      `Assoc
        (("summary", `String summary)
        :: ("continuity_state", `String continuity_str)
        :: filtered)
  | other -> other

(* RFC-0089 — the keeper "surface status" is the display status that
   [keeper_surface_status] derives from keeper health. It is carried on the wire
   as a string and re-classified by the server row patcher and dashboard
   pressure ranker. Close it into a sum so the producer builds it exhaustively
   and consumers match via [surface_status_of_string_opt]. "paused" is not part
   of this domain; it is an operator override applied one layer above. *)
type surface_status =
  | Surface_active
  | Surface_inactive
  | Surface_offline
  | Surface_idle

let surface_status_to_string = function
  | Surface_active -> "active"
  | Surface_inactive -> "inactive"
  | Surface_offline -> "offline"
  | Surface_idle -> "idle"

let surface_status_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "active" -> Some Surface_active
  | "inactive" -> Some Surface_inactive
  | "offline" -> Some Surface_offline
  | "idle" -> Some Surface_idle
  | _ -> None

type control_plane_status =
  | Cp_surface of surface_status
  | Cp_paused

let control_plane_status_to_string = function
  | Cp_surface surface -> surface_status_to_string surface
  | Cp_paused -> "paused"

let control_plane_status_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "paused" -> Some Cp_paused
  | _ -> Option.map (fun surface -> Cp_surface surface) (surface_status_of_string_opt s)

(* Health as the diagnostic reports it. An unreadable diagnostic falls to
   KH_offline with a warning rather than to a healthy-looking word, the same
   way every other reader of this field resolves it. *)
let keeper_diagnostic_health ~(diagnostic : Yojson.Safe.t) ~source =
  json_string_opt "health_state" diagnostic
  |> Option.value ~default:"offline"
  |> keeper_health_or_offline ~source

let keeper_surface_status ~(diagnostic : Yojson.Safe.t) =
  let health_state =
    keeper_diagnostic_health ~diagnostic ~source:"keeper_surface_status"
  in
  let surface =
    match health_state with
    | KH_healthy -> Surface_active
    | KH_idle -> Surface_idle
    | KH_stale | KH_degraded | KH_zombie -> Surface_inactive
    | KH_offline -> Surface_offline
  in
  surface_status_to_string surface

let keeper_diagnostic_json
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(history_items : Yojson.Safe.t list)
    ~(now_ts : float) : Yojson.Safe.t =
  let heartbeat_snapshot, heartbeat_observation_error =
    match
      Keeper_heartbeat_persisted_snapshot.latest
        ~config
        ~keeper_name:meta.name
    with
    | Ok snapshot -> snapshot, None
    | Error error ->
      Log.Keeper.warn
        ~keeper_name:meta.name
        "keeper heartbeat snapshot read failed: %s"
        error;
      None, Some error
  in
  let last_heartbeat_age_s =
    Option.map
      (fun (snapshot : Keeper_heartbeat_persisted_snapshot.t) ->
         Float.max 0.0 (now_ts -. snapshot.timestamp_unix))
      heartbeat_snapshot
  in
  let quiet_reason = classify_keeper_quiet_reason ~meta ~keepalive_running ~now_ts in
  let health_state =
    keeper_health_state
      ?last_heartbeat_age_s
      ~meta
      ~keepalive_running
      ()
  in
  let next_action_path = keeper_next_action_path ~health_state ~quiet_reason in
  let last_reply_status, last_reply_at, last_reply_preview =
    keeper_reply_snapshot_of_history history_items
  in
  (* The deleted workspace-agent projection was the only producer for this
     field. Do not reinterpret the display-oriented proactive reason as an
     error classifier. *)
  let last_error = `Null in
  `Assoc
    [
      ("health_state", `String (keeper_health_to_string health_state));
      ( "quiet_reason",
        Json_util.string_opt_to_json
          (Option.map keeper_quiet_reason_to_string quiet_reason) );
      ("next_action_path",
       `String (keeper_next_action_path_to_string next_action_path));
      ("recoverable", `Bool (next_action_path = Recover));
      ("summary", `String (keeper_diagnostic_summary ~meta ~health_state ~quiet_reason));
      ("last_reply_status", last_reply_status);
      ("last_reply_at", last_reply_at);
      ("last_reply_preview", last_reply_preview);
      ("last_error", last_error);
      ("keepalive_running", `Bool keepalive_running);
      ( "last_heartbeat"
      , match heartbeat_snapshot with
        | Some snapshot -> `String snapshot.timestamp
        | None -> `Null );
      ( "last_heartbeat_age_s"
      , Json_util.float_opt_to_json last_heartbeat_age_s );
      ( "heartbeat_observation_error"
      , Json_util.string_opt_to_json heartbeat_observation_error );
    ]

(** Derive pipeline stage directly from the Keeper lifecycle phase. *)
let pipeline_stage_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "offline"
  | Keeper_state_machine.Running -> "idle"
  | Keeper_state_machine.Failing -> "failing"
  | Keeper_state_machine.Draining -> "draining"
  | Keeper_state_machine.Paused -> "paused"
  | Keeper_state_machine.Stopped -> "offline"
  | Keeper_state_machine.Crashed -> "crashed"
  | Keeper_state_machine.Restarting -> "restarting"

(** Explain the lossy [pipeline_stage] label without changing its wire value.
    Consumers that need exact lifecycle authority should read [lifecycle_phase];
    this field explains why two phases can share a single stage label. *)
let pipeline_stage_detail_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "launch_pending_no_fiber"
  | Keeper_state_machine.Running -> "phase_running_idle"
  | Keeper_state_machine.Failing -> "health_or_turn_failure_probe"
  | Keeper_state_machine.Draining -> "graceful_shutdown_draining"
  | Keeper_state_machine.Paused -> "operator_paused"
  | Keeper_state_machine.Stopped -> "clean_stop_terminal"
  | Keeper_state_machine.Crashed -> "crashed_restart_candidate"
  | Keeper_state_machine.Restarting -> "supervisor_restart_requested"
