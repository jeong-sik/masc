(** Shell IR Adjacent Surfaces Plan, P9a — contract tests for the
    [Keeper_gh_shared] gh-command parser surface.

    Existing coverage:
    - [test_gh_api_classification] pins [is_gh_api_read_only].
    - [test_keeper_github_read_only] pins
      [is_read_only_with_input ~tool_name:"keeper_shell" ~input] for
      gh subcommand prefixes and api flag combinations.

    Gap closed here: the parser itself — [parse_simple_gh_command],
    [gh_simple_command_of_argv], and the repo-flag helpers
    [gh_simple_command_has_repo_flag] / [gh_simple_command_with_repo_flag]
    have no dedicated tests. P9b will either add typed [gh_args]
    fields to [keeper_shell] or split a dedicated GitHub op into its
    own handler; either path needs this layer locked first, so the
    schema migration is constrained by behavior the tests describe
    rather than by prose intent.

    These tests are intentionally behavior-preserving. They MUST pass
    against current main; a failure here is a regression of the
    documented contract. *)

open Masc_mcp

module Gh = Keeper_gh_shared

(* ---- Helpers ---------------------------------------------------- *)

let argv_t = Alcotest.list Alcotest.string

let parse_error_pp ppf = function
  | Gh.Empty_command -> Format.fprintf ppf "Empty_command"
  | Gh.Unsupported_shell_construct s ->
    Format.fprintf ppf "Unsupported_shell_construct(%s)" s
  | Gh.Unsupported_command_shape s ->
    Format.fprintf ppf "Unsupported_command_shape(%s)" s

let parse_error_eq a b =
  match a, b with
  | Gh.Empty_command, Gh.Empty_command -> true
  | Gh.Unsupported_shell_construct x, Gh.Unsupported_shell_construct y -> x = y
  | Gh.Unsupported_command_shape x, Gh.Unsupported_command_shape y -> x = y
  | _ -> false

let parse_error_t = Alcotest.testable parse_error_pp parse_error_eq

let argv_of = function
  | Ok cmd -> Ok (Gh.gh_simple_command_argv cmd)
  | Error e -> Error e

let argv_result_t = Alcotest.result argv_t parse_error_t

let must_ok_argv label = function
  | Ok cmd -> Gh.gh_simple_command_argv cmd
  | Error e ->
    Alcotest.failf "%s: expected Ok, got Error %a" label parse_error_pp e

(* ---- parse_simple_gh_command ------------------------------------ *)

let test_parse_empty () =
  Alcotest.check argv_result_t "empty string is Empty_command"
    (Error Gh.Empty_command)
    (argv_of (Gh.parse_simple_gh_command ""));
  Alcotest.check argv_result_t "whitespace-only is Empty_command"
    (Error Gh.Empty_command)
    (argv_of (Gh.parse_simple_gh_command "   \t  "))

