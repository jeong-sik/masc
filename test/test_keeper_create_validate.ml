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

let string_list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List xs) ->
      List.filter_map (function `String s -> Some s | _ -> None) xs
  | _ -> []

let test_initial_goal_injection () =
  (* D-10a transition: injection fills the legacy goal string, links the
     minted goal id (dedup), and the result passes the validate gate. *)
  let base =
    `Assoc
      [
        ("name", `String "valid-name");
        ("goal", `String "");
        ("mention_targets", `List [ `String "valid-name" ]);
        ("active_goal_ids", `List [ `String "goal-existing" ]);
      ]
  in
  let injected =
    Keeper_tool_persona_runtime.resolved_args_with_initial_goal
      ~goal_text:"첫 목표" ~goal_id:"goal-new" base
  in
  (match injected with
   | `Assoc fields ->
       (match List.assoc_opt "goal" fields with
        | Some (`String g) ->
            Alcotest.(check string) "goal filled from initial_goal" "첫 목표" g
        | _ -> Alcotest.fail "goal must be a string");
       Alcotest.(check (list string))
         "goal id linked after existing ids"
         [ "goal-existing"; "goal-new" ]
         (string_list_field fields "active_goal_ids")
   | _ -> Alcotest.fail "injection must return an object");
  Alcotest.(check (list string))
    "injected args pass the gate" [] (validate injected);
  (* Re-injecting the same id must not duplicate it. *)
  let twice =
    Keeper_tool_persona_runtime.resolved_args_with_initial_goal
      ~goal_text:"첫 목표" ~goal_id:"goal-new" injected
  in
  match twice with
  | `Assoc fields ->
      Alcotest.(check (list string))
        "goal id dedup on re-injection"
        [ "goal-existing"; "goal-new" ]
        (string_list_field fields "active_goal_ids")
  | _ -> Alcotest.fail "injection must return an object"

let test_pre_mint_shape_passes_gate () =
  (* Orphan-Goal guard companion (PR #24364 re-review P1-1): the handler now
     validates the goal_text-only injection BEFORE minting the Goal entity,
     so the gate must accept that exact pre-mint shape — no goal id, no
     active_goal_ids. If the gate ever starts requiring a minted id, the
     validate-before-mint ordering breaks and this pins the regression. *)
  let base =
    `Assoc
      [
        ("name", `String "valid-name");
        ("goal", `String "");
        ("mention_targets", `List [ `String "valid-name" ]);
      ]
  in
  let pre_mint =
    Keeper_tool_persona_runtime.resolved_args_with_initial_goal
      ~goal_text:"첫 목표" base
  in
  Alcotest.(check (list string))
    "goal_text-only injection passes the gate" [] (validate pre_mint);
  match pre_mint with
  | `Assoc fields ->
      Alcotest.(check (list string))
        "no goal id linked before the mint" []
        (string_list_field fields "active_goal_ids")
  | _ -> Alcotest.fail "injection must return an object"

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
      ( "initial_goal",
        [
          Alcotest.test_case
            "injection fills goal, links id with dedup, passes gate" `Quick
            test_initial_goal_injection;
          Alcotest.test_case "pre-mint shape (goal_text only) passes gate"
            `Quick test_pre_mint_shape_passes_gate;
        ] );
    ]
