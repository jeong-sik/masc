(** Regression guard for [Tool_task.completion_rejection_message].

    2026-04-17/18 ~/me/.masc/tool_calls showed 37 completion rejects
    where the keeper retried the same perfunctory notes because the
    rejection text said only "describe actual work". The message must
    now always embed [completion_notes_example] so small-LLM keepers
    see the expected density. See #8688. *)

module TT = Masc_mcp.Tool_task

let contains needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec scan i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else scan (i + 1)
  in
  scan 0

let test_message_includes_example () =
  let msg = TT.completion_rejection_message "verdict text" in
  Alcotest.(check bool) "rejection msg includes example" true
    (contains TT.completion_notes_example msg);
  Alcotest.(check bool) "rejection msg keeps reason" true
    (contains "verdict text" msg)

let test_allow_force_variant_includes_example () =
  let msg = TT.completion_rejection_message ~allow_force:true "verdict text" in
  Alcotest.(check bool) "force variant includes example" true
    (contains TT.completion_notes_example msg);
  Alcotest.(check bool) "force variant keeps force hint" true
    (contains "force=true" msg)

let test_example_nonempty () =
  Alcotest.(check bool) "example is nontrivial" true
    (String.length TT.completion_notes_example > 40)

let () =
  Alcotest.run "tool_task_completion_example" [
    ("completion_rejection_message",
     [ Alcotest.test_case "plain variant embeds example" `Quick
         test_message_includes_example
     ; Alcotest.test_case "force variant embeds example" `Quick
         test_allow_force_variant_includes_example
     ; Alcotest.test_case "example string is substantive" `Quick
         test_example_nonempty
     ])
  ]
