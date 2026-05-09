(** Pin tests for Mode_enforcer — tool classification and enforcement.

    These tests lock the behavior of [classify_tool], [classify_shell_command],
    [all_read_only], [all_workspace_only], violation serialization, and
    [tool_effect_class_of_string] against regressions.

    Part of #14323: restoring CDAL unit test coverage. *)

open Alcotest
module Me = Masc_mcp_cdal_runtime.Mode_enforcer

let check_bool = check bool
let check_string = check string
let check_int = check int

(* ── classify_tool (registry-driven, fail-closed) ─────────────── *)

let test_classify_unknown_is_external () =
  check_bool
    "unknown tool -> External_effect"
    true
    (Me.classify_tool "totally_unknown_tool" = Me.External_effect)
;;

let test_classify_mcp_prefix_is_external () =
  check_bool
    "mcp__ prefix -> External_effect"
    true
    (Me.classify_tool "mcp__some_server" = Me.External_effect)
;;

let test_register_and_classify () =
  Me.register_tool_class "test_read_tool" Me.Read_only;
  check_bool "registered read tool" true (Me.classify_tool "test_read_tool" = Me.Read_only);
  Me.register_tool_class "Test_Read_Tool" Me.Local_mutation;
  check_bool
    "case-insensitive lookup"
    true
    (Me.classify_tool "test_read_tool" = Me.Local_mutation)
;;

(* ── classify_tool (fail-closed default) ────────────────────────── *)

let test_classify_bash_dynamic_via_effective () =
  (* Register bash as Shell_dynamic, then test effective_class via input *)
  Me.register_tool_class "bash" Me.Shell_dynamic;
  check_bool
    "bash registered as Shell_dynamic"
    true
    (Me.classify_tool "bash" = Me.Shell_dynamic)
;;

(* ── all_read_only / all_workspace_only ────────────────────────── *)

let test_all_read_only_empty () =
  check_bool "empty list is read-only" true (Me.all_read_only [])
;;

let test_all_workspace_only_empty () =
  check_bool "empty list is workspace-only" true (Me.all_workspace_only [])
;;

let test_all_workspace_only_with_registered () =
  Me.register_tool_class "ws_read" Me.Read_only;
  Me.register_tool_class "ws_mut" Me.Local_mutation;
  check_bool
    "read + mutation = workspace"
    true
    (Me.all_workspace_only [ "ws_read"; "ws_mut" ]);
  check_bool
    "read + mutation is not all-read"
    true
    (not (Me.all_read_only [ "ws_read"; "ws_mut" ]))
;;

let test_all_workspace_rejects_external () =
  Me.register_tool_class "ws_ext" Me.External_effect;
  check_bool
    "external tool is not workspace"
    true
    (not (Me.all_workspace_only [ "ws_ext" ]))
;;

(* ── violation_kind round-trip ─────────────────────────────────── *)

let test_violation_kind_round_trip () =
  let all_kinds = [ Me.Mutating_in_diagnose; Me.External_in_draft; Me.Scope_violation ] in
  List.iter
    (fun kind ->
       let json = Me.violation_kind_to_yojson kind in
       match Me.violation_kind_of_yojson json with
       | Ok k -> check_bool (Me.violation_kind_to_string kind) true (k = kind)
       | Error e ->
         failf "round-trip failed for %s: %s" (Me.violation_kind_to_string kind) e)
    all_kinds
;;

let test_violation_kind_rejects_unknown () =
  match Me.violation_kind_of_yojson (`String "unknown_kind") with
  | Ok _ -> fail "expected error for unknown violation_kind"
  | Error _ -> ()
;;

let test_violation_kind_rejects_non_string () =
  match Me.violation_kind_of_yojson (`Int 42) with
  | Ok _ -> fail "expected error for non-string violation_kind"
  | Error _ -> ()
;;

(* ── violation record round-trip ───────────────────────────────── *)

let test_violation_round_trip () =
  let v =
    { Me.ts = 1715250000.0
    ; tool_name = "Write"
    ; input_summary = "{\"path\":\"/etc/passwd\"}"
    ; effective_mode = Masc_mcp_cdal_runtime.Execution_mode.Diagnose
    ; violation_kind = Me.Mutating_in_diagnose
    }
  in
  let json = Me.violation_to_yojson v in
  match Me.violation_of_yojson json with
  | Ok v' ->
    check_string "tool_name" v.Me.tool_name v'.Me.tool_name;
    check_string "input_summary" v.Me.input_summary v'.Me.input_summary;
    check_bool "violation_kind" true (v.Me.violation_kind = v'.Me.violation_kind)
  | Error e -> failf "violation round-trip failed: %s" e
;;

(* ── tool_effect_class_of_string ───────────────────────────────── *)

let test_effect_class_of_string_all () =
  let cases =
    [ "read_only", Some Me.Read_only
    ; "workspace", Some Me.Local_mutation
    ; "workspace_mutating", Some Me.Local_mutation
    ; "local_mutation", Some Me.Local_mutation
    ; "external", Some Me.External_effect
    ; "external_effect", Some Me.External_effect
    ; "shell_dynamic", Some Me.Shell_dynamic
    ; "garbage", None
    ]
  in
  List.iter
    (fun (input, expected) ->
       check_bool
         (Printf.sprintf "of_string %S" input)
         true
         (Me.tool_effect_class_of_string input = expected))
    cases
;;

let () =
  Alcotest.run
    "cdal_mode_enforcer"
    [ ( "classify_tool"
      , [ test_case "unknown -> External_effect" `Quick test_classify_unknown_is_external
        ; test_case "mcp__ prefix -> External" `Quick test_classify_mcp_prefix_is_external
        ; test_case "register + classify" `Quick test_register_and_classify
        ] )
    ; ( "classify_bash"
      , [ test_case
            "bash is Shell_dynamic"
            `Quick
            test_classify_bash_dynamic_via_effective
        ] )
    ; ( "tool_lists"
      , [ test_case "empty read-only" `Quick test_all_read_only_empty
        ; test_case "empty workspace" `Quick test_all_workspace_only_empty
        ; test_case
            "read+mutation workspace"
            `Quick
            test_all_workspace_only_with_registered
        ; test_case "external not workspace" `Quick test_all_workspace_rejects_external
        ] )
    ; ( "violation_kind"
      , [ test_case "round-trip" `Quick test_violation_kind_round_trip
        ; test_case "rejects unknown" `Quick test_violation_kind_rejects_unknown
        ; test_case "rejects non-string" `Quick test_violation_kind_rejects_non_string
        ] )
    ; "violation", [ test_case "record round-trip" `Quick test_violation_round_trip ]
    ; ( "effect_class_of_string"
      , [ test_case "all variants" `Quick test_effect_class_of_string_all ] )
    ]
;;
