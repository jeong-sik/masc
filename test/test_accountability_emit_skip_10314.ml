(** #10314 — pin the accountability ledger emit-skip counter.

    Pre-fix [is_keeper_agent_name] silently dropped any
    [record_task_transition] / [record_completion_claim] call whose
    [agent_name] did not parse as a [keeper-<name>-agent] alias.
    Production evidence (#10314): 9 of 14 keepers
    (executor, taskmaster, qa-king, issue_king, ...) had
    decisions.jsonl traffic of 43KB-1MB+ but zero accountability
    events; analyst alone produced 47% of the ledger.  The
    asymmetry was invisible — the gate emitted no signal.

    These tests pin
    [Keeper_accountability.accountability_emit_skip_metric]:

    1. A non-keeper agent_name through [record_task_transition]
       increments [{kind=task_transition, reason=not_keeper_agent_name}].
    2. A non-keeper agent_name through [record_completion_claim]
       increments [{kind=completion_claim, reason=not_keeper_agent_name}].
    3. A valid keeper agent_name with an empty subject through
       [record_completion_claim] increments
       [{kind=completion_claim, reason=empty_subject}].
    4. A valid keeper agent_name with a non-empty subject does
       NOT increment any skip counter (the call proceeds).
    5. Distinct (kind, reason) pairs land in distinct counter rows
       so dashboards can rate-alert per failure mode. *)

open Alcotest
open Masc_mcp

module Acct = Keeper_accountability
module Prom = Prometheus

(* --- helpers ------------------------------------------------------ *)

let temp_dir () =
  let path = Filename.temp_file "acct_skip_10314_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_config f =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some "planner"));
      f config)

let counter_for ~kind ~reason =
  Prom.metric_value_or_zero
    Acct.accountability_emit_skip_metric
    ~labels:[ ("kind", kind); ("reason", reason) ]
    ()

(* --- 1. record_task_transition: non-keeper agent_name --------- *)

let test_task_transition_non_keeper_increments () =
  with_temp_config @@ fun config ->
  let kind = "task_transition" in
  let reason = "not_keeper_agent_name" in
  let before = counter_for ~kind ~reason in
  (* "executor" is a bare keeper name, not [keeper-executor-agent].
     Pre-#10314 this dropped silently; now it surfaces. *)
  Acct.record_task_transition config ~agent_name:"executor"
    ~task_id:"task-9001" ~transition:Masc_domain.Claim ~details:`Null;
  check (float 0.0001)
    "executor (non-keeper alias) drop is counted"
    (before +. 1.0)
    (counter_for ~kind ~reason)

(* --- 2. record_completion_claim: non-keeper agent_name --------- *)

let test_completion_claim_non_keeper_increments () =
  with_temp_config @@ fun config ->
  let kind = "completion_claim" in
  let reason = "not_keeper_agent_name" in
  let before = counter_for ~kind ~reason in
  Acct.record_completion_claim config ~keeper_name:"taskmaster"
    ~agent_name:"taskmaster" ~trace_id:"t-1" ~turn_number:0
    ~subject:"shipped a thing" ~strong_evidence:false
    ~strong_evidence_refs:[] ();
  check (float 0.0001)
    "taskmaster (non-keeper alias) drop is counted"
    (before +. 1.0)
    (counter_for ~kind ~reason)

(* --- 3. record_completion_claim: valid keeper, empty subject --- *)

let test_completion_claim_empty_subject_increments () =
  with_temp_config @@ fun config ->
  let kind = "completion_claim" in
  let reason = "empty_subject" in
  let before = counter_for ~kind ~reason in
  (* Valid keeper-<name>-agent alias passes the first gate, but
     a whitespace-only subject hits the second gate and previously
     dropped silently. *)
  Acct.record_completion_claim config ~keeper_name:"executor"
    ~agent_name:"keeper-executor-agent" ~trace_id:"t-2" ~turn_number:0
    ~subject:"   " ~strong_evidence:false
    ~strong_evidence_refs:[] ();
  check (float 0.0001)
    "valid keeper + empty subject drop is counted"
    (before +. 1.0)
    (counter_for ~kind ~reason)

(* --- 4. valid keeper + non-empty subject: no skip ------------- *)

let test_valid_call_does_not_increment () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_config @@ fun config ->
  let kt = counter_for ~kind:"completion_claim"
             ~reason:"not_keeper_agent_name" in
  let ks = counter_for ~kind:"completion_claim"
             ~reason:"empty_subject" in
  (* A valid keeper alias + non-empty subject must NOT touch either
     skip counter — the call passes both gates and proceeds to the
     real append path. We don't assert on the append outcome here;
     the read_window_entries call needs an Eio context which the
     [Eio_main.run] above provides. *)
  Acct.record_completion_claim config ~keeper_name:"executor"
    ~agent_name:"keeper-executor-agent" ~trace_id:"t-3" ~turn_number:0
    ~subject:"shipped feature X" ~strong_evidence:false
    ~strong_evidence_refs:[] ();
  check (float 0.0001)
    "valid call does not increment not_keeper_agent_name"
    kt
    (counter_for ~kind:"completion_claim"
       ~reason:"not_keeper_agent_name");
  check (float 0.0001)
    "valid call does not increment empty_subject"
    ks
    (counter_for ~kind:"completion_claim" ~reason:"empty_subject")

(* --- 5. distinct (kind, reason) labels separate ------------- *)

let test_kind_and_reason_isolation () =
  with_temp_config @@ fun config ->
  (* Bumping (task_transition, not_keeper_agent_name) must NOT move
     completion_claim counters. Operators rate-alert per failure
     mode. *)
  let unrelated_before =
    counter_for ~kind:"completion_claim"
      ~reason:"not_keeper_agent_name"
  in
  Acct.record_task_transition config ~agent_name:"qa-king"
    ~task_id:"task-9002" ~transition:Masc_domain.Start ~details:`Null;
  check (float 0.0001)
    "completion_claim/not_keeper_agent_name unchanged when \
     task_transition bumps"
    unrelated_before
    (counter_for ~kind:"completion_claim"
       ~reason:"not_keeper_agent_name")

let () =
  run "accountability_emit_skip_10314"
    [
      ( "task_transition",
        [
          test_case "non-keeper agent_name drop is counted" `Quick
            test_task_transition_non_keeper_increments;
        ] );
      ( "completion_claim",
        [
          test_case "non-keeper agent_name drop is counted" `Quick
            test_completion_claim_non_keeper_increments;
          test_case "empty subject drop is counted" `Quick
            test_completion_claim_empty_subject_increments;
          test_case "valid call leaves counters unchanged" `Quick
            test_valid_call_does_not_increment;
        ] );
      ( "label_isolation",
        [
          test_case "(kind, reason) pairs separate" `Quick
            test_kind_and_reason_isolation;
        ] );
    ]
