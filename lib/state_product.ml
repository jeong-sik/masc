(** Orthogonal state machine composition.

    @since 2.260.0 *)

module Keeper = Keeper_state_machine

(* ── Dimension 2: Agent Turn ────────────────────────────── *)

module Agent_turn = struct
  type phase =
    | Idle | Prompting | Awaiting | Parsing
    | Dispatching | Collecting | Finalizing

  let phase_to_string = function
    | Idle -> "idle" | Prompting -> "prompting" | Awaiting -> "awaiting"
    | Parsing -> "parsing" | Dispatching -> "dispatching"
    | Collecting -> "collecting" | Finalizing -> "finalizing"

  let all_phases = [Idle; Prompting; Awaiting; Parsing; Dispatching; Collecting; Finalizing]

  type event =
    | Turn_start | Prompt_ready | Response_received | Parse_complete
    | Tools_dispatched | Results_collected | Turn_complete
    | Turn_error of string

  let event_to_string = function
    | Turn_start -> "turn_start" | Prompt_ready -> "prompt_ready"
    | Response_received -> "response_received" | Parse_complete -> "parse_complete"
    | Tools_dispatched -> "tools_dispatched" | Results_collected -> "results_collected"
    | Turn_complete -> "turn_complete" | Turn_error s -> "turn_error:" ^ s

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  let apply_event ~current event =
    match current, event with
    | Idle, Turn_start -> Applied Prompting
    | Prompting, Prompt_ready -> Applied Awaiting
    | Awaiting, Response_received -> Applied Parsing
    | Parsing, Parse_complete -> Applied Dispatching
    | Dispatching, Tools_dispatched -> Applied Collecting
    | Collecting, Results_collected -> Applied Finalizing
    | Finalizing, Turn_complete -> Applied Idle
    | _, Turn_error _ -> Applied Idle
    | _, Turn_complete -> Applied Idle
    | phase, event -> Ignored { phase; event }

  let apply_event_lossy ~current event =
    match apply_event ~current event with
    | Applied p | Ignored { phase = p; _ } -> p
end

(* ── Dimension 3: Tool Validation ───────────────────────── *)

module Tool_validation = struct
  type phase =
    | Unchecked | Det_correcting | Det_valid | Det_invalid
    | Nondet_retrying | Valid | Rejected

  let phase_to_string = function
    | Unchecked -> "unchecked" | Det_correcting -> "det_correcting"
    | Det_valid -> "det_valid" | Det_invalid -> "det_invalid"
    | Nondet_retrying -> "nondet_retrying" | Valid -> "valid"
    | Rejected -> "rejected"

  let all_phases = [Unchecked; Det_correcting; Det_valid; Det_invalid;
                    Nondet_retrying; Valid; Rejected]

  type event =
    | Validate_start | Det_fixed | Det_failed
    | Nondet_attempt of int | Nondet_fixed | Nondet_exhausted
    | Skip_validation

  let event_to_string = function
    | Validate_start -> "validate_start" | Det_fixed -> "det_fixed"
    | Det_failed -> "det_failed" | Nondet_attempt n -> Printf.sprintf "nondet_attempt(%d)" n
    | Nondet_fixed -> "nondet_fixed" | Nondet_exhausted -> "nondet_exhausted"
    | Skip_validation -> "skip_validation"

  type transition = Applied of phase | Ignored of { phase: phase; event: event }

  let default_max_nondet_retries = 3

  let apply_event ?(max_nondet_retries = default_max_nondet_retries) ~current event =
    match current, event with
    | Unchecked, Validate_start -> Applied Det_correcting
    | Unchecked, Skip_validation -> Applied Valid
    | Det_correcting, Det_fixed -> Applied Det_valid
    | Det_correcting, Det_failed -> Applied Det_invalid
    | Det_valid, Skip_validation -> Applied Valid
    | Det_invalid, Nondet_attempt _ -> Applied Nondet_retrying
    | Nondet_retrying, Nondet_fixed -> Applied Valid
    | Nondet_retrying, Nondet_exhausted -> Applied Rejected
    | Nondet_retrying, Nondet_attempt n ->
      if n < max_nondet_retries then Applied Nondet_retrying
      else Applied Rejected
    | phase, event -> Ignored { phase; event }

  let apply_event_lossy ?max_nondet_retries ~current event =
    match apply_event ?max_nondet_retries ~current event with
    | Applied p | Ignored { phase = p; _ } -> p
end

(* ── Product State ──────────────────────────────────────── *)

type product = {
  keeper : Keeper.phase;
  turn : Agent_turn.phase;
  validation : Tool_validation.phase;
}

let initial = {
  keeper = Keeper.Offline;
  turn = Agent_turn.Idle;
  validation = Tool_validation.Unchecked;
}

(* ── Cross-Dimension Invariants ─────────────────────────── *)

