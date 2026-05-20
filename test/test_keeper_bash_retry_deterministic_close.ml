(** Unit tests for [Keeper_tool_deterministic_error.classify].

    These tests exercise the closed-set classifier without bringing up
    the full keeper_tools_oas / Eio scheduler. The integration test
    that asserts the retry-counter jump lives in
    [test_keeper_tools_oas_retry_skipped.ml] once the surrounding
    fixtures stabilise; this file pins the classifier contract.

    Background: MASC/OAS Error-Warn Reduction Goal 2026-05-18 P2
    reducer. *)

module D = Masc_mcp.Keeper_tool_deterministic_error

let reason_testable =
  let pp ppf reason = Format.pp_print_string ppf (D.to_telemetry_key reason) in
  Alcotest.testable pp ( = )
;;

let check_classify ~name ~expected raw =
  Alcotest.check
    Alcotest.(option reason_testable)
    name
    expected
    (D.classify_raw raw)
;;

(* ── Deterministic — error code path ──────────────────────────── *)

let test_command_blocked () =
  let raw =
    {|{"ok":false,"error":"command_blocked","reason":"Shell injection syntax blocked"}|}
  in
  check_classify
    ~name:"command_blocked"
    ~expected:(Some D.Command_blocked)
    raw
;;

let test_command_shape_blocked () =
  let raw =
    {|{"ok":false,"error":"keeper_bash_command_shape_blocked","reason":"pipes blocked"}|}
  in
  check_classify
    ~name:"keeper_bash_command_shape_blocked"
    ~expected:(Some D.Command_shape_blocked)
    raw
;;

let test_task_state_file_probe_blocked () =
  let raw =
    {|{"ok":false,"error":"task_state_file_probe_blocked","reason":"Do not inspect task files"}|}
  in
  check_classify
    ~name:"task_state_file_probe_blocked"
    ~expected:(Some D.Task_state_probe_blocked)
    raw
;;

let test_destructive_operation_blocked () =
  let raw =
    {|{"ok":false,"error":"destructive_operation_blocked","reason":"rm -rf"}|}
  in
  check_classify
    ~name:"destructive_operation_blocked"
    ~expected:(Some D.Destructive_operation_blocked)
    raw
;;

let test_policy_blocked () =
  let raw = {|{"ok":false,"error":"policy_blocked"}|} in
  check_classify ~name:"policy_blocked" ~expected:(Some D.Policy_blocked) raw
;;

let test_policy_blocked_gh_irreversible () =
  let raw =
    {|{"ok":false,"error":"gh_irreversible_blocked","reason":"gh pr merge"}|}
  in
  check_classify
    ~name:"gh_irreversible_blocked"
    ~expected:(Some D.Policy_blocked)
    raw
;;

let test_completion_contract_violation () =
  let raw =
    {|{"ok":false,"error":"completion_contract_violation","detail":"require_tool_use"}|}
  in
  check_classify
    ~name:"completion_contract_violation"
    ~expected:(Some D.Completion_contract_violation)
    raw
;;

let test_keeper_shell_op_required () =
  let raw = {|{"ok":false,"error":"keeper_shell_bash_deprecated"}|} in
  check_classify
    ~name:"keeper_shell_bash_deprecated"
    ~expected:(Some D.Keeper_shell_op_required)
    raw
;;

(* ── Deterministic — path-check path ──────────────────────────── *)

let test_path_syntax_blocked_explicit () =
  let raw =
    {|{"ok":false,"error":"path_syntax_blocked","path":"/etc/shadow"}|}
  in
  check_classify
    ~name:"path_syntax_blocked"
    ~expected:(Some D.Path_syntax_blocked)
    raw
;;

let test_path_outside_sandbox_via_path_check_block () =
  let raw =
    {|{"ok":false,"error":"keeper_bash_blocked","path_check":{"reason":"path_outside_sandbox"}}|}
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

let test_workflow_rejection_failure_class () =
  let raw =
    {|{"ok":false,"error":"some_rule","failure_class":"workflow_rejection"}|}
  in
  check_classify
    ~name:"failure_class=workflow_rejection"
    ~expected:(Some D.Workflow_rejection_blocked)
    raw
