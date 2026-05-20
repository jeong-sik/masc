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
module Owne = Masc_mcp.Keeper_turn_driver

let check_completion_contract_class label cls_opt =
  match cls_opt with
  | Some KT.Completion_contract_violation -> ()
  | Some other ->
      let other_str = KT.blocker_class_to_string other in
      fail (Printf.sprintf "%s mapped to %s, expected Completion_contract_violation"
              label other_str)
  | None ->
      fail (Printf.sprintf "%s returned None, expected Completion_contract_violation" label)

let check_capacity_class label cls_opt =
  match cls_opt with
  | Some KT.Capacity_exhausted -> ()
  | Some other ->
      let other_str = KT.blocker_class_to_string other in
      fail
        (Printf.sprintf
           "%s mapped to %s, expected Capacity_exhausted"
           label
           other_str)
  | None ->
      fail (Printf.sprintf "%s returned None, expected Capacity_exhausted" label)

let check_cascade_class label cls_opt =
  match cls_opt with
  | Some (KT.Cascade_exhausted _) -> ()
  | Some other ->
      let other_str = KT.blocker_class_to_string other in
      fail
        (Printf.sprintf
           "%s mapped to %s, expected Cascade_exhausted"
           label
           other_str)
  | None ->
      fail (Printf.sprintf "%s returned None, expected Cascade_exhausted" label)

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

let test_turn_livelock_text_maps () =
  match
    B.blocker_class_of_string
      "keeper turn livelock blocked: attempts_exhausted attempts=3 max_attempts=3"
  with
  | Some KT.Turn_livelock_blocked -> ()
  | Some other ->
      fail ("turn livelock mapped to " ^ KT.blocker_class_to_string other)
  | None -> fail "turn livelock returned None"

let test_capacity_backpressure_text_maps () =
  check_capacity_class
    "capacity-exhausted text"
    (B.blocker_class_of_string
       "Internal error: [masc_oas_error] {\"kind\":\"capacity_exhausted\",\
        \"detail\":\"client capacity key glm is full\"}")

let test_legacy_cascade_slot_full_text_stays_cascade_exhausted () =
  check_cascade_class
    "legacy cascade slot-full text"
    (B.blocker_class_of_string
       "Internal error: [masc_oas_error] {\"kind\":\"cascade_exhausted\",\
        \"reason\":{\"tag\":\"other_detail\",\"message\":\"slot full, cascading \
        to next provider\"}}")

let test_capacity_backpressure_sdk_error_maps () =
  let err =
    Owne.sdk_error_of_masc_internal_error
      (Owne.Capacity_backpressure
         {
           cascade_name = Owne.cascade_name_of_string "strict_tool_candidates";
           source = Owne.Client_capacity;
           detail = "client capacity key glm is full";
           retry_after_sec = None;
         })
  in
  check_capacity_class "typed capacity structured SDK error"
    (B.blocker_class_of_sdk_error err)

let test_capacity_backpressure_runtime_surface_preserves_legacy_cascade_class () =
  let surface =
    B.runtime_blocker_surface_of_typed_class
      ~summary:"slot full, cascading to next provider"
      (KT.Cascade_exhausted (KT.Other_detail "cascade_exhausted"))
  in
  check string "runtime blocker class" "cascade_exhausted"
    surface.blocker_class
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
          test_case "turn livelock text maps" `Quick test_turn_livelock_text_maps;
          test_case "legacy cascade slot-full text stays cascade_exhausted" `Quick
            test_legacy_cascade_slot_full_text_stays_cascade_exhausted;
          test_case "capacity backpressure text maps" `Quick
            test_capacity_backpressure_text_maps;
          test_case "capacity backpressure SDK error maps" `Quick
            test_capacity_backpressure_sdk_error_maps;
          test_case "capacity backpressure runtime surface preserves legacy cascade class" `Quick
            test_capacity_backpressure_runtime_surface_preserves_legacy_cascade_class;
        ] );
    ]
