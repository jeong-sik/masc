(* test/test_require_tool_use_violation_counter_10091.ml

   #10091: pin the label vocabulary for
   [masc_keeper_require_tool_use_violations_total].  The counter
   is the operator's only signal for the active-task strict-gate
   path that #10031 intentionally left strict (the no-task path
   was already relaxed to [Auto]); its label set must be
   structurally stable so dashboards keyed on
   (keeper, has_current_task, contract_status) do not silently
   drop series when new cohorts or contract statuses appear.

   The test covers:

   1. [has_current_task=true]: the #10091 target — active-task
      refusal, strict gate fires, counter increments with
      [has_current_task="true"] and the supplied contract_status.
   2. [has_current_task=false]: the #10031 relaxation path —
      still emitted (with [has_current_task="false"]) so dashboards
      can compare relative volume of the two paths and justify or
      roll back the relaxation.
   3. Multiple contract_status values remain isolated per label
      bucket (increment on one status must not leak into another).
   4. Multiple keeper labels remain isolated.  Regression guard
      for the "single undifferentiated counter" anti-pattern
      (same one documented for [heuristic_metrics.jsonl] degenerate
      rows in [feedback_no-heuristic-category.md]).
*)

(* Set [MASC_BASE_PATH] before any module that calls
   [Env_config_core.base_path ()] at init time — #9903's
   prod-guard raises from under [/Users/dancer] otherwise,
   dune test env sets the var to [""] but that's still
   empty-string which the guard rejects. *)
let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-rtuv-10091-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module D = Masc_mcp.Keeper_tool_disclosure
module Prom = Masc_mcp.Prometheus

let metric = Prom.metric_keeper_require_tool_use_violations

let counter_for ~keeper ~has_current_task ~contract_status =
  Prom.metric_value_or_zero
    metric
    ~labels:
      [ "keeper", keeper
      ; ("has_current_task", if has_current_task then "true" else "false")
      ; "contract_status", contract_status
      ]
    ()
;;

(* Active-task refusal (the #10091 target): counter increments
   exactly on the [has_current_task="true"] bucket. *)
let test_active_task_violation_counts_on_true_bucket () =
  let keeper = "test-verifier-10091" in
  let status = "needs_execution_progress" in
  let before = counter_for ~keeper ~has_current_task:true ~contract_status:status in
  D.record_require_tool_use_violation
    ~keeper_name:keeper
    ~has_current_task:true
    ~contract_status:status;
  Alcotest.(check (float 0.0001))
    "has_current_task=true bucket +1"
    (before +. 1.0)
    (counter_for ~keeper ~has_current_task:true ~contract_status:status);
  Alcotest.(check (float 0.0001))
    "has_current_task=false bucket unchanged"
    0.0
    (counter_for ~keeper ~has_current_task:false ~contract_status:status)
;;

(* No-task refusal path still emits — dashboards compare volume
   of the two paths to justify or roll back #10031's relaxation.
   If this bucket silently drops to zero we lose the ability to
   argue about the relaxation's effect. *)
let test_no_task_violation_counts_on_false_bucket () =
  let keeper = "test-ramarama-10091" in
  let status = "passive_only" in
  let before = counter_for ~keeper ~has_current_task:false ~contract_status:status in
  D.record_require_tool_use_violation
    ~keeper_name:keeper
    ~has_current_task:false
    ~contract_status:status;
  Alcotest.(check (float 0.0001))
    "has_current_task=false bucket +1"
    (before +. 1.0)
    (counter_for ~keeper ~has_current_task:false ~contract_status:status);
  Alcotest.(check (float 0.0001))
    "has_current_task=true bucket unchanged"
    0.0
    (counter_for ~keeper ~has_current_task:true ~contract_status:status)
;;

(* The fine-grained contract_status labels must stay isolated.
   Regression guard: a call with [needs_execution_progress] must
   not leak into the [passive_only] series, otherwise the operator
   sees a single undifferentiated counter that cannot drive
   preset-reshape decisions. *)
let test_contract_status_labels_are_isolated () =
  let keeper = "test-velvet-10091" in
  let before_needs =
    counter_for ~keeper ~has_current_task:true ~contract_status:"needs_execution_progress"
  in
  let before_passive =
    counter_for ~keeper ~has_current_task:true ~contract_status:"passive_only"
  in
  D.record_require_tool_use_violation
    ~keeper_name:keeper
    ~has_current_task:true
    ~contract_status:"needs_execution_progress";
  Alcotest.(check (float 0.0001))
    "needs_execution_progress +1"
    (before_needs +. 1.0)
    (counter_for
       ~keeper
       ~has_current_task:true
       ~contract_status:"needs_execution_progress");
  Alcotest.(check (float 0.0001))
    "passive_only unchanged (no label leak)"
    before_passive
    (counter_for ~keeper ~has_current_task:true ~contract_status:"passive_only")
;;

(* Keeper name is the primary cohort discriminator: the operator
   uses it to target the right tool_preset.  Regression guard for
   cross-keeper label leakage. *)
let test_keeper_labels_are_isolated () =
  let status = "claim_only_after_owned_task" in
  let before_a =
    counter_for
      ~keeper:"test-analyst-10091"
      ~has_current_task:true
      ~contract_status:status
  in
  let before_b =
    counter_for
      ~keeper:"test-scholar-10091"
      ~has_current_task:true
      ~contract_status:status
  in
  D.record_require_tool_use_violation
    ~keeper_name:"test-analyst-10091"
    ~has_current_task:true
    ~contract_status:status;
  Alcotest.(check (float 0.0001))
    "analyst +1"
    (before_a +. 1.0)
    (counter_for
       ~keeper:"test-analyst-10091"
       ~has_current_task:true
       ~contract_status:status);
  Alcotest.(check (float 0.0001))
    "scholar unchanged"
    before_b
    (counter_for
       ~keeper:"test-scholar-10091"
       ~has_current_task:true
       ~contract_status:status)
;;

let () =
  Alcotest.run
    "require_tool_use_violation_counter_10091"
    [ ( "label_vocabulary"
      , [ Alcotest.test_case
            "active-task bucket"
            `Quick
            test_active_task_violation_counts_on_true_bucket
        ; Alcotest.test_case
            "no-task bucket"
            `Quick
            test_no_task_violation_counts_on_false_bucket
        ; Alcotest.test_case
            "contract_status isolation"
            `Quick
            test_contract_status_labels_are_isolated
        ; Alcotest.test_case "keeper isolation" `Quick test_keeper_labels_are_isolated
        ] )
    ]
;;
