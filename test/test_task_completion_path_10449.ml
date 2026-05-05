(** #10449: pin the pure classifiers that feed
    [masc_task_completion_path_total].  The Prometheus emit point
    is fed by [Coord_task.classify_contract_state] +
    [classify_completion_path]; pinning each axis here keeps the
    metric label vocabulary stable as the lifecycle module grows. *)

open Alcotest
module CT = Masc_mcp.Coord
module L = Coord_task_lifecycle
module T = Masc_domain

let empty_links : T.task_execution_links = {
  operation_id = None;
  session_id = None;
  autoresearch_loop_id = None;
}

let empty_contract : T.task_contract = {
  strict = false;
  completion_contract = [];
  required_tools = [];
  required_evidence = [];
  inspect_gate_evidence = [];
  verify_gate_evidence = [];
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
  (* Verifier-redirect path: Approve_verification trumps drift+force. *)
  check string "approve→done is via_verification regardless of drift"
    "via_verification"
    (CT.classify_completion_path
       ~action:T.Approve_verification ~drift:None ~force:false);
  check string "approve→done with force still via_verification"
    "via_verification"
    (CT.classify_completion_path
       ~action:T.Approve_verification ~drift:None ~force:true)

let test_path_forced () =
  (* force=true short-circuits same-agent guard; record as forced_done
     so dashboards can isolate admin-override traffic. *)
  check string "force=true with no drift labels forced_done"
    "forced_done"
    (CT.classify_completion_path
       ~action:T.Done_action ~drift:None ~force:true);
  check string "force=true with claimed_to_done_skip drift still forced_done"
    "forced_done"
    (CT.classify_completion_path
       ~action:T.Done_action
       ~drift:(Some L.Claimed_to_done_skip)
       ~force:true)

let test_path_drift () =
  check string "claimed_to_done_skip without force"
    "claimed_to_done_skip"
    (CT.classify_completion_path
       ~action:T.Done_action
       ~drift:(Some L.Claimed_to_done_skip)
       ~force:false)

let test_path_normal () =
  check string "in_progress→done is the canonical path"
    "in_progress_to_done"
    (CT.classify_completion_path
       ~action:T.Done_action ~drift:None ~force:false)

let () =
  run "task_completion_path_10449" [
    ("contract_state", [
        test_case "every contract surface maps to one of three labels"
          `Quick test_contract_state;
      ]);
    ("path", [
        test_case "verifier redirect path" `Quick test_path_via_verification;
        test_case "force override path" `Quick test_path_forced;
        test_case "claimed→done drift path" `Quick test_path_drift;
        test_case "normal in_progress→done path" `Quick test_path_normal;
      ]);
  ]
