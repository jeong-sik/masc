(** Unit tests for [Keeper_path_check_error].

    These tests pin the *exact byte-level* form of the rendered
    messages so any future emitter change is forced to update both
    the typed variant and any downstream consumer that matched on
    those bytes (e.g. dashboard tool-quality prefix rules). *)

open Masc_mcp.Keeper_path_check_error

let test_path_syntax_blocked_no_hint () =
  let msg = to_message (Path_syntax_blocked { token = "/tmp/foo"; hint = None }) in
  Alcotest.(check string)
    "syntax_blocked: byte-equivalent to legacy emit"
    "Path syntax blocked: shell quoting, globbing, brace expansion, and \
     backslash escapes are not allowed for path-bearing keeper commands. \
     Use plain unquoted paths and explicit cwd."
    msg
;;

let test_path_syntax_blocked_with_hint () =
  let msg =
    to_message
      (Path_syntax_blocked { token = "/tmp/foo"; hint = Some "Remove backslash escape." })
  in
  Alcotest.(check string)
    "syntax_blocked: appends hint with single space separator"
    "Path syntax blocked: shell quoting, globbing, brace expansion, and \
     backslash escapes are not allowed for path-bearing keeper commands. \
     Use plain unquoted paths and explicit cwd. Remove backslash escape."
    msg
;;

let test_path_outside_whitelist_keeper_command () =
  let msg =
    to_message
      (Path_outside_whitelist { path = "/etc/passwd"; for_keeper_command = true })
  in
  Alcotest.(check string)
    "outside_whitelist (keeper command): byte-equivalent"
    "Path blocked: /etc/passwd (outside allowed directories for this keeper command)"
    msg
;;

let test_path_outside_whitelist_generic () =
  let msg =
    to_message
      (Path_outside_whitelist { path = "/etc/passwd"; for_keeper_command = false })
  in
  Alcotest.(check string)
    "outside_whitelist (generic): byte-equivalent"
    "Path blocked: /etc/passwd (outside allowed directories)"
    msg
;;

let test_cwd_not_directory_no_hint () =
  let msg = to_message (Cwd_not_directory { path = ".worktrees/keeper-foo"; hint = None }) in
  Alcotest.(check string)
    "cwd_not_directory: byte-equivalent to legacy emit"
    "cwd_not_directory: .worktrees/keeper-foo (directory does not exist under \
     cwd; create or repair the sandbox repo/worktree first)"
    msg
;;

let test_parse_roundtrip_variants () =
  let cases =
    [ Path_syntax_blocked { token = "x"; hint = None }
    ; Path_outside_whitelist { path = "x"; for_keeper_command = true }
    ; Path_outside_whitelist { path = "x"; for_keeper_command = false }
    ; Cwd_not_directory { path = "x"; hint = None }
    ]
  in
  List.iter
    (fun original ->
      let msg = to_message original in
      match parse_prefix msg with
      | None ->
        Alcotest.failf "parse_prefix returned None for emitted message %S" msg
      | Some parsed ->
        let parsed_prefix = message_prefix parsed in
        let original_prefix = message_prefix original in
        Alcotest.(check string)
          (Printf.sprintf "prefix roundtrip for %s" original_prefix)
          original_prefix
          parsed_prefix)
    cases
;;

let test_parse_prefix_rejects_unrelated () =
  Alcotest.(check bool)
    "parse_prefix returns None for unrelated tool error"
    true
    (parse_prefix "some other tool error" = None)
;;

let test_message_prefix_is_lowercase_prefix_of_message () =
  let variants =
    [ Path_syntax_blocked { token = "x"; hint = None }
    ; Path_outside_whitelist { path = "x"; for_keeper_command = true }
    ; Path_outside_whitelist { path = "x"; for_keeper_command = false }
    ; Cwd_not_directory { path = "x"; hint = None }
    ]
  in
  List.iter
    (fun v ->
      let msg = to_message v in
      let pfx = message_prefix v in
      let lowered = String.lowercase_ascii msg in
      Alcotest.(check bool)
        (Printf.sprintf "message_prefix %S is a starts_with-prefix of lowered message" pfx)
        true
        (String.length lowered >= String.length pfx
         && String.sub lowered 0 (String.length pfx) = pfx))
    variants
;;

let () =
  Alcotest.run
    "keeper_path_check_error"
    [ ( "to_message"
      , [ Alcotest.test_case "path_syntax_blocked no hint" `Quick test_path_syntax_blocked_no_hint
        ; Alcotest.test_case
            "path_syntax_blocked with hint"
            `Quick
            test_path_syntax_blocked_with_hint
        ; Alcotest.test_case
            "path_outside_whitelist keeper_command"
            `Quick
            test_path_outside_whitelist_keeper_command
        ; Alcotest.test_case
            "path_outside_whitelist generic"
            `Quick
            test_path_outside_whitelist_generic
        ; Alcotest.test_case
            "cwd_not_directory no hint"
            `Quick
            test_cwd_not_directory_no_hint
        ] )
    ; ( "parse_prefix"
      , [ Alcotest.test_case "roundtrip variants" `Quick test_parse_roundtrip_variants
        ; Alcotest.test_case "rejects unrelated" `Quick test_parse_prefix_rejects_unrelated
        ] )
    ; ( "message_prefix"
      , [ Alcotest.test_case
            "is lowercase prefix of message"
            `Quick
            test_message_prefix_is_lowercase_prefix_of_message
        ] )
    ]
;;
