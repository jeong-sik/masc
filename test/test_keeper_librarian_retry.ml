open Alcotest

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types

let fact ~claim : Memory.fact =
  { claim
  ; category = Memory.Fact
  ; first_seen = 1_000_000.
  }
;;

let current_a = fact ~claim:"keep A"
let current_b = fact ~claim:"drop B"
let current_a_id = Memory.memory_id current_a
let current_b_id = Memory.memory_id current_b

let input () : Librarian.input =
  { turn_ref =
      Ids.Turn_ref.make
        ~trace_id:"trace-selection"
        ~absolute_turn:7
  ; generation = 7
  ; current =
      Some
        { Librarian.facts = [ current_a; current_b ] }
  ; messages =
      [ Agent_sdk.Types.make_message
          ~role:Agent_sdk.Types.User
          [ Agent_sdk.Types.Text "new conversation" ]
      ]
  }
;;

let new_claim ?(claim = "add C") () =
  `Assoc
    [ Librarian.wire_field_claim, `String claim
    ; Librarian.wire_field_category, `String "fact"
    ]
;;

let selection_json ?(retained = [ current_a_id ]) ?(new_claims = []) () =
  `Assoc
    [ Librarian.wire_field_retained_memory_ids
    , `List (List.map (fun id -> `String id) retained)
    ; Librarian.wire_field_new_claims, `List new_claims
    ]
;;

let parse json =
  Librarian.selection_of_json_result ~now:2_000_000. (input ()) json
;;

let test_omission_deletes_and_retention_preserves_exact_fact () =
  match parse (selection_json ()) with
  | Error error ->
    failf "selection rejected: %s" (Librarian.parse_error_to_string error)
  | Ok selection ->
    check (list string) "retained ids" [ current_a_id ] selection.retained_memory_ids;
    check int "one fact remains" 1 (List.length selection.facts);
    check string "exact retained claim" current_a.claim (List.hd selection.facts).claim
;;

let test_new_claim_is_materialized_after_retained_facts () =
  match parse (selection_json ~new_claims:[ new_claim () ] ()) with
  | Error error ->
    failf "selection rejected: %s" (Librarian.parse_error_to_string error)
  | Ok selection ->
    check (list string) "retained then new"
      [ "keep A"; "add C" ]
      (List.map (fun (fact : Memory.fact) -> fact.claim) selection.facts)
;;

let test_unknown_and_duplicate_retained_ids_reject () =
  (match parse (selection_json ~retained:[ "missing" ] ()) with
   | Error (Librarian.Unknown_retained_memory_id "missing") -> ()
   | Error error ->
     failf "wrong unknown-id error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "unknown retained id accepted");
  match parse (selection_json ~retained:[ current_a_id; current_a_id ] ()) with
  | Error (Librarian.Duplicate_retained_memory_id identity)
    when String.equal identity current_a_id -> ()
  | Error error ->
    failf "wrong duplicate-id error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "duplicate retained id accepted"
;;

let test_new_claim_cannot_collide_with_retained_identity () =
  match
    parse
      (selection_json
         ~retained:[ current_a_id ]
         ~new_claims:[ new_claim ~claim:"keep A" () ]
         ())
  with
  | Error (Librarian.Duplicate_selected_memory_id identity)
    when String.equal identity current_a_id -> ()
  | Error error ->
    failf "wrong collision error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "retained/new identity collision accepted"
;;

let test_new_claim_cannot_recreate_omitted_current_identity () =
  match
    parse
      (selection_json
         ~retained:[]
         ~new_claims:[ new_claim ~claim:"keep A" () ]
         ())
  with
  | Error (Librarian.Duplicate_selected_memory_id identity)
    when String.equal identity current_a_id -> ()
  | Error error ->
    failf
      "wrong omitted-current collision error: %s"
      (Librarian.parse_error_to_string error)
  | Ok _ -> fail "omitted current identity was recreated as a new claim"
;;

let test_strict_json_boundary () =
  (match parse (selection_json ()) with
   | Ok _ -> ()
   | Error error ->
     failf "exact JSON rejected: %s" (Librarian.parse_error_to_string error));
  match parse (`String (Yojson.Safe.to_string (selection_json ()))) with
  | Error Librarian.Top_level_not_object -> ()
  | Error error ->
    failf "wrong string-wrapper error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "string-wrapped JSON accepted"
;;

