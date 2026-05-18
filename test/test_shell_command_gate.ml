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
    ]
;;
