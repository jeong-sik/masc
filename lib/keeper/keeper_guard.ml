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
  | Guardrail_stop _ -> 0
  | Heartbeat_failed _ -> 1
  | Turn_failed _ -> 2
  | Compaction_started -> 3
  | Handoff_started -> 4
  | Context_measured _ -> 5
  | Heartbeat_ok -> 10
  | Turn_succeeded -> 10
  | _ -> 10

let evaluate (s : measurement_snapshot) : event list =
  let t = s.thresholds in
  let events = ref [] in
  let add ev = events := ev :: !events in

  (* 1. Guardrail: 4-way AND gate.
     Fail-closed when similarity is not measurable (e.g. status_tick without
     a user/assistant pair) — the goal_alignment / response_alignment floats
     are 0.0 sentinels in that case, which would otherwise satisfy the two
     [<=] comparisons trivially. See #10012. *)
  let guardrail_fired =
    s.similarity.similarity_measurable
    && s.similarity.repetition_risk >= t.guardrail_repetition_threshold
    && s.similarity.goal_alignment <= t.guardrail_goal_alignment_threshold
    && s.similarity.response_alignment <= t.guardrail_response_alignment_threshold
    && s.context.context_ratio >= t.guardrail_context_threshold
  in
  if guardrail_fired then
    add (Guardrail_stop {
      reason = Printf.sprintf
        "rep=%.2f goal=%.2f resp=%.2f ratio=%.3f"
        s.similarity.repetition_risk
        s.similarity.goal_alignment
        s.similarity.response_alignment
        s.context.context_ratio;
    });

  (* 2. Crash: heartbeat failure threshold *)
  if s.failures.consecutive_hb_failures >= t.max_consecutive_hb_failures then
    add (Heartbeat_failed {
      consecutive = s.failures.consecutive_hb_failures;
      max_allowed = t.max_consecutive_hb_failures;
    });

  (* 3. Crash: turn failure threshold *)
  if s.failures.consecutive_turn_failures >= t.max_consecutive_turn_failures then
    add (Turn_failed {
      consecutive = s.failures.consecutive_turn_failures;
      max_allowed = t.max_consecutive_turn_failures;
    });

  (* 4. Compaction: any of 3 gates.
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
  if (compact_ratio || compact_msg || compact_tok) && cooldown_ok then
    add Compaction_started;

  (* 5. Handoff: context ratio above threshold *)
  let handoff_threshold = t.handoff_threshold *. t.model_handoff_multiplier in
  let handoff_cooldown_ok =
    s.timing.since_last_handoff_sec >= float_of_int t.handoff_cooldown_sec
  in
  if t.auto_handoff_enabled
     && s.context.context_ratio >= handoff_threshold
     && handoff_cooldown_ok then
    add Handoff_started;

  (* 6. Heartbeat health: if below threshold, report ok *)
  if s.failures.consecutive_hb_failures > 0
     && s.failures.consecutive_hb_failures < t.max_consecutive_hb_failures then
    add (Heartbeat_failed {
      consecutive = s.failures.consecutive_hb_failures;
      max_allowed = t.max_consecutive_hb_failures;
    });

  (* 7. Context measurement (always emitted for audit trail) *)
  add (Context_measured {
    context_ratio = s.context.context_ratio;
    message_count = s.context.message_count;
    token_count = s.context.token_count;
    auto_rules = {
      reflect = s.similarity.repetition_risk >= t.reflect_repetition_threshold;
      plan =
        s.similarity.similarity_measurable
        && s.similarity.goal_alignment <= t.plan_goal_alignment_threshold
        && s.similarity.response_alignment <= t.plan_response_alignment_threshold;
      compact = (compact_ratio || compact_msg || compact_tok) && cooldown_ok;
      handoff =
        t.auto_handoff_enabled
        && s.context.context_ratio >= handoff_threshold;
      guardrail_stop = guardrail_fired;
      guardrail_reason =
        if guardrail_fired then
          Some (Printf.sprintf "rep=%.2f goal=%.2f resp=%.2f ratio=%.3f"
            s.similarity.repetition_risk
            s.similarity.goal_alignment
            s.similarity.response_alignment
            s.context.context_ratio)
        else None;
      goal_drift =
        1.0 -. s.similarity.goal_alignment;
    };
  });

  (* Sort by priority (highest first) and return *)
  List.sort (fun a b -> compare (event_priority a) (event_priority b))
    (List.rev !events)

let rec prioritized_event = function
  | [] -> Heartbeat_ok
  | Context_measured _ :: rest -> prioritized_event rest
  | first :: _ -> first
