(** #10449: pin the pure classifiers that feed
    [masc_task_completion_path_total].  The Otel_metric_store emit point
    is fed by [Workspace_task.classify_contract_state] +
    [classify_completion_path]; pinning each axis here keeps the
    metric label vocabulary stable as the lifecycle module grows. *)

open Alcotest
module CT = Masc.Workspace
module T = Masc_domain

let empty_links : T.task_execution_links = {
  operation_id = None;
  session_id = None;
}

let empty_contract : T.task_contract = {
  strict = false;
  completion_contract = [];
  required_evidence = [];
  inspect_gate_evidence = [];
  verify_gate_evidence = [];
  evidence_claims = [];
  stale_claim_timeout_sec = 0;
  links = empty_links;
}

let with_completion =
  { empty_contract with completion_contract = ["scan files"] }

let with_evidence =
  { empty_contract with required_evidence = ["board post"] }

let test_contract_state () =
  check string "no contract record" "no_contract"
    (CT.classify_contract_state None);
  check string "empty lists collapse to empty_contract" "empty_contract"
    (CT.classify_contract_state (Some empty_contract));
  check string "completion_contract non-empty triggers with_contract"
    "with_contract"
    (CT.classify_contract_state (Some with_completion));
  check string "required_evidence non-empty alone triggers with_contract"
    "with_contract"
    (CT.classify_contract_state (Some with_evidence))

let test_path_via_verification () =
  check string "submitted verification path"
    "via_verification"
    (CT.classify_completion_path ~action:T.Approve_verification)

let test_path_direct () =
  check string "direct done still uses LLM verdict" "direct_llm_verdict"
    (CT.classify_completion_path ~action:T.Done_action)

let () =
  run "task_completion_path_10449" [
    ("contract_state", [
        test_case "every contract surface maps to one of three labels"
          `Quick test_contract_state;
      ]);
    ("path", [
        test_case "verifier redirect path" `Quick test_path_via_verification;
        test_case "direct configured-LLM path" `Quick test_path_direct;
      ]);
  ]
