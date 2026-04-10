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

  let apply_event ~current event =
    match current, event with
    | Idle, Turn_start -> Prompting
    | Prompting, Prompt_ready -> Awaiting
    | Awaiting, Response_received -> Parsing
    | Parsing, Parse_complete -> Dispatching
    | Dispatching, Tools_dispatched -> Collecting
    | Collecting, Results_collected -> Finalizing
    | Finalizing, Turn_complete -> Idle
    | _, Turn_error _ -> Idle
    | _, Turn_complete -> Idle
    | phase, _ -> phase  (* ignore invalid transitions *)
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

  let apply_event ~current event =
    match current, event with
    | Unchecked, Validate_start -> Det_correcting
    | Unchecked, Skip_validation -> Valid
    | Det_correcting, Det_fixed -> Det_valid
    | Det_correcting, Det_failed -> Det_invalid
    | Det_valid, _ -> Valid  (* det correction succeeded *)
    | Det_invalid, Nondet_attempt _ -> Nondet_retrying
    | Nondet_retrying, Nondet_fixed -> Valid
    | Nondet_retrying, Nondet_exhausted -> Rejected
    | Nondet_retrying, Nondet_attempt _ -> Nondet_retrying  (* retry loop *)
    | _, Validate_start -> Det_correcting  (* reset *)
    | phase, _ -> phase  (* ignore invalid transitions *)
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
   | Keeper.Stopped | Keeper.Dead ->
     if state.turn <> Agent_turn.Idle then
       add (Printf.sprintf "keeper=%s but turn=%s (expected Idle)"
              (Keeper.phase_to_string state.keeper)
              (Agent_turn.phase_to_string state.turn))
   | _ -> ());

  (* Keeper draining -> turn must be idle or finalizing *)
  (match state.keeper with
   | Keeper.Draining ->
     (match state.turn with
      | Agent_turn.Idle | Agent_turn.Finalizing -> ()
      | other ->
        add (Printf.sprintf "keeper=Draining but turn=%s (expected Idle|Finalizing)"
               (Agent_turn.phase_to_string other)))
   | _ -> ());

  (* NonDet retrying -> turn must be dispatching *)
  (match state.validation with
   | Tool_validation.Nondet_retrying ->
     if state.turn <> Agent_turn.Dispatching then
       add (Printf.sprintf "validation=Nondet_retrying but turn=%s (expected Dispatching)"
              (Agent_turn.phase_to_string state.turn))
   | _ -> ());

  (* Keeper compacting -> turn must not be prompting/awaiting *)
  (match state.keeper with
   | Keeper.Compacting ->
     (match state.turn with
      | Agent_turn.Prompting | Agent_turn.Awaiting ->
        add (Printf.sprintf "keeper=Compacting but turn=%s (no new LLM calls during compaction)"
               (Agent_turn.phase_to_string state.turn))
      | _ -> ())
   | _ -> ());

  match List.rev !violations with
  | [] -> Ok ()
  | vs -> Error (String.concat "; " vs)

(* ── Unified Event Dispatch ─────────────────────────────── *)

type event =
  | K of Keeper.event
  | T of Agent_turn.event
  | V of Tool_validation.event

let event_to_string = function
  | K e -> "keeper:" ^ Keeper.event_to_string e
  | T e -> "turn:" ^ Agent_turn.event_to_string e
  | V e -> "validation:" ^ Tool_validation.event_to_string e

let apply_turn_event state event =
  let new_turn = Agent_turn.apply_event ~current:state.turn event in
  let new_state = { state with turn = new_turn } in
  match check_invariants new_state with
  | Ok () -> Ok new_state
  | Error reason -> Error reason

let apply_validation_event state event =
  let new_validation = Tool_validation.apply_event ~current:state.validation event in
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