;;

let test_workflow_rejection_nested_under_detail () =
  let raw =
    {|{"ok":false,"detail":{"failure_class":"workflow_rejection"}}|}
  in
  check_classify
    ~name:"detail.failure_class=workflow_rejection"
    ~expected:(Some D.Workflow_rejection_blocked)
    raw
;;

(* ── Deterministic — git exit 128 precondition/usage errors ───── *)

let test_git_diff_no_merge_base_is_deterministic () =
  let raw =
    {|{"status":"error","exit_code":128,"output":"fatal: main...keeper-verifier-agent/task-259: no merge base\n","command":"git diff main...keeper-verifier-agent/task-259","agent":"keeper-verifier-agent"}|}
  in
  check_classify
    ~name:"git diff no merge base"
    ~expected:(Some D.Git_ref_precondition_failed)
    raw
;;

let test_git_diff_unknown_revision_is_deterministic () =
  let raw =
    {|{"status":"error","exit_code":128,"output":"fatal: ambiguous argument 'origin/main...keeper-verifier-agent/task-314': unknown revision or path not in the working tree.\n","command":"git diff origin/main...keeper-verifier-agent/task-314","agent":"keeper-verifier-agent"}|}
  in
  check_classify
    ~name:"git diff unknown revision"
    ~expected:(Some D.Git_ref_precondition_failed)
    raw
;;

let test_git_unrecognized_argument_is_deterministic () =
  let raw =
    {|{"status":"error","exit_code":128,"output":"fatal: unrecognized argument: --no-stat\n","command":"git show f2f396316 --no-stat","agent":"keeper-analyst-agent"}|}
  in
  check_classify
    ~name:"git unrecognized argument"
    ~expected:(Some D.Git_command_usage_error)
    raw
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
    ; D.Path_syntax_blocked
    ; D.Path_outside_sandbox
    ; D.Cwd_not_directory
    ; D.Policy_blocked
    ; D.Completion_contract_violation
    ; D.Keeper_shell_op_required
    ; D.Workflow_rejection_blocked
    ; D.Git_ref_precondition_failed
    ; D.Git_command_usage_error
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

let () =
  Alcotest.run
    "keeper_bash_retry_deterministic_close"
    [ ( "classify_error_code"
      , [ Alcotest.test_case "command_blocked" `Quick test_command_blocked
        ; Alcotest.test_case
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
            "completion_contract_violation"
            `Quick
            test_completion_contract_violation
        ; Alcotest.test_case
            "keeper_shell_op_required"
            `Quick
            test_keeper_shell_op_required
        ] )
    ; ( "classify_path_check"
      , [ Alcotest.test_case
            "path_syntax_blocked"
            `Quick
            test_path_syntax_blocked_explicit
        ; Alcotest.test_case
            "path_outside_sandbox_via_block"
            `Quick
            test_path_outside_sandbox_via_path_check_block
        ; Alcotest.test_case "cwd_not_directory" `Quick test_cwd_not_directory
        ] )
    ; ( "classify_workflow_rejection"
      , [ Alcotest.test_case
            "failure_class_top_level"
            `Quick
            test_workflow_rejection_failure_class
        ; Alcotest.test_case
            "failure_class_under_detail"
            `Quick
            test_workflow_rejection_nested_under_detail
        ] )
    ; ( "classify_git_exit_128"
      , [ Alcotest.test_case
            "git_diff_no_merge_base"
            `Quick
            test_git_diff_no_merge_base_is_deterministic
        ; Alcotest.test_case
            "git_diff_unknown_revision"
            `Quick
            test_git_diff_unknown_revision_is_deterministic
        ; Alcotest.test_case
            "git_unrecognized_argument"
            `Quick
            test_git_unrecognized_argument_is_deterministic
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
    ; ( "telemetry_key_invariants"
      , [ Alcotest.test_case "key_format" `Quick test_telemetry_key_format
        ; Alcotest.test_case
            "to_string_non_empty"
            `Quick
            test_to_string_non_empty_for_every_variant
        ] )
    ]
;;
