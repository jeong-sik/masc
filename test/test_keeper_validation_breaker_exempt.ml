(** D2: caller-input validation errors must not trip the keeper HEALTH circuit
    breaker (Gate #1), while the per-(tool,args) breaker (Gate #2) must still
    count them so retrying the SAME bad args stays blocked.

    The fix tags keeper_task_create validation errors with
    [Tool_result.Policy_rejection] (RFC-0062 §3.2). This test proves the
    end-to-end behavior on the payload the producer actually emits — not a
    hand-built literal — so a regression in the producer (dropping the class)
    is caught here. *)

open Alcotest

module Task = Masc_mcp.Keeper_tool_task_runtime
module Dispatch = Masc_mcp.Keeper_tool_dispatch_runtime
module Boundary = Masc_mcp.Keeper_tools_oas_failure_boundary
(* Tool_result lives in the leaf [masc_mcp_tool_types] lib (wrapped false), so
   it is referenced bare — not under [Masc_mcp.] — matching existing tests. *)
module TR = Tool_result

(* The error a keeper sees when it sends a non-object contract — the residual
   validation case after D1 makes an OMITTED contract [Ok None]. *)
let payload =
  Task.validation_error_json
    "contract must be an object when provided (received string)"

(* A — producer: keeper_task_create validation errors carry policy_rejection. *)
let test_producer_tags_policy_rejection () =
  check (option string) "validation payload carries policy_rejection class"
    (Some "policy_rejection")
    (Dispatch.failure_class_of_tool_result_payload payload)

(* B — Gate #1 (health breaker): validation is exempt, but an UNCLASSIFIED
   error still counts (conservative: unknown -> fail, never permissive-default
   per CLAUDE.md anti-pattern #2). *)
let test_gate1_exempts_validation_but_counts_unclassified () =
  check bool "Gate#1 exempts policy_rejection validation" false
    (Dispatch.should_apply_circuit_breaker_to_failure_payload payload);
  check bool "Gate#1 still counts an unclassified (class-less) error" true
    (Dispatch.should_apply_circuit_breaker_to_failure_payload
       {|{"error":"contract must be an object when provided"}|})

(* C — Gate #2 (per-(tool,args) breaker): validation is NOT a workflow
   rejection, so identical bad args remain counted (retry-block intact). This
   is the proof we did not OVER-exempt. *)
let test_gate2_still_counts_validation () =
  let classified = Boundary.classify_raw_failure payload in
  check string "Gate#2 sees policy_rejection class" "policy_rejection"
    (TR.tool_failure_class_to_string classified.Boundary.failure_class);
  check bool
    "Gate#2 does not treat validation as workflow_rejection (still counts)"
    false classified.Boundary.is_workflow_rejection

let () =
  run "keeper validation breaker exemption"
    [ ( "validation_failure_class"
      , [ test_case "producer tags policy_rejection" `Quick
            test_producer_tags_policy_rejection
        ; test_case "Gate#1 exempts validation, counts unclassified" `Quick
            test_gate1_exempts_validation_but_counts_unclassified
        ; test_case "Gate#2 still counts validation (no over-exempt)" `Quick
            test_gate2_still_counts_validation
        ] )
    ]
