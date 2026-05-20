(** Regression guard for [Keeper_exec_shell.readonly_hint_of_category].

    The prior form only named the blocked category; small-LLM keepers
    then retried the same chaining/redirect command. 2026-04-17/18 logs
    in <base-path>/.masc/tool_calls showed 57 command_blocked_readonly
    rejections with no wire-level rewrite. Each active category now
    carries an explicit Good:/Bad: example; this test locks that in. *)

module Shell = Masc_mcp.Keeper_exec_shell
module Worker = Masc_mcp.Worker_dev_tools

let contains needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec scan i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else scan (i + 1)
  in
  scan 0

let check_example category =
  let hint = Shell.readonly_hint_of_category category in
  Alcotest.(check bool)
    (Printf.sprintf "%s hint contains Good:" category)
    true
    (contains "Good:" hint);
  Alcotest.(check bool)
    (Printf.sprintf "%s hint contains Bad:" category)
    true
    (contains "Bad:" hint);
  List.iter
    (fun internal_name ->
       Alcotest.(check bool)
         (Printf.sprintf "%s hint avoids %s" category internal_name)
         false
         (contains internal_name hint))
    [ "keeper_bash"; "keeper_shell"; "keeper_fs_edit" ]

let test_all_named_categories_carry_examples () =
  List.iter check_example
    [ "chaining"; "redirect"; "git_write"; "package_install"; "destructive" ]

let test_unknown_category_falls_back () =
  let hint = Shell.readonly_hint_of_category "not_a_real_category" in
  Alcotest.(check bool) "fallback does not claim Good:/Bad:" false
    (contains "Good:" hint)

let tool_suggestion_of_diagnosis = function
  | None -> None
  | Some diagnosis -> diagnosis.Masc_mcp.Exec_core.tool_suggestion

let test_block_reason_diagnoses_use_public_tool_suggestions () =
  Alcotest.(check (option string))
    "direct dune suggests public Bash"
    (Some "Bash")
    (tool_suggestion_of_diagnosis
       (Shell.diagnosis_of_block_reason Worker.Direct_dune_invocation));
  Alcotest.(check (option string))
    "unsafe redirect suggests public Write"
    (Some "Write")
    (tool_suggestion_of_diagnosis
       (Shell.diagnosis_of_block_reason Worker.Unsafe_redirect));
  Alcotest.(check (option string))
    "unknown command does not suggest internal shell"
    None
    (tool_suggestion_of_diagnosis
       (Shell.diagnosis_of_block_reason (Worker.Command_not_allowed "foo")))

let () =
  Alcotest.run "keeper_readonly_hints" [
    ("Good:/Bad: examples",
     [ Alcotest.test_case "all named categories" `Quick
         test_all_named_categories_carry_examples
     ; Alcotest.test_case "unknown category fallback" `Quick
         test_unknown_category_falls_back
     ; Alcotest.test_case "block reason suggestions are public" `Quick
         test_block_reason_diagnoses_use_public_tool_suggestions
     ])
  ]
