(** Unit tests for [Keeper_tool_deterministic_error.classify].

    These tests exercise the closed-set classifier without bringing up
    the full keeper_tools_oas / Eio scheduler. The integration test
    that asserts the retry-counter jump lives in
    [test_keeper_tools_oas_retry_skipped.ml] once the surrounding
    fixtures stabilise; this file pins the classifier contract.

    Background: MASC/OAS Error-Warn Reduction Goal 2026-05-18 P2
    reducer. *)

module D = Masc.Keeper_tool_deterministic_error
module Execute_runtime = Masc.Keeper_tool_execute_runtime.For_testing
module Shell_dispatch = Keeper_tool_execute_shell_ir
module AQ = Masc.Keeper_approval_queue
module Metrics = Masc.Otel_metric_store

external unsetenv : string -> unit = "masc_test_unsetenv"

let reason_testable =
  let pp ppf reason = Format.pp_print_string ppf (D.to_telemetry_key reason) in
  Alcotest.testable pp ( = )
;;

let source_testable =
  let pp ppf source =
    Format.pp_print_string ppf (D.classification_source_to_string source)
  in
  Alcotest.testable pp ( = )
;;

let check_classify ~name ~expected raw =
  Alcotest.check
    Alcotest.(option reason_testable)
    name
    expected
    (D.classify_raw raw)
;;

let check_classify_source ~name ~expected_reason ~expected_source raw =
  match D.classify_raw_with_source raw with
  | None -> Alcotest.fail (name ^ ": expected classified deterministic result")
  | Some classification ->
    Alcotest.check reason_testable (name ^ ": reason") expected_reason classification.reason;
    Alcotest.check source_testable (name ^ ": source") expected_source classification.source
;;

(* ── Deterministic — explicit typed markers ───────────────────── *)

let deterministic_marker_raw ?(error = "timeout") reason =
  Yojson.Safe.to_string
    (`Assoc
       ([ "ok", `Bool false; "error", `String error ]
        @ D.deterministic_retry_fields reason))
;;

let dispatch_error_marker_raw error =
  Yojson.Safe.to_string
    (`Assoc
       ([ "ok", `Bool false; "error", `String "execute_dispatch_rejected" ]
        @ Execute_runtime.dispatch_error_deterministic_retry_fields error))
;;

let temp_dir () =
  let dir = Filename.temp_file "test_shell_ir_approval_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  try rm_rf dir with _ -> ()
;;

let shell_ir_approval_env_key = "MASC_SHELL_IR_APPROVAL"

let set_shell_ir_approval_env = function
  | Some value -> Unix.putenv shell_ir_approval_env_key value
  | None -> unsetenv shell_ir_approval_env_key
;;

let with_shell_ir_approval_env value f =
  let previous = Sys.getenv_opt shell_ir_approval_env_key in
  Fun.protect
    ~finally:(fun () -> set_shell_ir_approval_env previous)
    (fun () ->
      set_shell_ir_approval_env value;
      f ())
;;

let overlay_testable =
  let open Masc_exec.Approval_config in
  let pp ppf overlay =
    Format.fprintf
      ppf
      "{safe=%s; audited=%s; privileged=%s}"
      (trust_level_to_string overlay.safe_trust)
      (trust_level_to_string overlay.audited_trust)
      (trust_level_to_string overlay.privileged_trust)
  in
  Alcotest.testable pp ( = )
;;

let test_shell_ir_approval_overlay_resolves_live () =
  let module Approval = Masc_exec.Approval_config in
  with_shell_ir_approval_env (Some "permissive") (fun () ->
    Alcotest.check
      overlay_testable
      "initial parsed overlay"
      Approval.permissive_default
      (Execute_runtime.shell_ir_approval_overlay ());
    set_shell_ir_approval_env (Some "enforced");
    Alcotest.check
      overlay_testable
      "updated env is reflected without reloading the module"
      Approval.enforced_all
      (Execute_runtime.shell_ir_approval_overlay ());
    set_shell_ir_approval_env (Some "not-a-valid-overlay");
    Alcotest.check
      overlay_testable
      "invalid overlay fails closed"
      Approval.enforced_all
      (Execute_runtime.shell_ir_approval_overlay ());
    set_shell_ir_approval_env None;
    Alcotest.check
      overlay_testable
      "missing overlay falls back to autonomous"
      Approval.autonomous
      (Execute_runtime.shell_ir_approval_overlay ()))
