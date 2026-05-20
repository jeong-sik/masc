module Gate = Masc_mcp.Shell_command_gate

let allowed = [ "rg"; "sort"; "head"; "wc"; "cat" ]

let check_stage_bins label expected context =
  Alcotest.(check (list string)) label expected context.Gate.stage_bins
;;

let test_parse_three_stage_pipeline () =
  match Gate.parse "rg foo lib | sort | head -20" with
  | Error kind ->
    Alcotest.failf "expected parsed pipeline, got %s" (Gate.cannot_parse_kind_tag kind)
  | Ok context ->
    Alcotest.(check int) "stage count" 3 (Gate.stage_count context);
    check_stage_bins "stage bins" [ "rg"; "sort"; "head" ] context;
    Alcotest.(check (option string)) "last stage" (Some "head") (Gate.last_stage_bin context);
    (match context.Gate.shape with
     | Gate.Pipeline { stages = 3 } -> ()
     | Gate.Simple -> Alcotest.fail "expected pipeline shape"
     | Gate.Pipeline { stages } -> Alcotest.failf "expected 3 stages, got %d" stages)
;;

let test_quoted_pipe_stays_inside_argument () =
  match Gate.parse "rg 'foo|bar' lib | head -20" with
  | Error kind ->
    Alcotest.failf "expected parsed pipeline, got %s" (Gate.cannot_parse_kind_tag kind)
  | Ok context ->
    Alcotest.(check int) "stage count" 2 (Gate.stage_count context);
    check_stage_bins "stage bins" [ "rg"; "head" ] context
;;

let test_quoted_pipe_single_stage () =
  match Gate.validate_allowlist ~allowed_commands:allowed "rg 'foo|bar' lib" with
  | Gate.Allow context ->
    Alcotest.(check int) "stage count" 1 (Gate.stage_count context);
    check_stage_bins "stage bins" [ "rg" ] context
  | other -> Alcotest.failf "expected Allow, got %s" (Gate.decision_tag other)
;;