let test_parse_without_gh_prefix () =
  (* The parser accepts both ["pr list"] and ["gh pr list"]. This is
     load-bearing: callers route through [keeper_shell op=gh cmd="pr
     list"] without re-prefixing. *)
  let argv = must_ok_argv "pr list" (Gh.parse_simple_gh_command "pr list") in
  Alcotest.check argv_t "argv preserves token order" [ "pr"; "list" ] argv

let test_parse_with_gh_prefix () =
  let argv =
    must_ok_argv "gh pr list" (Gh.parse_simple_gh_command "gh pr list")
  in
  Alcotest.check argv_t "leading gh stripped" [ "pr"; "list" ] argv

let test_parse_multi_arg_subcommand () =
  let argv =
    must_ok_argv "pr view 123" (Gh.parse_simple_gh_command "pr view 123")
  in
  Alcotest.check argv_t "three-token argv preserved"
    [ "pr"; "view"; "123" ] argv

let test_parse_quoted_arg_preserved () =
  (* Quoted whitespace stays as a single argv atom. *)
  let argv =
    must_ok_argv "pr create -t \"hello world\""
      (Gh.parse_simple_gh_command "pr create -t \"hello world\"")
  in
  Alcotest.check argv_t "quoted whitespace fuses into one atom"
    [ "pr"; "create"; "-t"; "hello world" ] argv

let test_parse_pipeline_rejected () =
  match Gh.parse_simple_gh_command "pr list | head" with
  | Error (Gh.Unsupported_shell_construct tag) ->
    Alcotest.(check string) "pipeline tag" "pipeline" tag
  | Ok _ -> Alcotest.failf "expected error, got Ok"
  | Error other ->
    Alcotest.failf "expected Unsupported_shell_construct, got %a"
      parse_error_pp other

let test_parse_redirect_rejected () =
  match Gh.parse_simple_gh_command "pr list > out.txt" with
  | Error (Gh.Unsupported_command_shape tag) ->
    Alcotest.(check string) "redirect tag" "redirect" tag
  | Ok _ -> Alcotest.failf "expected error, got Ok"
  | Error other ->
    Alcotest.failf "expected Unsupported_command_shape redirect, got %a"
      parse_error_pp other

let test_parse_logical_op_rejected () =
  (* [&&] is not a simple-command; the parser must refuse to silently
     execute the head and drop the tail. *)
  match Gh.parse_simple_gh_command "pr list && echo done" with
  | Ok _ -> Alcotest.failf "expected error, got Ok"
  | Error _ -> ()

let test_parse_variable_arg_rejected () =
  (* Shell variables in argv must not be silently expanded or dropped
     — they would change the effective gh command at runtime. The
     *which* error tag fires depends on whether [Bash.parse_string]
     refuses [$FOO] outright (parse_error) or admits it as a [Var]
     token that [gh_simple_command_of_simple] then rejects (var_arg).
     Either rejection is acceptable; the contract is just refusal. *)
  match Gh.parse_simple_gh_command "pr list $FOO" with
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "expected refusal, got Ok"

let test_parse_argv_token_order () =
  (* Argument *order* is part of the contract — gh CLI is positional. *)
  let argv =
    must_ok_argv "pr list --limit 5"
      (Gh.parse_simple_gh_command "pr list --limit 5")
  in
  Alcotest.check argv_t "flags follow positional verbs"
    [ "pr"; "list"; "--limit"; "5" ] argv

(* ---- gh_simple_command_of_argv ---------------------------------- *)

let test_of_argv_without_gh () =
  let argv =
    must_ok_argv "of_argv pr list"
      (Gh.gh_simple_command_of_argv [ "pr"; "list" ])
  in
  Alcotest.check argv_t "argv passes through" [ "pr"; "list" ] argv

let test_of_argv_with_gh_stripped () =
  let argv =
    must_ok_argv "of_argv gh pr list"
      (Gh.gh_simple_command_of_argv [ "gh"; "pr"; "list" ])
  in
  Alcotest.check argv_t "leading gh stripped" [ "pr"; "list" ] argv

let test_of_argv_gh_case_insensitive () =
  (* [equals_ci] is the documented predicate for the leading binary. *)
  let argv =
    must_ok_argv "of_argv GH pr list"
      (Gh.gh_simple_command_of_argv [ "GH"; "pr"; "list" ])
  in
  Alcotest.check argv_t "uppercase GH also stripped" [ "pr"; "list" ] argv

let test_of_argv_empty () =
  Alcotest.check argv_result_t "empty argv is Empty_command"
    (Error Gh.Empty_command)
    (argv_of (Gh.gh_simple_command_of_argv []));
  Alcotest.check argv_result_t "argv with only gh is Empty_command"
    (Error Gh.Empty_command)
    (argv_of (Gh.gh_simple_command_of_argv [ "gh" ]))

let test_of_argv_nul_byte_rejected () =
  match Gh.gh_simple_command_of_argv [ "pr"; "list"; "ev\000il" ] with
  | Error (Gh.Unsupported_command_shape tag) ->
    Alcotest.(check string) "nul_arg tag" "nul_arg" tag
  | Ok _ -> Alcotest.failf "expected error, got Ok"
  | Error other ->
    Alcotest.failf "expected Unsupported_command_shape nul_arg, got %a"
      parse_error_pp other

(* ---- Repo-flag helpers ------------------------------------------ *)

let test_has_repo_flag_false_by_default () =
  let cmd =
    match Gh.gh_simple_command_of_argv [ "pr"; "list" ] with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr list"
  in
  Alcotest.(check bool) "no repo flag" false
    (Gh.gh_simple_command_has_repo_flag cmd)

let test_has_repo_flag_long_form () =
  let cmd =
    match
      Gh.gh_simple_command_of_argv [ "pr"; "list"; "--repo"; "owner/name" ]
    with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr list --repo owner/name"
  in
  Alcotest.(check bool) "--repo flag detected" true
    (Gh.gh_simple_command_has_repo_flag cmd)

let test_has_repo_flag_short_form () =
  let cmd =
    match Gh.gh_simple_command_of_argv [ "pr"; "list"; "-R"; "owner/name" ] with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr list -R owner/name"
  in
  Alcotest.(check bool) "-R short flag detected" true
    (Gh.gh_simple_command_has_repo_flag cmd)

let test_with_repo_flag_injects_when_missing () =
  let cmd =
    match Gh.gh_simple_command_of_argv [ "pr"; "list" ] with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr list"
  in
  let rewritten = Gh.gh_simple_command_with_repo_flag ~repo_slug:"o/r" cmd in
  let argv = Gh.gh_simple_command_argv rewritten in
  Alcotest.check argv_t "--repo prepended" [ "--repo"; "o/r"; "pr"; "list" ]
    argv;
  Alcotest.(check bool) "flag visible after injection" true
    (Gh.gh_simple_command_has_repo_flag rewritten)

let test_with_repo_flag_idempotent_under_repeat () =
  let cmd =
    match Gh.gh_simple_command_of_argv [ "pr"; "list" ] with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr list"
  in
  let once = Gh.gh_simple_command_with_repo_flag ~repo_slug:"o/r" cmd in
  let twice = Gh.gh_simple_command_with_repo_flag ~repo_slug:"o/r" once in
  Alcotest.check argv_t "second injection does not duplicate"
    (Gh.gh_simple_command_argv once)
    (Gh.gh_simple_command_argv twice)

let test_with_repo_flag_replaces_existing () =
  let cmd =
    match
      Gh.gh_simple_command_of_argv
        [ "pr"; "list"; "--repo"; "old/owner"; "--limit"; "5" ]
    with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr list --repo old/owner --limit 5"
  in
  let rewritten = Gh.gh_simple_command_with_repo_flag ~repo_slug:"new/owner" cmd in
  let argv = Gh.gh_simple_command_argv rewritten in
  Alcotest.check argv_t "old --repo replaced, --limit kept"
    [ "--repo"; "new/owner"; "pr"; "list"; "--limit"; "5" ] argv

(* ---- render ----------------------------------------------------- *)

let test_render_round_trip_simple () =
  (* Render is for diagnostics; it MUST be quote-safe but it does not
     need to be a strict inverse of parse. The contract is: re-parsing
     the rendered string returns an equivalent argv. *)
  let original_argv = [ "pr"; "create"; "-t"; "hello world" ] in
  let cmd =
    match Gh.gh_simple_command_of_argv original_argv with
    | Ok cmd -> cmd
    | Error _ -> Alcotest.fail "construct pr create -t 'hello world'"
  in
  let rendered = Gh.render_simple_gh_command cmd in
  let reparsed_argv =
    must_ok_argv "render reparse" (Gh.parse_simple_gh_command rendered)
  in
  Alcotest.check argv_t "render → parse round trip preserves argv"
    original_argv reparsed_argv

(* ---- Suite registration ----------------------------------------- *)

let () =
  Alcotest.run "keeper_gh_parser_contract"
    [ ( "parse_simple_gh_command"
      , [ Alcotest.test_case "empty / whitespace" `Quick test_parse_empty
        ; Alcotest.test_case "no gh prefix" `Quick test_parse_without_gh_prefix
        ; Alcotest.test_case "gh prefix stripped" `Quick
            test_parse_with_gh_prefix
        ; Alcotest.test_case "multi-arg subcommand" `Quick
            test_parse_multi_arg_subcommand
        ; Alcotest.test_case "quoted arg single atom" `Quick
            test_parse_quoted_arg_preserved
        ; Alcotest.test_case "pipeline rejected" `Quick
            test_parse_pipeline_rejected
        ; Alcotest.test_case "redirect rejected" `Quick
            test_parse_redirect_rejected
        ; Alcotest.test_case "logical && rejected" `Quick
            test_parse_logical_op_rejected
        ; Alcotest.test_case "var arg rejected" `Quick
            test_parse_variable_arg_rejected
        ; Alcotest.test_case "argv token order preserved" `Quick
            test_parse_argv_token_order
        ] )
    ; ( "gh_simple_command_of_argv"
      , [ Alcotest.test_case "without gh prefix" `Quick
            test_of_argv_without_gh
        ; Alcotest.test_case "with gh prefix stripped" `Quick
            test_of_argv_with_gh_stripped
        ; Alcotest.test_case "GH case insensitive" `Quick
            test_of_argv_gh_case_insensitive
        ; Alcotest.test_case "empty argv" `Quick test_of_argv_empty
        ; Alcotest.test_case "NUL byte rejected" `Quick
            test_of_argv_nul_byte_rejected
        ] )
    ; ( "repo_flag_helpers"
      , [ Alcotest.test_case "absent by default" `Quick
            test_has_repo_flag_false_by_default
        ; Alcotest.test_case "--repo long form" `Quick
            test_has_repo_flag_long_form
        ; Alcotest.test_case "-R short form" `Quick
            test_has_repo_flag_short_form
        ; Alcotest.test_case "with_repo_flag injects" `Quick
            test_with_repo_flag_injects_when_missing
        ; Alcotest.test_case "with_repo_flag idempotent" `Quick
            test_with_repo_flag_idempotent_under_repeat
        ; Alcotest.test_case "with_repo_flag replaces existing" `Quick
            test_with_repo_flag_replaces_existing
        ] )
    ; ( "render"
      , [ Alcotest.test_case "round trip preserves argv" `Quick
            test_render_round_trip_simple
        ] )
    ]