;;

let submit_test_gh_approval_pending ~base_path () =
  Execute_runtime.submit_shell_ir_approval_pending
    ~base_path
    ~keeper_name:"typed-gh-keeper"
    ~task_id:"task-typed-gh"
    ~goal_ids:[ "goal-typed-gh" ]
    ~cmd:"gh repo create owner/new-repo --public"
    ~cwd:"/tmp/masc"
    ~bin:"gh"
    ~summary:"command 'gh' requires approval (audited/privileged risk class)"
    ~sandbox_profile:"host"
    ~sandbox_target:"host"
    ~risk_class:Masc_exec.Shell_ir_risk.R1_Reversible_mutation
    ~typed_hit:true
    ()
;;

let test_command_shape_blocked () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
          ([ "ok", `Bool false
           ; "error", `String "tool_execute_command_shape_blocked"
           ; "reason", `String "pipes blocked"
           ]
           @ D.deterministic_retry_fields D.Command_shape_blocked))
  in
  check_classify
    ~name:"tool_execute_command_shape_blocked"
    ~expected:(Some D.Command_shape_blocked)
    raw
;;

let test_task_state_file_probe_blocked () =
  let raw =
    deterministic_marker_raw
      ~error:"task_state_file_probe_blocked"
      D.Task_state_probe_blocked
  in
  check_classify
    ~name:"task_state_file_probe_blocked"
    ~expected:(Some D.Task_state_probe_blocked)
    raw
;;

let test_destructive_operation_blocked () =
  let raw =
    deterministic_marker_raw
      ~error:"destructive_operation_blocked"
      D.Destructive_operation_blocked
  in
  check_classify
    ~name:"destructive_operation_blocked"
    ~expected:(Some D.Destructive_operation_blocked)
    raw
;;

let test_policy_blocked () =
  let raw = deterministic_marker_raw ~error:"policy_blocked" D.Policy_blocked in
  check_classify ~name:"policy_blocked" ~expected:(Some D.Policy_blocked) raw
;;

let test_policy_blocked_gh_irreversible () =
  let raw =
    deterministic_marker_raw ~error:"gh_irreversible_blocked" D.Policy_blocked
  in
  check_classify
    ~name:"gh_irreversible_blocked"
    ~expected:(Some D.Policy_blocked)
    raw
;;

let test_completion_contract_violation () =
  let raw =
    deterministic_marker_raw
      ~error:"completion_contract_violation"
      D.Completion_contract_violation
  in
  check_classify
    ~name:"completion_contract_violation"
    ~expected:(Some D.Completion_contract_violation)
    raw
;;

let test_tool_search_files_op_payload () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
          ([ "ok", `Bool false
           ; "error", `String "tool_execute_requires_git_cwd"
           ]
           @ D.deterministic_retry_fields D.Structured_tool_payload))
  in
  check_classify
    ~name:"tool_execute_requires_git_cwd"
    ~expected:(Some D.Structured_tool_payload)
    raw
;;

let test_typed_deterministic_retry_marker_takes_precedence () =
  let raw = deterministic_marker_raw D.Write_operation_gated in
  check_classify
    ~name:"typed deterministic retry marker"
    ~expected:(Some D.Write_operation_gated)
    raw
;;

let test_typed_deterministic_retry_marker_reports_source () =
  let raw = deterministic_marker_raw D.Write_operation_gated in
  check_classify_source
    ~name:"typed deterministic retry marker source"
    ~expected_reason:D.Write_operation_gated
    ~expected_source:D.Deterministic_retry_marker
    raw
;;

let test_dispatch_gate_reject_marks_command_shape_blocked () =
  let raw =
    dispatch_error_marker_raw
      (Shell_dispatch.Gate_reject "shell operator token rejected")
  in
  check_classify
    ~name:"dispatch gate reject marker"
    ~expected:(Some D.Command_shape_blocked)
    raw
;;

let test_dispatch_parse_rejects_mark_command_shape_blocked () =
  List.iter
    (fun (name, error) ->
      check_classify
        ~name
        ~expected:(Some D.Command_shape_blocked)
        (dispatch_error_marker_raw error))
    [ "dispatch cannot_parse marker", Shell_dispatch.Cannot_parse
    ; "dispatch too_complex marker", Shell_dispatch.Too_complex
    ]
;;

let test_dispatch_path_reject_marks_path_reason () =
  List.iter
    (fun (name, error, expected) ->
      check_classify
        ~name
        ~expected:(Some expected)
        (dispatch_error_marker_raw (Shell_dispatch.Path_reject error)))
    [ ( "dispatch path outside whitelist marker"
      , "Path blocked: /etc/passwd (outside allowed directories)"
      , D.Path_outside_sandbox )
    ; ( "dispatch cwd_not_directory marker"
      , "cwd_not_directory: /tmp/missing (directory does not exist under cwd)"
      , D.Cwd_not_directory )
    ; ( "dispatch path_not_found_under_allowed_roots marker"
      , "path_not_found_under_allowed_roots: repos/masc/nope.ml"
      , D.Path_not_found )
    ; ( "dispatch task state path marker"
      , "task_state_file_path_blocked: .masc/tasks.json"
      , D.Task_state_probe_blocked )
    ]
;;

let test_dispatch_unknown_path_reject_stays_observed () =
  check_classify
    ~name:"dispatch unknown path reject observed"
    ~expected:None
    (dispatch_error_marker_raw
       (Shell_dispatch.Path_reject "new_path_error_without_typed_prefix"))
;;

let test_dispatch_policy_rejects_mark_policy_blocked () =
  List.iter
    (fun (name, error) ->
      check_classify
        ~name
        ~expected:(Some D.Policy_blocked)
        (dispatch_error_marker_raw error))
    [ ( "dispatch approval_required marker"
      , Shell_dispatch.Approval_required
          { summary = "approval required"
          ; bin = "gh"
          ; kind = Shell_dispatch.Gh_capability_requires_approval
          } )
    ; ( "dispatch policy_denied marker"
      , Shell_dispatch.Policy_denied { reason = "policy denied" } )
    ]
;;

let string_member name json =
  match Yojson.Safe.Util.member name json with
  | `String s -> s
  | other ->
    Alcotest.failf
      "expected string field %s, got %s"
      name
      (Yojson.Safe.to_string other)
;;

let bool_member name json =
  match Yojson.Safe.Util.member name json with
  | `Bool b -> b
  | other ->
    Alcotest.failf
      "expected bool field %s, got %s"
      name
      (Yojson.Safe.to_string other)
;;

let test_gh_approval_pending_helper_enqueues_nonblocking () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  let approval_id = ref None in
  Fun.protect
    ~finally:(fun () ->
      (match !approval_id with
       | Some id ->
         ignore (AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "test cleanup"))
       | None -> ());
      cleanup_dir base_path)
    (fun () ->
       let before = AQ.pending_count () in
       let block_time_metric = Keeper_metrics.(to_string GatedGhBlockTimeSeconds) in
       let block_time_labels =
         [ "keeper", "typed-gh-keeper"
         ; "risk_class", "R1"
         ; "typed_hit", "true"
         ]
       in
       let before_block_sum =
         Metrics.metric_value_or_zero block_time_metric ~labels:block_time_labels ()
       in
       let before_block_count =
         Metrics.metric_value_or_zero
           (block_time_metric ^ "_count")
           ~labels:block_time_labels
           ()
       in
       let id = submit_test_gh_approval_pending ~base_path () in
       approval_id := Some id;
       Alcotest.(check bool) "approval id nonempty" true (String.length id > 0);
       Alcotest.(check int) "pending count increments" (before + 1) (AQ.pending_count ());
       match AQ.get_pending_entry ~id with
       | None -> Alcotest.fail "pending entry missing"
       | Some entry ->
         Alcotest.(check string) "keeper" "typed-gh-keeper" entry.keeper_name;
         Alcotest.(check string) "tool" "tool_execute" entry.tool_name;
         Alcotest.(check string)
           "disposition"
           "requires_approval"
           (Option.value entry.disposition ~default:"");
         Alcotest.(check string)
           "task_id"
           "task-typed-gh"
           (Option.value entry.task_id ~default:"");
         Alcotest.(check (list string))
           "goal_ids"
           [ "goal-typed-gh" ]
           entry.goal_ids;
         Alcotest.(check string)
           "kind"
           "gh_capability_requires_approval"
           (string_member "kind" entry.input);
         Alcotest.(check bool) "typed_hit" true (bool_member "typed_hit" entry.input);
         Alcotest.(check string)
           "risk_class"
           "R1"
           (string_member "risk_class" entry.input);
         Alcotest.(check (float 0.0001))
           "block time sum stays zero"
           before_block_sum
           (Metrics.metric_value_or_zero block_time_metric ~labels:block_time_labels ());
         Alcotest.(check (float 0.0001))
           "block time observation recorded"
           (before_block_count +. 1.0)
           (Metrics.metric_value_or_zero
              (block_time_metric ^ "_count")
              ~labels:block_time_labels
              ()))
;;

let resolve_or_fail ~id decision =
  match AQ.resolve ~id ~decision with
  | Ok () -> ()
  | Error err ->
    Alcotest.failf "approval resolve failed: %s" (AQ.resolve_error_to_string err)
;;

let require_durable_resolution
    ~base_path
    ~(entry : AQ.pending_approval)
    ~expected_decision
  =
  let matching =
    Masc.Keeper_registry_event_queue.snapshot ~base_path entry.keeper_name
    |> Keeper_event_queue.to_list
    |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Hitl_resolved resolution
        when String.equal resolution.approval_id entry.id ->
        Some (stimulus, resolution)
      | _ -> None)
  in
  match matching with
  | [ stimulus, resolution ] ->
    Alcotest.(check string)
      "resolution post id is canonical"
      (Keeper_event_queue.hitl_resolution_post_id resolution)
      stimulus.post_id;
    (match expected_decision, resolution.decision with
     | `Approved, Keeper_event_queue.Hitl_approved action ->
       Alcotest.(check bool)
         "approved wake preserves exact request identity"
         true
         (AQ.approved_action_matches_request
            action
            ~keeper_name:entry.keeper_name
            ~tool_name:entry.tool_name
            ~input:entry.input)
     | `Rejected, Keeper_event_queue.Hitl_rejected -> ()
     | (`Approved | `Rejected), _ ->
       Alcotest.fail "durable resolution decision changed")
  | rows ->
    Alcotest.failf
      "expected one durable resolution for %s, got %d"
      entry.id
      (List.length rows)
;;

let test_gh_approval_resolution_does_not_install_retry_grant () =
  Eio_main.run @@ fun _env ->
  let base_path = temp_dir () in
  let approval_ids = ref [] in
  let remember id =
    approval_ids := id :: !approval_ids;
    id
  in
  let forget id =
    approval_ids := List.filter (fun pending_id -> not (String.equal pending_id id)) !approval_ids
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun id ->
           ignore (AQ.resolve ~id ~decision:(Agent_sdk.Hooks.Reject "test cleanup")))
        !approval_ids;
      cleanup_dir base_path)
    (fun () ->
       let before = AQ.pending_count () in
       let first_id = remember (submit_test_gh_approval_pending ~base_path ()) in
       let first_entry =
         match AQ.get_pending_entry ~id:first_id with
         | Some entry -> entry
         | None -> Alcotest.fail "first pending approval is missing"
       in
       Alcotest.(check int)
         "first request pending"
         (before + 1)
         (AQ.pending_count ());
       resolve_or_fail ~id:first_id Agent_sdk.Hooks.Approve;
       require_durable_resolution
         ~base_path
         ~entry:first_entry
         ~expected_decision:`Approved;
       forget first_id;
       Alcotest.(check int)
         "approval removed from pending queue"
         before
         (AQ.pending_count ());
       let second_id = remember (submit_test_gh_approval_pending ~base_path ()) in
       let second_entry =
         match AQ.get_pending_entry ~id:second_id with
         | Some entry -> entry
         | None -> Alcotest.fail "second pending approval is missing"
       in
       Alcotest.(check bool)
         "retry creates a fresh pending approval"
         true
         (String.length second_id > 0 && not (String.equal first_id second_id));
       Alcotest.(check int)
         "retry re-enqueues instead of consuming grant"
         (before + 1)
         (AQ.pending_count ());
       resolve_or_fail ~id:second_id (Agent_sdk.Hooks.Reject "test cleanup");
       require_durable_resolution
         ~base_path
         ~entry:second_entry
         ~expected_decision:`Rejected;
       forget second_id;
       Alcotest.(check int) "cleanup restores pending count" before (AQ.pending_count ()))
;;

let test_plain_error_codes_are_observed_only () =
  let cases =
    [ "command_blocked"
    ; "task_state_file_probe_blocked"
    ; "destructive_operation_blocked"
    ; "policy_blocked"
    ; "gh_irreversible_blocked"
    ; "completion_contract_violation"
    ]
  in
  List.iter
    (fun error ->
      let raw =
        Yojson.Safe.to_string
          (`Assoc
             [ "ok", `Bool false
             ; "error", `String error
             ; "reason", `String "plain deterministic-looking error code"
             ])
      in
      check_classify ~name:("plain error code observed: " ^ error) ~expected:None raw)
    cases
;;

let test_retryability_without_deterministic_reason_is_observed_only () =
  let raw =
    {|{"ok":false,"error":"command_blocked","retryability":"self_correct","reason":"retryable but no typed deterministic reason"}|}
  in
  check_classify
    ~name:"retryability without deterministic reason"
    ~expected:None
    raw
;;

let test_unknown_typed_deterministic_retry_marker_observes () =
  let raw =
    {|{"ok":false,"error":"timeout","deterministic_retry":{"reason":"new_reason","retry_same_args":false}}|}
  in
  check_classify ~name:"unknown deterministic retry marker" ~expected:None raw
;;

let test_typed_deterministic_retry_marker_requires_no_same_args_retry () =
  let raw =
    {|{"ok":false,"error":"timeout","deterministic_retry":{"reason":"write_operation_gated","retry_same_args":true}}|}
  in
  check_classify
    ~name:"deterministic retry marker with retry_same_args=true"
    ~expected:None
    raw
;;

let test_typed_deterministic_retry_marker_requires_retry_same_args_field () =
  let raw =
    {|{"ok":false,"error":"timeout","deterministic_retry":{"reason":"write_operation_gated"}}|}
  in
  check_classify
    ~name:"deterministic retry marker without retry_same_args"
    ~expected:None
    raw
;;

(* ── Deterministic — path-check path ──────────────────────────── *)

let test_path_outside_sandbox_via_path_check_block () =
  let raw =
    {|{"ok":false,"error":"tool_execute_blocked","path_check":{"reason":"path_outside_sandbox"}}|}
  in
  check_classify
    ~name:"path_check.reason=path_outside_sandbox"
    ~expected:(Some D.Path_outside_sandbox)
    raw
;;

let test_cwd_not_directory () =
  let raw = {|{"ok":false,"error":"cwd_not_directory"}|} in
  check_classify
    ~name:"cwd_not_directory"
    ~expected:(Some D.Cwd_not_directory)
    raw
;;

(* ── Deterministic — typed workflow_rejection ─────────────────── *)

let test_workflow_rejection_failure_class_only_is_observed () =
  let raw =
    {|{"ok":false,"error":"some_rule","failure_class":"workflow_rejection"}|}
  in
  check_classify
    ~name:"failure_class=workflow_rejection without deterministic marker"
    ~expected:None
    raw
;;

let test_workflow_rejection_plain_error_code_is_observed () =
  let raw =
    {|{"ok":false,"error":"task_state_file_probe_blocked","failure_class":"workflow_rejection"}|}
  in
  check_classify
    ~name:"workflow_rejection does not fall through to plain error code"
    ~expected:None
    raw
;;

let test_workflow_rejection_explicit_deterministic () =
  let raw =
    {|{"ok":false,"error":"some_rule","failure_class":"workflow_rejection","error_class":"deterministic","recoverable":false}|}
  in
  check_classify
    ~name:"explicit deterministic workflow_rejection"
    ~expected:(Some D.Workflow_rejection_blocked)
    raw
;;

let test_workflow_rejection_nested_under_detail () =
  let raw =
    {|{"ok":false,"detail":{"failure_class":"workflow_rejection","error_class":"deterministic","recoverable":false}}|}
  in
  check_classify
    ~name:"detail deterministic workflow_rejection"
    ~expected:(Some D.Workflow_rejection_blocked)
    raw
;;

(* ── Git process failures stay recoverable ────────────────────── *)

let test_retired_git_precondition_marker_is_observed_only () =
  let raw =
    {|{"ok":false,"error":"git_exit_128","deterministic_retry":{"reason":"git_precondition_failed","retry_same_args":false}}|}
  in
  check_classify
    ~name:"retired git precondition marker"
    ~expected:None
    raw
;;

let test_plain_git_exit_128_is_observed_only () =
  let raw =
    {|{"status":"error","exit_code":128,"retryability":"none","output":"fatal: main...keeper-verifier-agent/task-259: no merge base\n","command":"git diff main...keeper-verifier-agent/task-259","agent":"keeper-verifier-agent"}|}
  in
  check_classify ~name:"plain git exit 128" ~expected:None raw
;;

(* ── Negative — transient / runtime / shell exit ──────────────── *)

let test_shell_exit_nonzero_is_transient () =
  let raw =
    {|{"ok":false,"status":{"label":"general_error","kind":"exit_nonzero"},"hint":"check stderr"}|}
  in
  check_classify ~name:"general_error (transient)" ~expected:None raw
;;

let test_wrong_arguments_is_transient () =
  let raw =
    {|{"ok":false,"status":{"label":"wrong_arguments","kind":"exit_nonzero"}}|}
  in
  check_classify ~name:"wrong_arguments (transient)" ~expected:None raw
;;

let test_circuit_breaker_marker_is_transient () =
  let raw =
    {|{"ok":false,"circuit_breaker":true,"status":{"label":"general_error"}}|}
  in
  check_classify ~name:"circuit_breaker marker only" ~expected:None raw
;;

let test_transient_failure_class_is_not_deterministic () =
  let raw =
    {|{"ok":false,"error":"timeout","failure_class":"transient_error"}|}
  in
  check_classify ~name:"failure_class=transient_error" ~expected:None raw
;;

let test_invalid_json_returns_none () =
  let raw = "not json at all" in
  check_classify ~name:"invalid JSON" ~expected:None raw
;;

let test_empty_payload_returns_none () =
  let raw = "{}" in
  check_classify ~name:"empty object" ~expected:None raw
;;

(* ── Negative — unknown error code stays None ─────────────────── *)

let test_unknown_error_code_returns_none () =
  let raw = {|{"ok":false,"error":"some_brand_new_error_code"}|} in
  check_classify ~name:"unknown error code" ~expected:None raw
;;

(* ── Telemetry key invariants ─────────────────────────────────── *)

let test_telemetry_key_format () =
  let key = D.to_telemetry_key D.Command_shape_blocked in
  Alcotest.(check string)
    "telemetry key has stable prefix"
    "deterministic_error_command_shape_blocked"
    key
;;

let test_to_string_non_empty_for_every_variant () =
  let variants =
    [ D.Command_blocked
    ; D.Command_shape_blocked
    ; D.Task_state_probe_blocked
    ; D.Destructive_operation_blocked
    ; D.Path_outside_sandbox
    ; D.Cwd_not_directory
    ; D.Policy_blocked
    ; D.Write_operation_gated
    ; D.Completion_contract_violation
    ; D.Structured_tool_payload
    ; D.Workflow_rejection_blocked
    ]
  in
  List.iter
    (fun v ->
      let s = D.to_string v in
      Alcotest.(check bool)
        ("to_string non-empty for " ^ D.to_telemetry_key v)
        true
        (String.length s > 0))
    variants
;;

let test_unregistered_repo_access_denial_is_policy_blocked () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool false
         ; "error", `String "Repository masc-mcp is not registered; access not allowed"
         ; "path", `String "/Users/dancer/me/.masc/playground/docker/rondo/repos/masc-mcp/lib/foo.ml"
         ; ( "deterministic_retry"
           , `Assoc [ "reason", `String "policy_blocked"; "retry_same_args", `Bool false ] )
         ])
  in
  check_classify_source
    ~name:"unregistered_repo_access_denial"
    ~expected_reason:D.Policy_blocked
    ~expected_source:D.Deterministic_retry_marker
    raw
