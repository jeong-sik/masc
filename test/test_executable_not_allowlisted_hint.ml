(** RFC-0196 P0 §1 acceptance: descriptor-backed lookup for the "executable
    not in allowlist" hint. Verified indirectly through [pp_validation_error]
    so the private helper stays private (no test-backdoor mli widening).

    The MASC tool hint must:
    - fire on real MASC tool names (e.g. [keeper_tasks_list], [masc_status])
    - NOT fire on misspellings that share the historical prefix
      (e.g. [keeper_foo_xyz_unknown], [masc_unknown_tool])
    - leave the existing shell/mode hints (gh, jq, bash, ...) intact *)

open Masc
module E = Keeper_tool_execute_typed_input

let pp_err err = Format.asprintf "%a" E.pp_validation_error err

let render ~name ~mode =
  pp_err (E.Executable_not_allowlisted { name; mode })

let contains hay needle =
  let nh = String.length hay
  and nn = String.length needle in
  let rec loop i =
    if i + nn > nh
    then false
    else if String.sub hay i nn = needle
    then true
    else loop (i + 1)
  in
  loop 0

let masc_hint_text = "MASC tool names are not shell programs"

let real_keeper_tool_gets_masc_hint () =
  let msg = render ~name:"keeper_tasks_list" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "real keeper tool → MASC hint"
    true
    (contains msg masc_hint_text)

let real_masc_tool_gets_masc_hint () =
  let msg = render ~name:"masc_status" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "real masc tool → MASC hint"
    true
    (contains msg masc_hint_text)

let keeper_prefixed_misspelling_no_masc_hint () =
  let msg = render ~name:"keeper_foo_xyz_unknown" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "keeper_-prefixed unknown name → no MASC hint (RFC-0196: typed, not substring)"
    false
    (contains msg masc_hint_text)

let masc_prefixed_misspelling_no_masc_hint () =
  let msg = render ~name:"masc_unknown_tool_xyz" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "masc_-prefixed unknown name → no MASC hint"
    false
    (contains msg masc_hint_text)

let bare_unrelated_name_no_masc_hint () =
  let msg = render ~name:"keeperish" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "unrelated name not in descriptor-backed surface → no MASC hint"
    false
    (contains msg masc_hint_text)

let gh_in_readonly_keeps_existing_hint () =
  let msg = render ~name:"gh" ~mode:E.Readonly in
  Alcotest.(check bool)
    "gh in readonly mode still emits read-only hint"
    true
    (contains msg "read-only")

let bash_keeps_existing_hint () =
  let msg = render ~name:"bash" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "bash hint still fires"
    true
    (contains msg "Shell interpreters")

let jq_keeps_existing_hint () =
  let msg = render ~name:"jq" ~mode:E.Dev_full in
  Alcotest.(check bool)
    "jq hint still fires"
    true
    (contains msg "jq is not part of Execute")

let () =
  Alcotest.run "executable_not_allowlisted_hint"
    [ "MASC structured-layer lookup"
    , [ Alcotest.test_case "real keeper tool yields MASC hint" `Quick
          real_keeper_tool_gets_masc_hint
      ; Alcotest.test_case "real masc tool yields MASC hint" `Quick
          real_masc_tool_gets_masc_hint
      ; Alcotest.test_case "keeper_-prefixed misspelling no longer yields MASC hint"
          `Quick keeper_prefixed_misspelling_no_masc_hint
      ; Alcotest.test_case "masc_-prefixed misspelling no longer yields MASC hint"
          `Quick masc_prefixed_misspelling_no_masc_hint
      ; Alcotest.test_case "unrelated name yields no MASC hint" `Quick
          bare_unrelated_name_no_masc_hint
      ]
    ; "Other layer hints remain intact"
    , [ Alcotest.test_case "gh in readonly" `Quick gh_in_readonly_keeps_existing_hint
      ; Alcotest.test_case "bash" `Quick bash_keeps_existing_hint
      ; Alcotest.test_case "jq" `Quick jq_keeps_existing_hint
      ]
    ]
