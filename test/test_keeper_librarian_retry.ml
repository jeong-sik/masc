open Alcotest

module Librarian = Masc.Keeper_librarian
module Runtime = Masc.Keeper_librarian_runtime
module Memory = Masc.Keeper_memory_os_types
module Budget = Masc.Keeper_memory_os_budget

(* Render tests resolve the real repo templates so template <-> code
   variable drift fails here instead of as a live [Prompt_render_failed]
   (same pattern as test_keeper_prompt_metrics). *)
let has_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/keeper.librarian.current_selection.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())

let () =
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  Masc.Prompt_defaults.init ()

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
  ; persona = "You are the retry-test keeper."
  ; current =
      Some
        { Librarian.facts = [ current_a; current_b ] }
  ; max_recall_fact_bytes = 64 * 1024
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

let dropped_json ?(reason = "superseded by newer state") id =
  `Assoc
    [ Librarian.wire_field_memory_id, `String id
    ; Librarian.wire_field_reason, `String reason
    ]
;;

(* Defaults keep the totality contract satisfied for the default input:
   current = [A; B], retained = [A], so B must carry a drop statement. *)
let selection_json
      ?(retained = [ current_a_id ])
      ?(new_claims = [])
      ?(dropped = [ dropped_json current_b_id ])
      ()
  =
  `Assoc
    [ Librarian.wire_field_retained_memory_ids
    , `List (List.map (fun id -> `String id) retained)
    ; Librarian.wire_field_new_claims, `List new_claims
    ; Librarian.wire_field_dropped, `List dropped
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
    check string "exact retained claim" current_a.claim (List.hd selection.facts).claim;
    check (list string) "drop statement names B"
      [ current_b_id ]
      (List.map
         (fun (d : Memory.dropped_statement) -> d.memory_id)
         selection.dropped);
    check string "drop statement carries the reason"
      "superseded by newer state"
      (List.hd selection.dropped).reason
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

let test_oversized_selection_is_rejected_without_local_truncation () =
  let constrained = { (input ()) with max_recall_fact_bytes = 256 } in
  let json =
    selection_json
      ~retained:[]
      ~new_claims:[ new_claim ~claim:(String.make 512 'x') () ]
      ~dropped:[ dropped_json current_a_id; dropped_json current_b_id ]
      ()
  in
  match
    Librarian.selection_of_json_result ~now:2_000_000. constrained json
  with
  | Error (Librarian.Recall_fact_budget_exceeded { actual_bytes; max_bytes }) ->
    check int "declared budget" 256 max_bytes;
    check bool "exact rendered payload exceeds budget" true (actual_bytes > max_bytes)
  | Error error ->
    failf "wrong budget error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "oversized selection was accepted"
;;

let test_budget_measurement_matches_exact_rendered_utf8_bytes () =
  let facts =
    [ fact ~claim:"plain ASCII"
    ; { (fact ~claim:"한글과 emoji 🧠") with category = Memory.Lesson }
    ]
  in
  let expected = String.length (Budget.render_facts facts) in
  check int "incremental bytes equal rendered bytes" expected (Budget.rendered_bytes facts);
  match Budget.measure ~max_bytes:expected facts with
  | Budget.Fits { actual_bytes; max_bytes } ->
    check int "measured bytes" expected actual_bytes;
    check int "boundary is inclusive" expected max_bytes
  | Budget.Exceeds _ -> fail "exact boundary rejected"
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

let test_new_claim_cannot_recreate_dropped_current_identity () =
  match
    parse
      (selection_json
         ~retained:[]
         ~dropped:[ dropped_json current_a_id; dropped_json current_b_id ]
         ~new_claims:[ new_claim ~claim:"keep A" () ]
         ())
  with
  | Error (Librarian.Duplicate_selected_memory_id identity)
    when String.equal identity current_a_id -> ()
  | Error error ->
    failf
      "wrong dropped-current collision error: %s"
      (Librarian.parse_error_to_string error)
  | Ok _ -> fail "dropped current identity was recreated as a new claim"
;;

