(** Unit tests for {!Masc_exec.Shell_ir_validator}.  RFC-0092 PR-1.

    These tests pin the typed-advisor contract before any production
    caller exists (Phase A wiring is PR-2).  Coverage axes:

    - Parsed simple command, bin in allowlist → [Allow]
    - Parsed simple command, bin outside allowlist → [Reject
      Command_not_in_allowlist]
    - Parsed pipeline, every segment in allowlist → [Allow]
    - Parsed pipeline, one segment outside → [Reject
      Pipeline_segment_disallowed]
    - Parse failure variants → [Cannot_parse] with the right kind *)

module V = Masc_mcp.Shell_ir_validator

let dev_allowlist = [ "ls"; "cat"; "rg"; "git"; "wc" ]

let test_allow_simple_in_allowlist () =
  match V.advise ~cmd:"ls" ~allowlist:dev_allowlist with
  | V.Allow -> ()
  | other -> Alcotest.failf "expected Allow, got %s" (V.advisory_tag other)
;;

let test_allow_simple_with_args () =
  match V.advise ~cmd:"ls -la /tmp" ~allowlist:dev_allowlist with
  | V.Allow -> ()
  | other -> Alcotest.failf "expected Allow, got %s" (V.advisory_tag other)
;;

let test_reject_simple_outside_allowlist () =
  match V.advise ~cmd:"foo" ~allowlist:dev_allowlist with
  | V.Reject { reason = V.Command_not_in_allowlist "foo"; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Reject Command_not_in_allowlist foo, got %s"
      (V.advisory_tag other)
;;

let test_allow_pipeline_all_in_allowlist () =
  match V.advise ~cmd:"ls | wc -l" ~allowlist:dev_allowlist with
  | V.Allow -> ()
  | other -> Alcotest.failf "expected Allow, got %s" (V.advisory_tag other)
;;

let test_reject_pipeline_one_segment_outside () =
  match V.advise ~cmd:"ls | foo" ~allowlist:dev_allowlist with
  | V.Reject { reason = V.Pipeline_segment_disallowed "foo"; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Reject Pipeline_segment_disallowed foo, got %s"
      (V.advisory_tag other)
;;

let is_cannot_parse = function
  | V.Cannot_parse _ -> true
  | _ -> false
;;

let test_cannot_parse_empty_command () =
  let result = V.advise ~cmd:"" ~allowlist:dev_allowlist in
  Alcotest.(check bool)
    "empty command surfaces as Cannot_parse"
    true
    (is_cannot_parse result)
;;

let test_cannot_parse_shell_chain () =
  (* `a && b` is outside the bash_subset grammar — must surface as
     Cannot_parse, never silently Allow. *)
  let result = V.advise ~cmd:"ls && rm -rf /" ~allowlist:dev_allowlist in
  Alcotest.(check bool)
    "shell chain surfaces as Cannot_parse"
    true
    (is_cannot_parse result)
;;

let test_advisory_tag_stable () =
  Alcotest.(check string) "allow tag" "allow" (V.advisory_tag V.Allow);
  Alcotest.(check string)
    "reject tag"
    "reject"
    (V.advisory_tag
       (V.Reject
          { reason = V.Command_not_in_allowlist "x"; diagnostic = "x" }));
  Alcotest.(check string)
    "cannot_parse tag"
    "cannot_parse"
    (V.advisory_tag (V.Cannot_parse { kind = V.Parse_error }))
;;

let test_cannot_parse_kind_tag_pinned () =
  (* Pin every wording: dashboards greppable on these literals.  Any
     new variant added to Parsed.reason_too_complex / reason_aborted
     forces an exhaustive-match update in cannot_parse_kind_tag so
     this test does not have to enumerate the new arm to catch the
     regression — the compile-time failure does. *)
  let cases =
    [ "parse_error", V.Parse_error
    ; "timeout", V.Parse_aborted `Timeout_50ms
    ; "depth_limit", V.Parse_aborted `Depth_limit
    ; "token_limit", V.Parse_aborted `Token_limit_50k
    ; "heredoc", V.Too_complex `Heredoc
    ; "here_string", V.Too_complex `Here_string
    ; "cmd_subst", V.Too_complex `Cmd_subst
    ; "proc_subst", V.Too_complex `Proc_subst
    ; "subshell", V.Too_complex `Subshell
    ; "arith_expansion", V.Too_complex `Arith_expansion
    ; "control_flow", V.Too_complex `Control_flow
    ; "logic_op", V.Too_complex `Logic_op
    ; "function_def", V.Too_complex `Function_def
    ; "glob_brace", V.Too_complex `Glob_brace
    ; "background", V.Too_complex `Background
    ; "redirect", V.Too_complex `Redirect
    ; "other", V.Too_complex (`Unknown_construct "future_thing")
    ]
  in
  List.iter
    (fun (expected, kind) ->
      Alcotest.(check string)
        (Printf.sprintf "%s tag" expected)
        expected
        (V.cannot_parse_kind_tag kind))
    cases
;;

let test_reject_reason_tag_pinned () =
  Alcotest.(check string)
    "command tag"
    "command"
    (V.reject_reason_tag (V.Command_not_in_allowlist "x"));
  Alcotest.(check string)
    "pipeline_segment tag"
    "pipeline_segment"
    (V.reject_reason_tag (V.Pipeline_segment_disallowed "x"))
;;

let test_sub_tag_constant_under_binary_variation () =
  (* Reject-reason sub-tag must be CONSTANT across different
     offending binaries — the metric label is a fixed bucket name,
     not a per-command string.  Pin by computing the tag for two
     distinct bin names and asserting equality (plus equality to the
     pinned literal). *)
  let a = V.reject_reason_tag (V.Command_not_in_allowlist "rm") in
  let b = V.reject_reason_tag (V.Command_not_in_allowlist "curl") in
  Alcotest.(check string) "command tag a = pinned" "command" a;
  Alcotest.(check string) "command tag b = pinned" "command" b;
  let p1 =
    V.reject_reason_tag (V.Pipeline_segment_disallowed "rm")
  in
  let p2 =
    V.reject_reason_tag (V.Pipeline_segment_disallowed "curl")
  in
  Alcotest.(check string) "pipeline tag p1 = pinned" "pipeline_segment" p1;
  Alcotest.(check string) "pipeline tag p2 = pinned" "pipeline_segment" p2
;;

let test_empty_allowlist_rejects_known_bin () =
  (* Empty allowlist must reject any simple command — the allowlist is
     the only allow source; an empty list means deny all. *)
  match V.advise ~cmd:"ls" ~allowlist:[] with
  | V.Reject { reason = V.Command_not_in_allowlist "ls"; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Reject Command_not_in_allowlist ls, got %s"
      (V.advisory_tag other)
;;

let () =
  Alcotest.run
    "shell_ir_validator"
    [ ( "allow"
      , [ Alcotest.test_case "simple in allowlist" `Quick test_allow_simple_in_allowlist
        ; Alcotest.test_case "simple with args" `Quick test_allow_simple_with_args
        ; Alcotest.test_case
            "pipeline all in allowlist"
            `Quick
            test_allow_pipeline_all_in_allowlist
        ] )
    ; ( "reject"
      , [ Alcotest.test_case
            "simple outside allowlist"
            `Quick
            test_reject_simple_outside_allowlist
        ; Alcotest.test_case
            "pipeline one segment outside"
            `Quick
            test_reject_pipeline_one_segment_outside
        ; Alcotest.test_case
            "empty allowlist rejects known bin"
            `Quick
            test_empty_allowlist_rejects_known_bin
        ] )
    ; ( "cannot_parse"
      , [ Alcotest.test_case
            "empty command"
            `Quick
            test_cannot_parse_empty_command
        ; Alcotest.test_case
            "shell chain"
            `Quick
            test_cannot_parse_shell_chain
        ] )
    ; ( "advisory_tag"
      , [ Alcotest.test_case "stable wording" `Quick test_advisory_tag_stable ]
      )
    ; ( "sub_tags"
      , [ Alcotest.test_case
            "cannot_parse_kind_tag pinned"
            `Quick
            test_cannot_parse_kind_tag_pinned
        ; Alcotest.test_case
            "reject_reason_tag pinned"
            `Quick
            test_reject_reason_tag_pinned
        ; Alcotest.test_case
            "sub tag constant under binary variation"
            `Quick
            test_sub_tag_constant_under_binary_variation
        ] )
    ]
;;
