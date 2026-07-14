(* Keeper state-machine JSON wire encoders.

   Used by the keeper composite observer + transition audit + dashboard
   surface to ship FSM events / conditions / transitions to UI / logs.

   Extracted from [Keeper_state_machine] (godfile decomp). Pure mapping
   over typed FSM values. No reverse alias in parent - wrapped-library
   cycle blocked the alias (see PR #16880 keeper_state_machine_mermaid
   for the same pattern + rationale). External callers reference this
   module directly. *)

open Keeper_state_machine

let phase_to_json p = `String (phase_to_string p)

let conditions_to_json (c : conditions) =
  `Assoc
    [ "launch_pending", `Bool c.launch_pending
    ; "fiber_alive", `Bool c.fiber_alive
    ; "heartbeat_healthy", `Bool c.heartbeat_healthy
    ; "turn_healthy", `Bool c.turn_healthy
    ; "context_within_budget", `Bool c.context_within_budget
    ; "context_handoff_needed", `Bool c.context_handoff_needed
    ; "compaction_active", `Bool c.compaction_active
    ; "handoff_active", `Bool c.handoff_active
    ; "operator_paused", `Bool c.operator_paused
    ; "stop_requested", `Bool c.stop_requested
    ; "dead_tombstone_latched", `Bool c.dead_tombstone_latched
    ; "restart_requested", `Bool c.restart_requested
    ; "drain_complete", `Bool c.drain_complete
    ; "context_overflow", `Bool c.context_overflow
    ; "credential_archived", `Bool c.credential_archived
    ]
;;

let event_to_json (ev : event) : Yojson.Safe.t =
  let obj typ fields = `Assoc (("type", `String typ) :: fields) in
  match ev with
  | Heartbeat_ok -> obj "heartbeat_ok" []
  | Heartbeat_failed r ->
    obj "heartbeat_failed" [ "consecutive", `Int r.consecutive ]
  | Turn_succeeded -> obj "turn_succeeded" []
  | Turn_failed r ->
    obj "turn_failed" [ "consecutive", `Int r.consecutive ]
  | Context_measured r ->
    obj
      "context_measured"
      [ "context_ratio", `Float r.context_ratio
      ; "message_count", `Int r.message_count
      ; "token_count", `Int r.token_count
      ; ( "context_actions"
        , `Assoc
            [ "compact", `Bool r.context_actions.compact
            ; "handoff", `Bool r.context_actions.handoff
            ] )
      ]
  | Compaction_started -> obj "compaction_started" []
  | Compaction_completed r ->
    obj
      "compaction_completed"
      [ "before_checkpoint_bytes", `Int r.before_checkpoint_bytes
      ; "after_checkpoint_bytes", `Int r.after_checkpoint_bytes
      ]
  | Compaction_failed r -> obj "compaction_failed" [ "reason", `String r.reason ]
  | Handoff_started -> obj "handoff_started" []
  | Handoff_completed r ->
    obj
      "handoff_completed"
      [ "new_trace_id", `String r.new_trace_id; "generation", `Int r.generation ]
  | Handoff_failed r -> obj "handoff_failed" [ "reason", `String r.reason ]
  | Operator_pause -> obj "operator_pause" []
  | Operator_resume -> obj "operator_resume" []
  | Operator_stop r -> obj "operator_stop" [ "remove_meta", `Bool r.remove_meta ]
  | Stop_requested -> obj "stop_requested" []
  | Drain_complete -> obj "drain_complete" []
  | Fiber_started -> obj "fiber_started" []
  | Fiber_terminated r ->
    let base = [ "outcome", `String r.outcome ] in
    let with_prov =
      match r.provider_id with
      | None -> base
      | Some p -> base @ [ "provider_id", `String p ]
    in
    let with_http =
      match r.http_status with
      | None -> with_prov
      | Some s -> with_prov @ [ "http_status", `Int s ]
    in
    obj "fiber_terminated" with_http
  | Supervisor_restart_attempt r ->
    obj "supervisor_restart_attempt" [ "attempt", `Int r.attempt ]
  | Credential_archived -> obj "credential_archived" []
  | Context_overflow_detected r ->
    let limit_tokens =
      match r.limit_tokens with
      | Some n -> `Int n
      | None -> `Null
    in
    obj
      "context_overflow_detected"
      [ "limit_tokens", limit_tokens ]
  | Auto_compact_triggered -> obj "auto_compact_triggered" []
  | Operator_compact_requested -> obj "operator_compact_requested" []
  | Operator_clear_requested r ->
    obj
      "operator_clear_requested"
      [ "preserve_system", `Bool r.preserve_system; "reason", `String r.reason ]
;;

let transition_result_to_json (tr : transition_result) =
  `Assoc
    [ "prev_phase", phase_to_json tr.prev_phase
    ; "new_phase", phase_to_json tr.new_phase
    ; "conditions", conditions_to_json tr.updated_conditions
    ; "event", event_to_json tr.event_applied
    ; "timestamp", `Float tr.timestamp
    ]
;;
