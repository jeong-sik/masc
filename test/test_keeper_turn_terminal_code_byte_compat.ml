(** RFC-0042 PR-2 invariant: [Keeper_execution_receipt.stale_terminal_reason_code]
    output must remain byte-for-byte identical to the pre-RFC inline match
    after delegation through [Keeper_turn_terminal_code]. The oracle below
    is the literal pre-PR-2 implementation; if PR-2 (or any later refactor)
    drifts, this test fails the build. *)

module R = Masc_mcp.Keeper_registry
module Code = Masc_mcp.Keeper_turn_terminal_code

(* PR-2 invariant target: every failure_reason (and [None]) flowing
   through the new typed bridge must produce the same wire string as
   the pre-RFC inline match. The pre-RFC match has been deleted from
   [Keeper_execution_receipt] and replaced by a delegation; this test
   guards the typed bridge directly so the invariant survives later
   refactors. *)
let typed_wire fr = Code.to_wire (Code.of_failure_reason_option fr)

(* Oracle: copy of the pre-PR-2 [stale_terminal_reason_code] from
   [keeper_execution_receipt.ml]. Do not edit casually — drift here is
   the bug this test is meant to catch. *)
let oracle = function
  | Some (R.Provider_runtime_error { code; _ }) -> code
  | Some (R.Tool_required_unsatisfied { code; _ }) -> code
  | Some (R.Oas_timeout_budget_loop _) -> "oas_timeout_budget"
  | Some (R.Stale_turn_timeout _) -> "stale_turn_timeout"
  | Some (R.Stale_fleet_batch _) -> "stale_fleet_batch"
  | Some (R.Stale_termination_storm _) -> "stale_termination_storm"
  | Some (R.Heartbeat_consecutive_failures _) -> "heartbeat_failures"
  | Some (R.Turn_consecutive_failures _) -> "turn_failures"
  | Some (R.Ambiguous_partial_commit _) -> "ambiguous_partial_commit"
  | Some R.Fiber_unresolved -> "fiber_unresolved"
  | Some (R.Exception _) -> "exception"
  | None -> "stale_turn_timeout"

let cases : (string * R.failure_reason option) list = [
  "Heartbeat_consecutive_failures",
    Some (R.Heartbeat_consecutive_failures 3);
  "Turn_consecutive_failures",
    Some (R.Turn_consecutive_failures 5);
  "Stale_turn_timeout/Idle",
    Some (R.Stale_turn_timeout (R.Idle_turn { stall_seconds = 60.0 }));
  "Stale_turn_timeout/In_turn_hung",
    Some (R.Stale_turn_timeout
      (R.In_turn_hung { active_seconds = 120.0; timeout_threshold = 90.0 }));
  "Stale_turn_timeout/Noop_failure_loop",
    Some (R.Stale_turn_timeout (R.Noop_failure_loop { noop_count = 7 }));
  "Stale_termination_storm",
    Some (R.Stale_termination_storm { count = 4 });
  "Stale_fleet_batch",
    Some (R.Stale_fleet_batch { distinct_count = 6 });
  "Oas_timeout_budget_loop",
    Some (R.Oas_timeout_budget_loop { count = 2 });
  "Provider_runtime_error",
    Some (R.Provider_runtime_error
      { code = "provider_http_500"; detail = "upstream 500" });
  "Tool_required_unsatisfied",
    Some (R.Tool_required_unsatisfied
      { code = "tool_unsat_no_call"; detail = "no tool" });
  "Ambiguous_partial_commit/Post_commit_timeout",
    Some (R.Ambiguous_partial_commit
      { kind = R.Post_commit_timeout; detail = "" });
  "Ambiguous_partial_commit/Post_commit_failure",
    Some (R.Ambiguous_partial_commit
      { kind = R.Post_commit_failure; detail = "" });
  "Fiber_unresolved",
    Some R.Fiber_unresolved;
  "Exception",
    Some (R.Exception "boom");
  "None", None;
]

let test_byte_compat () =
  List.iter (fun (label, fr) ->
    let expected = oracle fr in
    let actual = typed_wire fr in
    Alcotest.(check string) label expected actual
  ) cases

let () =
  Alcotest.run "keeper_turn_terminal_code_byte_compat" [
    "stale_terminal_reason_code byte invariant",
      [ Alcotest.test_case "all failure_reason cases match oracle"
          `Quick test_byte_compat ];
  ]