let test_rejects_disallowed_pipeline_stage_with_index () =
  match Gate.validate_allowlist ~allowed_commands:allowed "rg foo | sed s/a/b/ | head -20" with
  | Gate.Reject { reason = Gate.Pipeline_segment_disallowed { stage = 2; bin = "sed" }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected stage 2 sed rejection, got %s"
      (Gate.decision_tag other)
;;

let test_rejects_pipes_when_disabled () =
  match
    Gate.validate_allowlist ~allow_pipes:false ~allowed_commands:allowed "rg foo | head -20"
  with
  | Gate.Reject { reason = Gate.Pipes_not_allowed { stages = 2 }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Pipes_not_allowed rejection, got %s"
      (Gate.decision_tag other)
;;

let test_too_complex_shell_chain () =
  match Gate.validate_allowlist ~allowed_commands:allowed "rg foo && head file" with
  | Gate.Cannot_parse { kind = Gate.Too_complex `Logic_op } -> ()
  | other ->
    Alcotest.failf "expected Too_complex Logic_op, got %s" (Gate.decision_tag other)
;;

(* RFC-0131 PR-1a — caller partition tag.  The optional [?caller] does
   not affect the verdict; these tests pin (a) backward compatibility
   when omitted, (b) every variant tags distinctly, (c) the parse and
   validate paths both accept the new arg. *)

let test_caller_tag_round_trip () =
  Alcotest.(check string) "worker tag" "worker_dev_tools" (Gate.caller_tag Worker_dev_tools);
  Alcotest.(check string) "code_write tag" "tool_code_write" (Gate.caller_tag Tool_code_write);
  Alcotest.(check string)
    "keeper tag"
    "keeper_shell_bash"
    (Gate.caller_tag Keeper_shell_bash)
;;

let test_validate_with_caller_matches_without () =
  let cmd = "rg foo lib | head -20" in
  let without = Gate.validate_allowlist ~allowed_commands:allowed cmd in
  let with_caller =
    Gate.validate_allowlist ~caller:Worker_dev_tools ~allowed_commands:allowed cmd
  in
  Alcotest.(check string)
    "tag identity"
    (Gate.decision_tag without)
    (Gate.decision_tag with_caller);
  match without, with_caller with
  | Gate.Allow w, Gate.Allow c ->
    Alcotest.(check (list string))
      "stage_bins identity"
      w.Gate.stage_bins
      c.Gate.stage_bins
  | _ ->
    Alcotest.failf
      "expected both decisions to be Allow; got %s vs %s"
      (Gate.decision_tag without)
      (Gate.decision_tag with_caller)
;;

let test_parse_with_caller_matches_without () =
  let cmd = "rg foo lib" in
  let without = Gate.parse cmd in
  let with_caller = Gate.parse ~caller:Keeper_shell_bash cmd in
  match without, with_caller with
  | Ok w, Ok c ->
    Alcotest.(check (list string)) "bins identity" w.Gate.stage_bins c.Gate.stage_bins
  | Error wk, Error ck ->
    Alcotest.(check string)
      "kind identity"
      (Gate.cannot_parse_kind_tag wk)
      (Gate.cannot_parse_kind_tag ck)
  | Ok _, Error ck ->
    Alcotest.failf "without=Ok but with_caller=Error %s" (Gate.cannot_parse_kind_tag ck)
  | Error wk, Ok _ ->
    Alcotest.failf "without=Error %s but with_caller=Ok" (Gate.cannot_parse_kind_tag wk)
;;

(* RFC-0131 PR-1b/PR-1c — typed-IR nested pipeline and redirect policy.

   The current bash_subset grammar (see lib/exec/parser/bash.ml's
   [to_shell_ir]) emits non-nested pipelines plus a narrow redirect
   subset: fd-to-fd redirects and explicit /dev/null file redirects.
   General file targets still classify as Too_complex `Redirect. The
   tests below pin both the typed-IR and raw-parser policy boundaries. *)

let mk_bin name =
  match Masc_exec.Bin.of_string name with
  | Error (`Unknown raw) -> Alcotest.failf "Bin.of_string rejected %S as %S" name raw
  | Ok bin -> bin
;;

let mk_simple bin_name : Masc_exec.Shell_ir.simple =
  let bin = mk_bin bin_name in
  { Masc_exec.Shell_ir.bin
  ; args = []
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Masc_exec.Sandbox_target.host ()
  }
;;

let mk_simple_with_file_write bin_name =
  let simple = mk_simple bin_name in
  let target = Masc_exec.Path_scope.classify ~raw:"out.txt" ~cwd:"/tmp" in
  let redirect =
    Masc_exec.Redirect_scope.File { fd = 1; target; mode = Masc_exec.Redirect_scope.Write }
  in
  { simple with redirects = [ redirect ] }
;;

let mk_simple_context s =
  { Gate.ast = Masc_exec.Shell_ir.Simple s
  ; shape = Gate.Simple
  ; stage_bins = [ Masc_exec.Bin.to_string s.Masc_exec.Shell_ir.bin ]
  }
;;

let test_redirect_disallowed_rejects_file_redirect () =
  let s = mk_simple_with_file_write "rg" in
  let ctx = mk_simple_context s in
  match
    Gate.validate_parsed_context
      ~redirect_allowed:false
      ~allowed_commands:[ "rg" ]
      ctx
  with
  | Gate.Reject { reason = Gate.Redirect_disallowed_in_caller { stage_index = 0 }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Redirect_disallowed_in_caller, got %s"
      (Gate.decision_tag other)
;;

let test_redirect_allowed_by_default_admits_file_redirect () =
  let s = mk_simple_with_file_write "rg" in
  let ctx = mk_simple_context s in
  match Gate.validate_parsed_context ~allowed_commands:[ "rg" ] ctx with
  | Gate.Allow _ -> ()
  | other ->
    Alcotest.failf
      "expected Allow with default redirect_allowed=true, got %s"
      (Gate.decision_tag other)
;;

let test_redirect_disallowed_admits_command_without_redirect () =
  let s = mk_simple "rg" in
  let ctx = mk_simple_context s in
  match
    Gate.validate_parsed_context
      ~redirect_allowed:false
      ~allowed_commands:[ "rg" ]
      ctx
  with
  | Gate.Allow _ -> ()
  | other ->
    Alcotest.failf
      "expected Allow when no redirects present, got %s"
      (Gate.decision_tag other)
;;

let test_redirect_disallowed_tag_round_trip () =
  Alcotest.(check string)
    "tag"
    "redirect_disallowed_in_caller"
    (Gate.reject_reason_tag (Gate.Redirect_disallowed_in_caller { stage_index = 0 }))
;;

let test_raw_dev_null_redirect_rejected_when_disabled () =
  match
    Gate.validate_allowlist
      ~redirect_allowed:false
      ~allowed_commands:[ "rg" ]
      "rg foo 2>/dev/null"
  with
  | Gate.Reject { reason = Gate.Redirect_disallowed_in_caller { stage_index = 0 }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected raw /dev/null redirect to obey redirect_allowed=false, got %s"
      (Gate.decision_tag other)
;;

let test_raw_spaced_dev_null_redirect_rejected_when_disabled () =
  match
    Gate.validate_allowlist
      ~redirect_allowed:false
      ~allowed_commands:[ "rg" ]
      "rg foo 2> /dev/null"
  with
  | Gate.Reject { reason = Gate.Redirect_disallowed_in_caller { stage_index = 0 }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected spaced raw /dev/null redirect to obey redirect_allowed=false, got %s"
      (Gate.decision_tag other)
;;

let test_raw_fd_redirect_admitted_when_redirects_disabled () =
  match
    Gate.validate_allowlist
      ~redirect_allowed:false
      ~allowed_commands:[ "ls" ]
      "ls 2>&1"
  with
  | Gate.Allow context ->
    Alcotest.(check int) "stage count" 1 (Gate.stage_count context);
    check_stage_bins "stage bins" [ "ls" ] context
  | other ->
    Alcotest.failf
      "expected fd-to-fd redirect to remain allowed, got %s"
      (Gate.decision_tag other)
;;

let test_validate_allowlist_default_unchanged_with_explicit_true () =
  let without = Gate.validate_allowlist ~allowed_commands:allowed "rg foo lib | head -20" in
  let with_explicit =
    Gate.validate_allowlist ~redirect_allowed:true ~allowed_commands:allowed "rg foo lib | head -20"
  in
  Alcotest.(check string)
    "decision tag identity"
    (Gate.decision_tag without)
    (Gate.decision_tag with_explicit)
;;

let test_typed_input_flat_pipeline_round_trips () =
  let ast =
    Masc_exec.Shell_ir.Pipeline
      [ Masc_exec.Shell_ir.Simple (mk_simple "rg")
      ; Masc_exec.Shell_ir.Simple (mk_simple "head")
      ]
  in
  match Gate.parsed_context_of_shell_ir ast with
  | Ok context ->
    Alcotest.(check int) "stage count" 2 (Gate.stage_count context);
    check_stage_bins "stage bins" [ "rg"; "head" ] context
  | Error kind ->
    Alcotest.failf
      "expected Ok for flat pipeline, got Error %s"
      (Gate.cannot_parse_kind_tag kind)
;;

let test_typed_input_nested_pipeline_rejected () =
  let inner =
    Masc_exec.Shell_ir.Pipeline
      [ Masc_exec.Shell_ir.Simple (mk_simple "sort")
      ; Masc_exec.Shell_ir.Simple (mk_simple "head")
      ]
  in
  let outer = Masc_exec.Shell_ir.Pipeline
    [ Masc_exec.Shell_ir.Simple (mk_simple "rg"); inner ]
  in
  match Gate.parsed_context_of_shell_ir outer with
  | Error (Gate.Unsupported_nested_pipeline { stage_index = 1 }) -> ()
  | Error other ->
    Alcotest.failf
      "expected Unsupported_nested_pipeline at index 1, got %s"
      (Gate.cannot_parse_kind_tag other)
  | Ok context ->
    Alcotest.failf
      "expected Error, got Ok with stage_bins=[%s]"
      (String.concat "; " context.Gate.stage_bins)
;;

let test_unsupported_nested_pipeline_tag () =
  Alcotest.(check string)
    "tag"
    "unsupported_nested_pipeline"
    (Gate.cannot_parse_kind_tag (Gate.Unsupported_nested_pipeline { stage_index = 0 }))
;;

let () =
  Alcotest.run
    "shell_command_gate"
    [ ( "parse"
      , [ Alcotest.test_case "three-stage pipeline" `Quick test_parse_three_stage_pipeline
        ; Alcotest.test_case "quoted pipe in pipeline" `Quick test_quoted_pipe_stays_inside_argument
        ] )
    ; ( "validate"
      , [ Alcotest.test_case "quoted pipe single stage" `Quick test_quoted_pipe_single_stage
        ; Alcotest.test_case
            "disallowed pipeline stage reports index"
            `Quick
            test_rejects_disallowed_pipeline_stage_with_index
        ; Alcotest.test_case "pipes disabled" `Quick test_rejects_pipes_when_disabled
        ; Alcotest.test_case "shell chain is too complex" `Quick test_too_complex_shell_chain
        ] )
    ; ( "caller_partition"
      , [ Alcotest.test_case "caller_tag round trip" `Quick test_caller_tag_round_trip
        ; Alcotest.test_case
            "validate_allowlist with caller matches without"
            `Quick
            test_validate_with_caller_matches_without
        ; Alcotest.test_case
            "parse with caller matches without"
            `Quick
            test_parse_with_caller_matches_without
        ] )
    ; ( "redirect_policy"
      , [ Alcotest.test_case
            "file redirect rejected when ~redirect_allowed:false"
            `Quick
            test_redirect_disallowed_rejects_file_redirect
        ; Alcotest.test_case
            "file redirect admitted by default"
            `Quick
            test_redirect_allowed_by_default_admits_file_redirect
        ; Alcotest.test_case
            "no-redirect command admitted even with ~redirect_allowed:false"
            `Quick
            test_redirect_disallowed_admits_command_without_redirect
        ; Alcotest.test_case
            "tag round trip"
            `Quick
            test_redirect_disallowed_tag_round_trip
        ; Alcotest.test_case
            "raw /dev/null redirect rejected when ~redirect_allowed:false"
            `Quick
            test_raw_dev_null_redirect_rejected_when_disabled
        ; Alcotest.test_case
            "raw spaced /dev/null redirect rejected when ~redirect_allowed:false"
            `Quick
            test_raw_spaced_dev_null_redirect_rejected_when_disabled
        ; Alcotest.test_case
            "raw fd redirect allowed when ~redirect_allowed:false"
            `Quick
            test_raw_fd_redirect_admitted_when_redirects_disabled
        ; Alcotest.test_case
            "default behavior unchanged with explicit ~redirect_allowed:true"
            `Quick
            test_validate_allowlist_default_unchanged_with_explicit_true
        ] )
    ; ( "typed_input"
      , [ Alcotest.test_case
            "flat pipeline round trips"
            `Quick
            test_typed_input_flat_pipeline_round_trips
        ; Alcotest.test_case
            "nested pipeline rejected with stage index"
            `Quick
            test_typed_input_nested_pipeline_rejected
        ; Alcotest.test_case
            "unsupported_nested_pipeline tag"
            `Quick
            test_unsupported_nested_pipeline_tag
        ] )
    ]
;;