let test_duplicate_object_fields_reject () =
  let duplicate_top =
    match selection_json () with
    | `Assoc fields ->
      `Assoc
        (( Librarian.wire_field_retained_memory_ids
         , `List [ `String current_a_id ] )
         :: fields)
    | _ -> assert false
  in
  (match parse duplicate_top with
   | Error (Librarian.Duplicate_field field)
     when String.equal field Librarian.wire_field_retained_memory_ids -> ()
   | Error error ->
     failf "wrong duplicate top-level error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "duplicate top-level field accepted");
  let duplicate_claim =
    match new_claim () with
    | `Assoc fields ->
      `Assoc ((Librarian.wire_field_claim, `String "duplicate") :: fields)
    | _ -> assert false
  in
  match parse (selection_json ~new_claims:[ duplicate_claim ] ()) with
  | Error (Librarian.Duplicate_field field)
    when String.equal field Librarian.wire_field_claim -> ()
  | Error error ->
    failf "wrong duplicate claim error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "duplicate claim field accepted"
;;

let test_removed_contract_fields_reject () =
  let with_removed_claim_field =
    match new_claim () with
    | `Assoc fields -> `Assoc (("claim_id", `String "retired") :: fields)
    | _ -> assert false
  in
  (match parse (selection_json ~new_claims:[ with_removed_claim_field ] ()) with
   | Error (Librarian.Unexpected_field "claim_id") -> ()
   | Error error ->
     failf "wrong removed claim-field error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "removed claim_id field accepted");
  List.iter
    (fun (field, value) ->
       let with_removed_top_field =
         match selection_json () with
         | `Assoc fields -> `Assoc ((field, value) :: fields)
         | _ -> assert false
       in
       match parse with_removed_top_field with
       | Error (Librarian.Unexpected_field observed)
         when String.equal observed field -> ()
       | Error error ->
         failf
           "wrong removed top-field error for %s: %s"
           field
           (Librarian.parse_error_to_string error)
       | Ok _ -> failf "removed top-level field %s accepted" field)
    [ "summary", `String "retired"; "open_items", `List [] ]
;;

let test_prompt_contains_exact_current_selection () =
  let variables = Librarian.prompt_variables (input ()) in
  let current_memory = List.assoc "current_memory" variables in
  check bool "contains A identity" true
    (String_util.contains_substring current_memory ("\"memory_id\": \"" ^ current_a_id ^ "\""));
  check bool "contains B identity" true
    (String_util.contains_substring current_memory ("\"memory_id\": \"" ^ current_b_id ^ "\""));
  check bool "presentation timestamp is not prompt context" false
    (String_util.contains_substring current_memory "first_seen")
;;

let test_cadence_fresh_then_periodic () =
  check (pair int bool) "fresh due"
    (3, true)
    (Runtime.cadence_step ~cadence:3 ~counter:(-1));
  check (pair int bool) "mid-cycle"
    (2, false)
    (Runtime.cadence_step ~cadence:3 ~counter:1);
  check (pair int bool) "threshold due"
    (3, true)
    (Runtime.cadence_step ~cadence:3 ~counter:2)
;;

let test_cadence_trace_rollover_is_fresh () =
  check (pair (pair string int) bool) "same trace advances"
    (("trace-a", 2), false)
    (Runtime.cadence_step_keyed
       ~cadence:3
       ~current_trace:"trace-a"
       ~prior:(Some ("trace-a", 1)));
  check (pair (pair string int) bool) "new trace is due"
    (("trace-b", 3), true)
    (Runtime.cadence_step_keyed
       ~cadence:3
       ~current_trace:"trace-b"
       ~prior:(Some ("trace-a", 1)))
;;

let () =
  Eio_main.run @@ fun _env ->
  run
    "keeper_librarian_current_selection"
    [ ( "selection"
      , [ test_case
            "omission deletes and retain preserves"
            `Quick
            test_omission_deletes_and_retention_preserves_exact_fact
        ; test_case "new claim materialized" `Quick
            test_new_claim_is_materialized_after_retained_facts
        ; test_case "unknown and duplicate retained reject" `Quick
            test_unknown_and_duplicate_retained_ids_reject
        ; test_case "retained/new collision rejects" `Quick
            test_new_claim_cannot_collide_with_retained_identity
        ; test_case "omitted/new recreation rejects" `Quick
            test_new_claim_cannot_recreate_omitted_current_identity
        ; test_case "strict JSON boundary" `Quick test_strict_json_boundary
        ; test_case "duplicate object fields reject" `Quick
            test_duplicate_object_fields_reject
        ; test_case "removed contract fields reject" `Quick
            test_removed_contract_fields_reject
        ; test_case "prompt carries exact current selection" `Quick
            test_prompt_contains_exact_current_selection
        ] )
    ; ( "cadence"
      , [ test_case "fresh then periodic" `Quick test_cadence_fresh_then_periodic
        ; test_case "trace rollover is fresh" `Quick
            test_cadence_trace_rollover_is_fresh
        ] )
    ]
;;
