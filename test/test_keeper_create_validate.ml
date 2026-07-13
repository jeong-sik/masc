(** test_keeper_create_validate — [validate_resolved_keeper_create_json] is the
    single pre-boot gate on the live [masc_keeper_create_from_persona] path
    (wired for both [dry_run] previews and real creates). Pins the gate's
    contract so the deletion of the unreachable Keeper_persona duplicate
    cannot silently drop validation. *)

open Masc

(* Minimal substring check, stdlib-only. *)
let contains ~affix s =
  let n = String.length affix and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = affix || go (i + 1)) in
  n = 0 || go 0

let validate = Keeper_tool_persona_runtime.validate_resolved_keeper_create_json

let test_missing_goal_and_mentions () =
  let errors = validate (`Assoc [ ("name", `String "valid-name") ]) in
  Alcotest.(check bool)
    "goal error present" true
    (List.exists (contains ~affix:"goal is required") errors);
  Alcotest.(check bool)
    "mention_targets error present" true
    (List.exists (contains ~affix:"mention_targets is required") errors)

let test_complete_args_pass () =
  let errors =
    validate
      (`Assoc
         [
           ("name", `String "valid-name");
           ("goal", `String "do the thing");
           ("mention_targets", `List [ `String "valid-name" ]);
         ])
  in
  Alcotest.(check (list string)) "no errors" [] errors

let test_invalid_name_rejected () =
  let errors =
    validate
      (`Assoc
         [
           ("name", `String "bad name/with sep");
           ("goal", `String "g");
           ("mention_targets", `List [ `String "x" ]);
         ])
  in
  Alcotest.(check bool)
    "name error present" true
    (List.exists (contains ~affix:"invalid keeper name") errors)

let () =
  Alcotest.run "keeper_create_validate"
    [
      ( "gate",
        [
          Alcotest.test_case "missing goal and mention_targets are rejected"
            `Quick test_missing_goal_and_mentions;
          Alcotest.test_case "complete resolved args pass" `Quick
            test_complete_args_pass;
          Alcotest.test_case "invalid keeper name is rejected" `Quick
            test_invalid_name_rejected;
        ] );
    ]