;;

let () =
  Alcotest.run
    "tool_execute_retry_deterministic_close"
    [ ( "classify_typed_markers"
      , [ Alcotest.test_case
            "command_shape_blocked"
            `Quick
            test_command_shape_blocked
        ; Alcotest.test_case
            "task_state_file_probe_blocked"
            `Quick
            test_task_state_file_probe_blocked
        ; Alcotest.test_case
            "destructive_operation_blocked"
            `Quick
            test_destructive_operation_blocked
        ; Alcotest.test_case "policy_blocked" `Quick test_policy_blocked
        ; Alcotest.test_case
            "gh_irreversible_blocked"
            `Quick
            test_policy_blocked_gh_irreversible
        ; Alcotest.test_case
            "unregistered_repo_access_denial"
            `Quick
            test_unregistered_repo_access_denial_is_policy_blocked
        ; Alcotest.test_case
            "completion_contract_violation"
            `Quick
            test_completion_contract_violation
        ; Alcotest.test_case
            "tool_search_files_op_payload"
            `Quick
            test_tool_search_files_op_payload
        ; Alcotest.test_case
            "typed_deterministic_retry_marker"
            `Quick
            test_typed_deterministic_retry_marker_takes_precedence
        ; Alcotest.test_case
            "typed_deterministic_retry_marker_reports_source"
            `Quick
            test_typed_deterministic_retry_marker_reports_source
        ; Alcotest.test_case
            "dispatch_gate_reject_marker"
            `Quick
            test_dispatch_gate_reject_marks_command_shape_blocked
        ; Alcotest.test_case
            "dispatch_parse_reject_markers"
            `Quick
            test_dispatch_parse_rejects_mark_command_shape_blocked
        ; Alcotest.test_case
            "dispatch_path_reject_markers"
            `Quick
            test_dispatch_path_reject_marks_path_reason
        ; Alcotest.test_case
            "dispatch_unknown_path_reject_observed"
            `Quick
            test_dispatch_unknown_path_reject_stays_observed
        ; Alcotest.test_case
            "dispatch_policy_reject_markers"
            `Quick
            test_dispatch_policy_rejects_mark_policy_blocked
        ; Alcotest.test_case
            "plain_error_codes_observed_only"
            `Quick
            test_plain_error_codes_are_observed_only
        ; Alcotest.test_case
            "retryability_without_deterministic_reason_observed_only"
            `Quick
            test_retryability_without_deterministic_reason_is_observed_only
        ; Alcotest.test_case
            "unknown_typed_deterministic_retry_marker_observes"
            `Quick
            test_unknown_typed_deterministic_retry_marker_observes
        ; Alcotest.test_case
            "typed_deterministic_retry_marker_requires_no_same_args_retry"
            `Quick
            test_typed_deterministic_retry_marker_requires_no_same_args_retry
        ; Alcotest.test_case
            "typed_deterministic_retry_marker_requires_retry_same_args_field"
            `Quick
            test_typed_deterministic_retry_marker_requires_retry_same_args_field
        ] )
    ; ( "classify_path_check"
      , [ Alcotest.test_case
            "path_outside_sandbox_via_block"
            `Quick
            test_path_outside_sandbox_via_path_check_block
        ; Alcotest.test_case "cwd_not_directory" `Quick test_cwd_not_directory
        ] )
    ; ( "classify_workflow_rejection"
      , [ Alcotest.test_case
            "failure_class_only_observed"
            `Quick
            test_workflow_rejection_failure_class_only_is_observed
        ; Alcotest.test_case
            "plain_error_code_observed"
            `Quick
            test_workflow_rejection_plain_error_code_is_observed
        ; Alcotest.test_case
            "explicit_deterministic_top_level"
            `Quick
            test_workflow_rejection_explicit_deterministic
        ; Alcotest.test_case
            "failure_class_under_detail"
            `Quick
            test_workflow_rejection_nested_under_detail
        ] )
    ; ( "classify_git_markers"
      , [ Alcotest.test_case
            "retired_git_precondition_marker_observed_only"
            `Quick
            test_retired_git_precondition_marker_is_observed_only
        ; Alcotest.test_case
            "plain_git_exit_128_observed_only"
            `Quick
            test_plain_git_exit_128_is_observed_only
        ] )
    ; ( "negative_transient"
      , [ Alcotest.test_case
            "shell_exit_nonzero"
            `Quick
            test_shell_exit_nonzero_is_transient
        ; Alcotest.test_case
            "wrong_arguments_label"
            `Quick
            test_wrong_arguments_is_transient
        ; Alcotest.test_case
            "circuit_breaker_marker"
            `Quick
            test_circuit_breaker_marker_is_transient
        ; Alcotest.test_case
            "transient_failure_class"
            `Quick
            test_transient_failure_class_is_not_deterministic
        ; Alcotest.test_case "invalid_json" `Quick test_invalid_json_returns_none
        ; Alcotest.test_case "empty_payload" `Quick test_empty_payload_returns_none
        ; Alcotest.test_case
            "unknown_error_code"
            `Quick
            test_unknown_error_code_returns_none
        ] )
    ; ( "shell_ir_approval_queue"
      , [ Alcotest.test_case
            "overlay_resolves_live_and_invalid_fails_closed"
            `Quick
            test_shell_ir_approval_overlay_resolves_live
        ; Alcotest.test_case
            "gh_capability_requires_approval_enqueues_pending_without_wait"
            `Quick
            test_gh_approval_pending_helper_enqueues_nonblocking
        ; Alcotest.test_case
            "gh_capability_resolution_does_not_install_retry_grant"
            `Quick
            test_gh_approval_resolution_does_not_install_retry_grant
        ] )
    ; ( "telemetry_key_invariants"
      , [ Alcotest.test_case "key_format" `Quick test_telemetry_key_format
        ; Alcotest.test_case
            "to_string_non_empty"
            `Quick
            test_to_string_non_empty_for_every_variant
        ] )
    ]
;;
