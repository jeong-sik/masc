(** Keeper_trace_validate — validate JSONL traces against TLA+ safety invariants.

    Reads .tla-trace.jsonl files emitted by {!Keeper_trace_emit} and checks
    all 10 safety invariants from {!Keeper_invariant_check} at each step. *)

type step = {
  seq : int;
  phase : Keeper_state_machine.phase;
  conditions : Keeper_state_machine.conditions;
  restart_count : int;
}

type located_violation = {
  seq : int;
  violation : Keeper_invariant_check.violation;
}

(** Validate a JSONL trace file. Returns list of violations (empty = all passed). *)
val validate_trace_file : string -> (located_violation list, string) result

(** Parse a single JSONL line into a step. *)
val parse_step : string -> (step, string) result
