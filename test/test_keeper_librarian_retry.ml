open Alcotest

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types

let fact ~claim_id ~claim : Memory.fact =
  { claim
  ; category = Memory.Fact
  ; claim_kind = Some Memory.Durable_knowledge
  ; source = { trace_id = "trace-current"; turn = 1; tool_call_id = None }
  ; first_seen = 1_000_000.
  ; valid_until = None
  ; last_verified_at = None
  ; schema_version = Memory.schema_version
  ; claim_id = Some claim_id
  }
;;

let current_a = fact ~claim_id:"a" ~claim:"keep A"
let current_b = fact ~claim_id:"b" ~claim:"drop B"

let input () : Librarian.input =
  { trace_id = "trace-selection"
  ; generation = 7
  ; current_facts = [ current_a; current_b ]
  ; messages =
      [ Agent_sdk.Types.make_message
          ~role:Agent_sdk.Types.User
          [ Agent_sdk.Types.Text "new conversation" ]
      ]
  }
;;

let new_claim ?(claim_id = "c") ?(claim = "add C") () =
  `Assoc
    [ Librarian.wire_field_claim, `String claim
    ; Librarian.wire_field_category, `String "fact"
    ; Librarian.wire_field_source_turn, `Int 0
    ; Librarian.wire_field_source_tool_call_id, `Null
    ; Librarian.wire_field_claim_id, `String claim_id
    ; Librarian.wire_field_claim_kind, `String "durable_knowledge"
    ; Librarian.wire_field_valid_for_days, `Null
    ]
;;

let selection_json ?(retained = [ "id:a" ]) ?(new_claims = []) () =
  `Assoc
    [ Librarian.wire_field_summary, `String "small current memory"
    ; Librarian.wire_field_retained_claim_ids
    , `List (List.map (fun id -> `String id) retained)
    ; Librarian.wire_field_new_claims, `List new_claims
    ; Librarian.wire_field_open_items, `List []
    ; Librarian.wire_field_constraints, `List []
    ; Librarian.wire_field_preserved_tool_refs, `List []
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
    check (list string) "retained ids" [ "id:a" ] selection.retained_claim_ids;
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
  (match parse (selection_json ~retained:[ "id:missing" ] ()) with
   | Error (Librarian.Unknown_retained_claim_id "id:missing") -> ()
   | Error error ->
     failf "wrong unknown-id error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "unknown retained id accepted");
  match parse (selection_json ~retained:[ "id:a"; "id:a" ] ()) with
  | Error (Librarian.Duplicate_retained_claim_id "id:a") -> ()
  | Error error ->
    failf "wrong duplicate-id error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "duplicate retained id accepted"
;;

let test_new_claim_cannot_collide_with_retained_identity () =
  match
    parse
      (selection_json
         ~retained:[ "id:a" ]
         ~new_claims:[ new_claim ~claim_id:"a" ~claim:"rewritten A" () ]
         ())
  with
  | Error (Librarian.Duplicate_selected_claim_id "id:a") -> ()
  | Error error ->
    failf "wrong collision error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "retained/new identity collision accepted"
;;

let test_strict_output_boundary () =
  let exact = Yojson.Safe.to_string (selection_json ()) in
  (match Librarian.selection_of_output_result ~now:2_000_000. (input ()) exact with
   | Ok _ -> ()
   | Error error ->
     failf "exact JSON rejected: %s" (Librarian.parse_error_to_string error));
  let wrapped = Yojson.Safe.to_string (`String exact) in
  (match Librarian.selection_of_output_result ~now:2_000_000. (input ()) wrapped with
   | Ok _ -> ()
   | Error error ->
     failf "exact JSON string rejected: %s" (Librarian.parse_error_to_string error));
  match
    Librarian.selection_of_output_result
      ~now:2_000_000.
      (input ())
      ("```json\n" ^ exact ^ "\n```")
  with
  | Error (Librarian.Invalid_json _) -> ()
  | Error error ->
    failf "wrong fenced-output error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "markdown-fenced output accepted"
;;

let test_prompt_contains_exact_current_memory_ids () =
  let variables = Librarian.prompt_variables (input ()) in
  let current_memory = List.assoc "current_memory" variables in
  check bool "contains A identity" true
    (String_util.contains_substring current_memory "\"memory_id\": \"id:a\"");
  check bool "contains B identity" true
    (String_util.contains_substring current_memory "\"memory_id\": \"id:b\"")
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
        ; test_case "strict output boundary" `Quick test_strict_output_boundary
        ; test_case "prompt carries exact ids" `Quick
            test_prompt_contains_exact_current_memory_ids
        ] )
    ; ( "cadence"
      , [ test_case "fresh then periodic" `Quick test_cadence_fresh_then_periodic
        ; test_case "trace rollover is fresh" `Quick
            test_cadence_trace_rollover_is_fresh
        ] )
    ]
;;
