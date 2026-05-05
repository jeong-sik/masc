(** 2026-05-05 — pin that [Keeper_status_bridge.blocker_class_of_string]
    maps the [require_tool_use] completion contract violation message
    (text-stamped to runtime.last_blocker by SDK error path) to the
    [Completion_contract_violation] enum variant.

    Pre-fix bug: 4/14 production keepers had
    [last_blocker = "Completion contract [require_tool_use] violated: …"]
    but [last_blocker_class = null], causing the dashboard "차단된 키퍼"
    card and Prometheus blocker-class series to silently drop this
    failure mode.  Variant existed in [Keeper_types.blocker_class] but
    the bridge had no mapping. *)

open Alcotest
module KT = Masc_mcp.Keeper_types
module B = Masc_mcp.Keeper_status_bridge

let check_completion_contract_class label cls_opt =
  match cls_opt with
  | Some KT.Completion_contract_violation -> ()
  | Some other ->
      let other_str = KT.blocker_class_to_string other in
      fail (Printf.sprintf "%s mapped to %s, expected Completion_contract_violation"
              label other_str)
  | None ->
      fail (Printf.sprintf "%s returned None, expected Completion_contract_violation" label)

let test_completion_contract_text_maps () =
  let msg = "Completion contract [require_tool_use] violated: actionable \
             keeper signal was present, but the model used \
             keeper_stay_silent without typed no-work proof: \
             keeper_stay_silent, keeper_tasks_list, keeper_board_list" in
  check_completion_contract_class "require_tool_use full text"
    (B.blocker_class_of_string msg)

let test_completion_contract_short_text_maps () =
  let msg = "completion contract violated" in
  check_completion_contract_class "short lower-case form"
    (B.blocker_class_of_string msg)

let test_completion_contract_mixed_case_maps () =
  let msg = "COMPLETION CONTRACT [require_tool_use] VIOLATED" in
  check_completion_contract_class "upper-case form"
    (B.blocker_class_of_string msg)

let test_unrelated_text_returns_none () =
  let msg = "some other unrelated keeper failure text" in
  match B.blocker_class_of_string msg with
  | None -> ()
  | Some cls ->
      let s = KT.blocker_class_to_string cls in
      fail ("unrelated text mapped to " ^ s ^ ", expected None")

let test_empty_text_returns_none () =
  match B.blocker_class_of_string "" with
  | None -> ()
  | Some _ -> fail "empty string should return None"

let test_existing_mappings_unchanged () =
  (* Regression guard: adding the new arm must not perturb earlier branches. *)
  match B.blocker_class_of_string "turn wall-clock timeout exceeded" with
  | Some KT.Turn_timeout -> ()
  | Some other ->
      fail ("turn wall-clock timeout mapped to " ^ KT.blocker_class_to_string other)
  | None -> fail "turn wall-clock timeout returned None"

let () =
  run "keeper_blocker_class_completion_contract"
    [
      ( "require_tool_use → Completion_contract_violation",
        [
          test_case "full SDK error text" `Quick
            test_completion_contract_text_maps;
          test_case "short lower-case form" `Quick
            test_completion_contract_short_text_maps;
          test_case "upper-case form" `Quick
            test_completion_contract_mixed_case_maps;
        ] );
      ( "negative cases",
        [
          test_case "unrelated text returns None" `Quick
            test_unrelated_text_returns_none;
          test_case "empty text returns None" `Quick
            test_empty_text_returns_none;
        ] );
      ( "regression guard",
        [
          test_case "existing turn-timeout mapping unchanged" `Quick
            test_existing_mappings_unchanged;
        ] );
    ]
