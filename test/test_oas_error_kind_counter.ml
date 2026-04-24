(* test/test_oas_error_kind_counter.ml

   #9933: verify that [Oas_worker_named.sdk_error_of_masc_internal_error]
   emits [masc_oas_error_total{kind}] once per constructed error so
   Grafana can alert on per-kind rates without parsing the
   free-form BDI blocker string.  Exercises all 9 variants of
   [masc_internal_error] (the single production source of
   [masc_oas_error] payloads). *)

module OWN = Masc_mcp.Oas_worker_named
module Prom = Masc_mcp.Prometheus

let counter_for kind =
  Prom.metric_value_or_zero
    OWN.masc_oas_error_total_metric
    ~labels:[ ("kind", kind) ]
    ()

let test_metric_name_stable () =
  Alcotest.(check string)
    "canonical oas error total metric name"
    "masc_oas_error_total"
    OWN.masc_oas_error_total_metric

let test_oas_timeout_budget_kind () =
  let kind = "oas_timeout_budget" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Oas_timeout_budget
         {
           budget_sec = 423.8;
           keeper_turn_timeout_sec = 1200.0;
           estimated_input_tokens = 2519;
           source = "adaptive_estimated_input_tokens";
         })
  in
  Alcotest.(check (float 0.0001))
    "oas_timeout_budget counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_turn_timeout_kind () =
  let kind = "turn_timeout" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Turn_timeout { elapsed_sec = 1201.0 })
  in
  Alcotest.(check (float 0.0001))
    "turn_timeout counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_cascade_exhausted_kind () =
  let kind = "cascade_exhausted" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Cascade_exhausted
         {
           cascade_name = "big_three";
           reason =
             Masc_mcp.Keeper_types.Other_detail "all providers tried";
         })
  in
  Alcotest.(check (float 0.0001))
    "cascade_exhausted counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_resumable_cli_session_kind () =
  let kind = "resumable_cli_session" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Resumable_cli_session
         {
           cascade_name = "big_three";
           detail = "session resumable";
           exit_code = Some 130;
         })
  in
  Alcotest.(check (float 0.0001))
    "resumable_cli_session counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_no_tool_capable_provider_kind () =
  let kind = "no_tool_capable_provider" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.No_tool_capable_provider
         {
           cascade_name = "tool_required";
           configured_labels = [ "openai"; "anthropic" ];
         })
  in
  Alcotest.(check (float 0.0001))
    "no_tool_capable_provider counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_accept_rejected_kind () =
  let kind = "accept_rejected" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Accept_rejected
         {
           scope = "keeper_turn";
           model = Some "codex";
           reason = "accept=false";
         })
  in
  Alcotest.(check (float 0.0001))
    "accept_rejected counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_admission_queue_timeout_kind () =
  let kind = "admission_queue_timeout" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Admission_queue_timeout
         {
           keeper_name = "keeper-alpha";
           cascade_name = "big_three";
           wait_sec = 30.0;
         })
  in
  Alcotest.(check (float 0.0001))
    "admission_queue_timeout counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_admission_queue_rejected_kind () =
  let kind = "admission_queue_rejected" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Admission_queue_rejected
         { keeper_name = "keeper-alpha"; reason = "queue closed" })
  in
  Alcotest.(check (float 0.0001))
    "admission_queue_rejected counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_ambiguous_post_commit_kind () =
  let kind = "ambiguous_post_commit" in
  let before = counter_for kind in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Ambiguous_post_commit
         {
           is_timeout = true;
           tools = [ "keeper_board_post" ];
           original_error = "provider timeout";
         })
  in
  Alcotest.(check (float 0.0001))
    "ambiguous_post_commit counter +1"
    (before +. 1.0)
    (counter_for kind)

let test_kind_isolation () =
  (* Bumping one kind must not move the counter for a different
     kind — the label separation is what lets Grafana split
     [rate(...{kind=~"oas_timeout_budget"}[5m])] cleanly. *)
  let a = "turn_timeout" in
  let b = "oas_timeout_budget" in
  let b_before = counter_for b in
  let _ =
    OWN.sdk_error_of_masc_internal_error
      (OWN.Turn_timeout { elapsed_sec = 42.0 })
  in
  Alcotest.(check (float 0.0001))
    "different kind counter unchanged"
    b_before (counter_for b);
  ignore a

let () =
  Alcotest.run "oas_error_kind_counter_9933"
    [
      ( "metric_name",
        [
          Alcotest.test_case "canonical name stable" `Quick
            test_metric_name_stable;
        ] );
      ( "per_kind_increment",
        [
          Alcotest.test_case "oas_timeout_budget" `Quick
            test_oas_timeout_budget_kind;
          Alcotest.test_case "turn_timeout" `Quick
            test_turn_timeout_kind;
          Alcotest.test_case "cascade_exhausted" `Quick
            test_cascade_exhausted_kind;
          Alcotest.test_case "resumable_cli_session" `Quick
            test_resumable_cli_session_kind;
          Alcotest.test_case "no_tool_capable_provider" `Quick
            test_no_tool_capable_provider_kind;
          Alcotest.test_case "accept_rejected" `Quick
            test_accept_rejected_kind;
          Alcotest.test_case "admission_queue_timeout" `Quick
            test_admission_queue_timeout_kind;
          Alcotest.test_case "admission_queue_rejected" `Quick
            test_admission_queue_rejected_kind;
          Alcotest.test_case "ambiguous_post_commit" `Quick
            test_ambiguous_post_commit_kind;
        ] );
      ( "isolation",
        [
          Alcotest.test_case "kind labels separate" `Quick
            test_kind_isolation;
        ] );
    ]
