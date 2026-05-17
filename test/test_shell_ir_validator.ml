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
    ]
;;