let test_totality_rejects_unaccounted_current_id () =
  (match parse (selection_json ~dropped:[] ()) with
   | Error (Librarian.Missing_disposition identity)
     when String.equal identity current_b_id -> ()
   | Error error ->
     failf "wrong totality error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "unaccounted current id accepted");
  match
    parse
      (`Assoc
         [ Librarian.wire_field_retained_memory_ids
         , `List [ `String current_a_id ]
         ; Librarian.wire_field_new_claims, `List []
         ])
  with
  | Error Librarian.Missing_required_fields -> ()
  | Error error ->
    failf
      "wrong missing-dropped-field error: %s"
      (Librarian.parse_error_to_string error)
  | Ok _ -> fail "selection without dropped field accepted"
;;

let test_dropped_statements_validate () =
  (match
     parse (selection_json ~dropped:[ dropped_json "missing" ] ())
   with
   | Error (Librarian.Unknown_dropped_memory_id "missing") -> ()
   | Error error ->
     failf "wrong unknown-dropped error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "unknown dropped id accepted");
  (match
     parse
       (selection_json
          ~dropped:[ dropped_json current_b_id; dropped_json current_b_id ]
          ())
   with
   | Error (Librarian.Duplicate_dropped_memory_id identity)
     when String.equal identity current_b_id -> ()
   | Error error ->
     failf "wrong duplicate-dropped error: %s" (Librarian.parse_error_to_string error)
   | Ok _ -> fail "duplicate dropped id accepted");
  (match
     parse
       (selection_json
          ~dropped:[ dropped_json current_a_id; dropped_json current_b_id ]
          ())
   with
   | Error (Librarian.Dropped_memory_id_also_retained identity)
     when String.equal identity current_a_id -> ()
   | Error error ->
     failf "wrong dropped-retained overlap error: %s"
       (Librarian.parse_error_to_string error)
   | Ok _ -> fail "dropped id overlapping retained accepted");
  match
    parse
      (selection_json ~dropped:[ dropped_json ~reason:"  " current_b_id ] ())
  with
  | Error Librarian.Dropped_schema_mismatch -> ()
  | Error error ->
    failf "wrong blank-reason error: %s" (Librarian.parse_error_to_string error)
  | Ok _ -> fail "blank drop reason accepted"
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

let test_prompt_carries_persona () =
  let variables = Librarian.prompt_variables (input ()) in
  check string "persona is the resolved text"
    "You are the retry-test keeper."
    (List.assoc "persona" variables);
  let blank = { (input ()) with persona = " \n \t " } in
  check string "blank persona renders an explicit marker"
    "[no persona]"
    (List.assoc "persona" (Librarian.prompt_variables blank))
;;

let user_text_of_messages messages =
  messages
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
    if m.role = Agent_sdk.Types.User
    then
      Some
        (m.content
         |> List.filter_map (function
           | Agent_sdk.Types.Text s -> Some s
           | Agent_sdk.Types.ToolResult _ | Agent_sdk.Types.ToolUse _
           | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.ReasoningDetails _
           | Agent_sdk.Types.RedactedThinking _ | Agent_sdk.Types.Image _
           | Agent_sdk.Types.Document _ | Agent_sdk.Types.Audio _ -> None)
         |> String.concat "\n")
    else None)
  |> String.concat "\n"
;;

let test_prompt_carries_recall_fact_byte_budget () =
  let constrained = { (input ()) with max_recall_fact_bytes = 12_345 } in
  check string "budget variable is exact"
    "12345"
    (List.assoc
       "max_recall_fact_bytes"
       (Librarian.prompt_variables constrained));
  match Runtime.messages_for_librarian constrained with
  | Error detail -> failf "librarian render failed: %s" detail
  | Ok messages ->
    check bool "rendered prompt states the capacity" true
      (String_util.contains_substring
         (user_text_of_messages messages)
         "within 12345 UTF-8 bytes")
;;

(* The constraint category is scoped to rules something outside the agent
   applies. Measured on the live workspace 2026-08-05: excluding taskmaster,
   12 of 25 stored facts were category constraint, and five of those were the
   agent's own scope decisions -- "unclaimed implementation tasks are outside
   the code-reviewer's scope and should be ignored", "only intervening when
   directly mentioned", "does not autonomously claim backlog tasks". None was
   set by an operator; each was a turn's operating judgment promoted to a
   permanent boundary, and the same backlog held 56 cancelled tasks that no
   keeper had claimed. The externally-enforced ones (a PR-title regex, a
   review bot blocking on contrast ratio, a hook blocking commits to main) are
   what the category is for and still qualify. *)
let test_constraint_category_excludes_self_imposed_scope () =
  match Runtime.messages_for_librarian (input ()) with
  | Error detail -> failf "librarian render failed: %s" detail
  | Ok messages ->
    let user_text = user_text_of_messages messages in
    check bool "constraint is defined as externally enforced" true
      (String_util.contains_substring user_text
         "a rule enforced from outside this agent");
    check bool "external enforcement is the test" true
      (String_util.contains_substring user_text
         "something other than the agent applies it");
    check bool "self-scope decisions are excluded from the category" true
      (String_util.contains_substring user_text
         "An agent's own choice about what it will or will not take on is NOT a constraint");
    check bool "the excluded shapes are named" true
      (String_util.contains_substring user_text
         "do not claim unassigned work");
    check bool "narrowing one's own scope is not stored" true
      (String_util.contains_substring user_text
         "Do not store what the agent decided to stop doing, stay out of, or wait for");
    (* Narrowing the category alone would only gate new claims: the retention
       criteria ask whether a stored fact is still true and important, and
       "unclaimed tasks are outside my scope" passes all four. The five
       self-imposed constraints already in the live stores would then never
       leave. Retention has to re-apply the category rules for the fix to reach
       the existing rows. *)
    check bool "category rules re-apply to stored memories" true
      (String_util.contains_substring user_text
         "Apply the category criteria below to existing memories too");
    check bool "already being stored is not a reason to retain" true
      (String_util.contains_substring user_text
         "does not earn retention by already being there");
    check bool "stored self-scope constraints are dropped" true
      (String_util.contains_substring user_text
         "drop a stored `constraint` that no external rule enforces")
;;

let test_repo_template_renders_persona () =
  (match Runtime.messages_for_librarian (input ()) with
   | Error detail -> failf "librarian render failed: %s" detail
   | Ok messages ->
     let user_text = user_text_of_messages messages in
     check bool "persona section header present" true
       (String_util.contains_substring user_text
          "Persona of the agent whose memory you curate:");
     check bool "persona text present" true
       (String_util.contains_substring user_text
          "You are the retry-test keeper."));
  match
    Runtime.messages_for_librarian { (input ()) with persona = "" }
  with
  | Error detail -> failf "blank-persona render failed: %s" detail
  | Ok messages ->
    check bool "blank persona renders explicit marker" true
      (String_util.contains_substring
         (user_text_of_messages messages)
         "[no persona]")
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
        ; test_case
            "oversized selection rejects without truncation"
            `Quick
            test_oversized_selection_is_rejected_without_local_truncation
        ; test_case
            "incremental budget equals rendered UTF-8 bytes"
            `Quick
            test_budget_measurement_matches_exact_rendered_utf8_bytes
        ; test_case "unknown and duplicate retained reject" `Quick
            test_unknown_and_duplicate_retained_ids_reject
        ; test_case "retained/new collision rejects" `Quick
            test_new_claim_cannot_collide_with_retained_identity
        ; test_case "dropped/new recreation rejects" `Quick
            test_new_claim_cannot_recreate_dropped_current_identity
        ; test_case "totality rejects unaccounted id" `Quick
            test_totality_rejects_unaccounted_current_id
        ; test_case "dropped statements validate" `Quick
            test_dropped_statements_validate
        ; test_case "strict JSON boundary" `Quick test_strict_json_boundary
        ; test_case "duplicate object fields reject" `Quick
            test_duplicate_object_fields_reject
        ; test_case "removed contract fields reject" `Quick
            test_removed_contract_fields_reject
        ; test_case "prompt carries exact current selection" `Quick
            test_prompt_contains_exact_current_selection
        ; test_case "prompt carries persona" `Quick
            test_prompt_carries_persona
        ; test_case "prompt carries recall byte budget" `Quick
            test_prompt_carries_recall_fact_byte_budget
        ; test_case "repo template renders persona" `Quick
            test_repo_template_renders_persona
        ; test_case "constraint category excludes self-imposed scope" `Quick
            test_constraint_category_excludes_self_imposed_scope
        ] )
    ; ( "cadence"
      , [ test_case "fresh then periodic" `Quick test_cadence_fresh_then_periodic
        ; test_case "trace rollover is fresh" `Quick
            test_cadence_trace_rollover_is_fresh
        ] )
    ]
;;
