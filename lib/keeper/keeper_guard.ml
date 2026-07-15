(** Keeper Guard — Pure guard evaluation (RFC-0002).
    See .mli for documentation.

    This module replaces the inline threshold checks currently scattered
    across keeper_memory_recall.ml, keeper_keepalive.ml, and
    keeper_supervisor.ml. All decisions are made against a frozen
    [measurement_snapshot] — no Runtime_params re-reads, no clock queries. *)

open Keeper_measurement
open Keeper_state_machine

(** Priority levels for event ordering (lower = higher priority). *)
let event_priority = function
  | Heartbeat_failed _ -> 1
  | Turn_failed _ -> 2
  | Compaction_started -> 3
  | Handoff_started -> 4
  | Context_measured _ -> 5
  | Heartbeat_ok -> 10
  | Turn_succeeded -> 10
  | Compaction_completed -> 10
  | Compaction_failed _ -> 10
  | Handoff_completed _ -> 10
  | Handoff_failed _ -> 10
  | Operator_pause -> 10
  | Operator_resume -> 10
  | Operator_stop _ -> 10
  | Stop_requested -> 10
  | Drain_complete -> 10
  | Fiber_started -> 10
  | Fiber_terminated _ -> 10
  | Supervisor_restart_attempt _ -> 10
  | Credential_archived -> 10
  | Auto_compact_triggered -> 10
  | Operator_compact_requested -> 10
  | Operator_clear_requested _ -> 10
  | Context_overflow_detected _ -> 10

let context_actions (s : measurement_snapshot) : context_actions =
  let t = s.thresholds in
  (* Compaction: any of 3 explicit context-capacity gates.
     NOTE(boundary): compact_tok uses raw token_count — ideally MASC would
     use only ratio-based checks (compact_ratio). The token_gate remains
     because it is a user-configurable compaction parameter persisted in
     keeper meta, exposed via dashboard config panel, and referenced in 30+
     sites. Removing it requires a cross-cutting migration. Until then,
     token_gate=0 (the default for most profiles) disables this gate. *)
  let compact_ratio = s.context.context_ratio >= t.compaction_ratio_gate in
  let compact_msg =
    t.compaction_message_gate > 0
    && s.context.message_count >= t.compaction_message_gate
  in
  let compact_tok =
    t.compaction_token_gate > 0
    && s.context.token_count >= t.compaction_token_gate
  in
  let cooldown_ok =
    s.timing.since_last_compaction_sec >= float_of_int t.compaction_cooldown_sec
  in
  (* Handoff: context ratio above threshold *)
  let handoff_threshold = t.handoff_threshold *. t.model_handoff_multiplier in
  { compact = (compact_ratio || compact_msg || compact_tok) && cooldown_ok
  ; handoff =
      t.auto_handoff_enabled
      && s.context.context_ratio >= handoff_threshold
  }

let evaluate (s : measurement_snapshot) : event list =
  let t = s.thresholds in
  let actions = context_actions s in
  let events = ref [] in
  let add ev = events := ev :: !events in

  if s.failures.consecutive_hb_failures > 0 then
    add (Heartbeat_failed { consecutive = s.failures.consecutive_hb_failures });

  if s.failures.consecutive_turn_failures > 0 then
    add (Turn_failed { consecutive = s.failures.consecutive_turn_failures });

  if actions.compact then add Compaction_started;

  let handoff_cooldown_ok =
    s.timing.since_last_handoff_sec >= float_of_int t.handoff_cooldown_sec
  in
  if actions.handoff && handoff_cooldown_ok then add Handoff_started;

  (* 7. Context measurement (always emitted for audit trail) *)
  add (Context_measured {
    context_ratio = s.context.context_ratio;
    message_count = s.context.message_count;
    token_count = s.context.token_count;
    context_actions = actions;
  });

  (* Sort by priority (highest first) and return *)
  List.sort (fun a b -> compare (event_priority a) (event_priority b))
    (List.rev !events)

let rec prioritized_event = function
  | [] -> Heartbeat_ok
  | Context_measured _ :: rest -> prioritized_event rest
  | first :: _ -> first