let check_invariants (state : product) : (unit, string) result =
  let violations = ref [] in
  let add v = violations := v :: !violations in

  (* Keeper terminal -> turn must be idle *)
  (match state.keeper with
   | Keeper.Stopped | Keeper.Dead | Keeper.Zombie ->
     if state.turn <> Agent_turn.Idle then
       add (Printf.sprintf "keeper=%s but turn=%s (expected Idle)"
              (Keeper.phase_to_string state.keeper)
              (Agent_turn.phase_to_string state.turn))
   | Keeper.Offline | Keeper.Running | Keeper.Failing | Keeper.Overflowed
   | Keeper.Compacting | Keeper.HandingOff | Keeper.Draining | Keeper.Paused
   | Keeper.Crashed | Keeper.Restarting -> ());

  (* Keeper draining -> turn must not be Prompting (no new LLM calls).
     In-progress turns (Awaiting, Parsing, etc.) are allowed because
     drain waits for the current turn to complete. TLA+ verified. *)
  (match state.keeper with
   | Keeper.Draining ->
     if state.turn = Agent_turn.Prompting then
       add "keeper=Draining but turn=Prompting (no new LLM calls during drain)"
   | Keeper.Offline | Keeper.Running | Keeper.Failing | Keeper.Overflowed
   | Keeper.Compacting | Keeper.HandingOff | Keeper.Paused | Keeper.Stopped
   | Keeper.Crashed | Keeper.Restarting | Keeper.Dead | Keeper.Zombie -> ());

  (* NonDet retrying -> turn must be dispatching *)
  (match state.validation with
   | Tool_validation.Nondet_retrying ->
     if state.turn <> Agent_turn.Dispatching then
       add (Printf.sprintf "validation=Nondet_retrying but turn=%s (expected Dispatching)"
              (Agent_turn.phase_to_string state.turn))
   | Tool_validation.Unchecked | Tool_validation.Det_correcting
   | Tool_validation.Det_valid | Tool_validation.Det_invalid
   | Tool_validation.Valid | Tool_validation.Rejected -> ());

  (* Keeper compacting -> turn must not be prompting/awaiting *)
  (match state.keeper with
   | Keeper.Compacting ->
     (match state.turn with
      | Agent_turn.Prompting | Agent_turn.Awaiting ->
        add (Printf.sprintf "keeper=Compacting but turn=%s (no new LLM calls during compaction)"
               (Agent_turn.phase_to_string state.turn))
      | Agent_turn.Idle | Agent_turn.Parsing | Agent_turn.Dispatching
      | Agent_turn.Collecting | Agent_turn.Finalizing -> ())
   | Keeper.Offline | Keeper.Running | Keeper.Failing | Keeper.Overflowed
   | Keeper.HandingOff | Keeper.Draining | Keeper.Paused | Keeper.Stopped
   | Keeper.Crashed | Keeper.Restarting | Keeper.Dead | Keeper.Zombie -> ());

  match List.rev !violations with
  | [] -> Ok ()
  | vs -> Error (String.concat "; " vs)

(* ── Per-Dimension Event Application ────────────────────── *)

let apply_turn_event state event =
  let new_turn = Agent_turn.apply_event_lossy ~current:state.turn event in
  (* TLA+ bug fix: TurnError and TurnFinalize must reset validation to
     Unchecked, otherwise orphaned NondetRetrying violates invariant.
     TurnStart also resets validation for the new turn. *)
  let new_validation = match event with
    | Agent_turn.Turn_error _ | Agent_turn.Turn_complete | Agent_turn.Turn_start ->
      Tool_validation.Unchecked
    | _ -> state.validation
  in
  let new_state = { state with turn = new_turn; validation = new_validation } in
  match check_invariants new_state with
  | Ok () -> Ok new_state
  | Error reason -> Error reason

let apply_validation_event ?max_nondet_retries state event =
  (* Guard: validation events only accepted during Dispatching (TLA+ spec). *)
  if state.turn <> Agent_turn.Dispatching then
    Error (Printf.sprintf "validation event %s rejected: turn=%s (expected Dispatching)"
             (Tool_validation.event_to_string event)
             (Agent_turn.phase_to_string state.turn))
  else
    let new_validation =
      Tool_validation.apply_event_lossy ?max_nondet_retries ~current:state.validation event
    in
    let new_state = { state with validation = new_validation } in
    match check_invariants new_state with
    | Ok () -> Ok new_state
    | Error reason -> Error reason

(* ── Serialization ──────────────────────────────────────── *)

let product_to_json state =
  `Assoc [
    ("keeper", `String (Keeper.phase_to_string state.keeper));
    ("turn", `String (Agent_turn.phase_to_string state.turn));
    ("validation", `String (Tool_validation.phase_to_string state.validation));
  ]
