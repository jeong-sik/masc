(** Current Keeper lifecycle contract tests.

    The lifecycle is typed: context capacity produces only compaction/handoff
    actions, while the state machine owns phase transitions. Model-authored
    prose and similarity heuristics are intentionally absent from this surface. *)

open Alcotest

module SM = Keeper_state_machine
module Measurement = Keeper_measurement
module Guard = Masc.Keeper_guard

let thresholds =
  { Measurement.compaction_ratio_gate = 0.50
  ; compaction_message_gate = 100
  ; compaction_token_gate = 50_000
  ; compaction_cooldown_sec = 60
  ; handoff_threshold = 0.85
  ; handoff_cooldown_sec = 300
  ; auto_handoff_enabled = true
  ; max_consecutive_hb_failures = 5
  ; max_consecutive_turn_failures = 3
  ; model_ratio_multiplier = 1.0
  ; model_handoff_multiplier = 1.0
  }

let snapshot
    ?(context_ratio = 0.30)
    ?(message_count = 20)
    ?(token_count = 15_000)
    ?(since_last_compaction_sec = 600.0)
    ?(since_last_handoff_sec = 600.0)
    ?(hb_failures = 0)
    ?(turn_failures = 0)
    () =
  Measurement.capture
    ~snapshot_id:"test"
    ~keeper_name:"alpha"
    ~generation:1
    ~timestamp:1_000.0
    ~thresholds
    ~context_ratio
    ~message_count
    ~token_count
    ~max_tokens:100_000
    ~now_ts:1_000.0
    ~idle_seconds:0
    ~since_last_compaction_sec
    ~since_last_handoff_sec
    ~proactive_warmup_elapsed:true
    ~consecutive_hb_failures:hb_failures
    ~consecutive_turn_failures:turn_failures
    ()

let has_event predicate events = List.exists predicate events

let test_healthy_snapshot () =
  let events = Guard.evaluate (snapshot ()) in
  check bool "no compaction" false
    (has_event (function SM.Compaction_started -> true | _ -> false) events);
  check bool "no handoff" false
    (has_event (function SM.Handoff_started -> true | _ -> false) events);
  check bool "context evidence is emitted" true
    (has_event (function SM.Context_measured _ -> true | _ -> false) events)

let test_context_actions_are_typed () =
  let events = Guard.evaluate (snapshot ~context_ratio:0.90 ()) in
  match List.find_opt (function SM.Context_measured _ -> true | _ -> false) events with
  | Some (SM.Context_measured { context_actions; _ }) ->
      check bool "compact action" true context_actions.compact;
      check bool "handoff action" true context_actions.handoff
  | Some _ | None -> fail "missing Context_measured event"

let test_context_capacity_events () =
  let events = Guard.evaluate (snapshot ~context_ratio:0.55 ()) in
  check bool "compaction event" true
    (has_event (function SM.Compaction_started -> true | _ -> false) events);
  check bool "cooldown suppresses compaction" false
    (has_event
       (function SM.Compaction_started -> true | _ -> false)
       (Guard.evaluate (snapshot ~context_ratio:0.55
          ~since_last_compaction_sec:30.0 ())))

let test_failure_events_are_explicit () =
  let events = Guard.evaluate (snapshot ~hb_failures:5 ~turn_failures:3 ()) in
  check bool "heartbeat failure" true
    (has_event (function SM.Heartbeat_failed _ -> true | _ -> false) events);
  check bool "turn failure" true
    (has_event (function SM.Turn_failed _ -> true | _ -> false) events)

let test_phase_lifecycle () =
  let initial = { SM.default_conditions with fiber_alive = true
                                      ; heartbeat_healthy = true
                                      ; turn_healthy = true }
  in
  check string "running phase" "running"
    (SM.phase_to_string (SM.derive_phase initial));
  match
    SM.apply_event
      ~current_phase:SM.Running
      ~conditions:initial
      ~event:SM.Compaction_started
      ~now:1.0
  with
  | Error error -> fail (SM.transition_error_to_string error)
  | Ok transition ->
      check string "compacting phase" "compacting"
        (SM.phase_to_string transition.new_phase);
      check bool "compaction active" true
        transition.updated_conditions.compaction_active

let test_json_uses_context_actions () =
  match
    Keeper_state_machine_json.event_to_json
      (SM.Context_measured
         { context_ratio = 0.5
         ; message_count = 2
         ; token_count = 10
         ; context_actions = { compact = true; handoff = false } })
  with
  | `Assoc fields ->
      check bool "context_actions wire key" true
        (List.mem_assoc "context_actions" fields);
      check bool "retired auto_rules key absent" false
        (List.mem_assoc "auto_rules" fields)
  | _ -> fail "expected JSON object"

let () =
  run "keeper_state_machine"
    [ ( "guard"
      , [ test_case "healthy snapshot" `Quick test_healthy_snapshot
        ; test_case "typed context actions" `Quick test_context_actions_are_typed
        ; test_case "capacity events" `Quick test_context_capacity_events
        ; test_case "failure events" `Quick test_failure_events_are_explicit
        ] )
    ; ( "lifecycle"
      , [ test_case "phase transition" `Quick test_phase_lifecycle
        ; test_case "context action JSON" `Quick test_json_uses_context_actions
        ] )
    ]
