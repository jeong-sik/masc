(** RFC-0320 W3c / G5 — continuation delivery gate (pure core) + outcome tags.

    Covers [Keeper_continuation_delivery.gate_decision] (the fail-closed
    routing gate) and [describe_outcome] (the G5 observability tag that the
    ContinuationDeliveryOutcome counter labels on). Pure — no connector I/O. *)

open Alcotest

module D = Masc.Keeper_continuation_delivery
module C = Keeper_continuation_channel

let test_gate_unrouted_channel_skips_fail_closed () =
  match D.gate_decision ~channel:(C.unrouted "test no channel") ~already_replied:false ~content:"hi" with
  | D.Skip D.Skipped_unrouted -> ()
  | _ -> fail "unrouted channel must skip delivery (fail-closed, no fabrication)"
;;

let test_gate_empty_content_skips () =
  match D.gate_decision ~channel:(C.unrouted "x") ~already_replied:false ~content:"   " with
  | D.Skip D.Skipped_empty -> ()
  | _ -> fail "empty content must skip delivery"
;;

let test_gate_already_replied_skips () =
  match D.gate_decision ~channel:(C.unrouted "x") ~already_replied:true ~content:"hi" with
  | D.Skip D.Skipped_already_replied -> ()
  | _ -> fail "a turn that already posted to a surface must skip (W3b dedup)"
;;

let test_gate_routable_dashboard_delivers () =
  match
    D.gate_decision
      ~channel:(C.Dashboard { thread_id = "t1" })
      ~already_replied:false
      ~content:"answer"
  with
  | D.Deliver -> ()
  | _ -> fail "a routable Dashboard channel with real content must deliver"
;;

let test_describe_outcome_is_human_readable () =
  (* Logs retain connector/error detail; metrics use the separate closed label
     function below so this detail cannot inflate metric cardinality. *)
  let delivered = D.describe_outcome (D.Delivered { kind = "dashboard" }) in
  let unrouted = D.describe_outcome D.Skipped_unrouted in
  let failed = D.describe_outcome (D.Failed { kind = "slack"; error = "boom" }) in
  check bool "delivered tag non-empty" true (String.length delivered > 0);
  check bool "unrouted tag non-empty" true (String.length unrouted > 0);
  check bool "failed tag non-empty" true (String.length failed > 0);
  check bool "tags distinct" true (delivered <> unrouted && unrouted <> failed)
;;

let test_metric_label_excludes_failure_detail () =
  let first =
    D.outcome_metric_label (D.Failed { kind = "slack"; error = "timeout-1" })
  in
  let second =
    D.outcome_metric_label
      (D.Failed { kind = "discord"; error = "token-2" })
  in
  check string "failed metric label" "failed" first;
  check string "failure details do not change metric label" first second
;;

let () =
  run "keeper continuation delivery gate (RFC-0320 W3c/G5)"
    [ "gate"
      , [ "unrouted channel skips (fail-closed)", `Quick, test_gate_unrouted_channel_skips_fail_closed
        ; "empty content skips", `Quick, test_gate_empty_content_skips
        ; "already-replied skips (dedup)", `Quick, test_gate_already_replied_skips
        ; "routable dashboard delivers", `Quick, test_gate_routable_dashboard_delivers
        ; "describe_outcome is human-readable", `Quick, test_describe_outcome_is_human_readable
        ; "metric label excludes failure detail", `Quick, test_metric_label_excludes_failure_detail
        ]
    ]
;;
