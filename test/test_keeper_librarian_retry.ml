(* Librarian cadence policy and strict recognition-output parsing
   (typed-harness contract C6, recognition contract masc#26122):
   - cadence: fresh keeper due immediately, then once per period; rollover
     resets; the counter table stays bounded under trace rotation;
   - parsing: exact JSON (or exact JSON-string wrapping) only; markdown
     fences, prose wrapping, schema drift, foreign non-null operation
     fields, and malformed op payloads are all typed rejections. *)

open Alcotest
module R = Masc.Keeper_librarian_runtime
module Lib = Masc.Keeper_librarian
module Recognition = Masc.Keeper_librarian_recognition
module Types = Masc.Keeper_memory_os_types

let field_episode_summary = Lib.wire_field_episode_summary
let field_operations = Lib.wire_field_operations
let field_op = Lib.wire_field_op
let field_fact = Lib.wire_field_fact
let field_index = Lib.wire_field_index
let field_reason = Lib.wire_field_reason
let field_claim = Lib.wire_field_claim
let deprecated_field_confidence = "confidence"
let field_category = Lib.wire_field_category
let field_source_turn = Lib.wire_field_source_turn
let field_valid_for_days = Lib.wire_field_valid_for_days
let field_open_items = Lib.wire_field_open_items
let field_constraints = Lib.wire_field_constraints
let field_preserved_tool_refs = Lib.wire_field_preserved_tool_refs

let claim_json ?confidence ?(claim = "c") ?(source_turn = `Int 0) () =
  let fields =
    [ field_claim, `String claim
    ; field_category, `String "fact"
    ; field_source_turn, source_turn
    ]
  in
  let fields =
    match confidence with
    | None -> fields
    | Some confidence -> (deprecated_field_confidence, confidence) :: fields
  in
  `Assoc fields
;;

let add_op_json ?confidence ?claim ?source_turn () =
  `Assoc [ field_op, `String "add"; field_fact, claim_json ?confidence ?claim ?source_turn () ]
;;

let string_list_json values = `List (List.map (fun value -> `String value) values)

let output_json
      ?(episode_summary = "s")
      ?(operations = [ add_op_json () ])
      ?(open_items = [])
      ?(constraints = [])
      ?(preserved_tool_refs = [])
      ()
  =
  `Assoc
    [ field_episode_summary, `String episode_summary
    ; field_operations, `List operations
    ; field_open_items, string_list_json open_items
    ; field_constraints, string_list_json constraints
    ; field_preserved_tool_refs, string_list_json preserved_tool_refs
    ]
;;

let output_json_string ?episode_summary ?operations ?open_items ?constraints
      ?preserved_tool_refs () =
  output_json ?episode_summary ?operations ?open_items ?constraints ?preserved_tool_refs ()
  |> Yojson.Safe.to_string
;;

let minimal_output_json ?(claim = "c") () =
  output_json_string ~operations:[ add_op_json ~claim () ] ()
;;

(* Drive [cadence_step] sequentially from a fresh keeper (counter -1) for
   [turns] turns, collecting the [due] decision each turn. When a turn is due
   we simulate a successful extraction by resetting the counter to 0, matching
   the behavior of [run_best_effort] calling [cadence_record_success]. *)
let run_cadence ~cadence ~turns =
  let counter = ref (-1) in
  List.init turns (fun _ ->
    let next, due = R.cadence_step ~cadence ~counter:!counter in
    counter := next;
    if due then counter := 0;
    due)

let test_cadence_fresh_then_every_cadence () =
  (* cadence 3: first turn is due immediately, then wait three turns between
     subsequent extractions. *)
  check (list bool) "fresh due immediately, then every third turn"
    [ true; false; false; true; false; false; true; false; false ]
    (run_cadence ~cadence:3 ~turns:9)

let test_cadence_one_always_due () =
  (* cadence 1 (and the floored <=1 case) restores per-turn extraction. *)
  check (list bool) "cadence 1 is due every turn"
    [ true; true; true; true ]
    (run_cadence ~cadence:1 ~turns:4);
  check (pair int bool) "cadence<=1 pins counter at 0"
    (0, true)
    (R.cadence_step ~cadence:1 ~counter:5)

let test_cadence_step_transitions () =
  (* A fresh counter is due immediately and moves to the due threshold. *)
  check (pair int bool) "fresh keeper is due immediately"
    (3, true)
    (R.cadence_step ~cadence:3 ~counter:(-1));
  (* A due threshold stays due until reset by a successful extraction. *)
  check (pair int bool) "due counter stays at threshold"
    (3, true)
    (R.cadence_step ~cadence:3 ~counter:3);
  (* Mid-cycle advances without firing. *)
  check (pair int bool) "mid-cycle advances without firing"
    (2, false)
    (R.cadence_step ~cadence:3 ~counter:1)

let test_cadence_record_success_resets () =
  let kid = "test-cadence-record-success" and tid = "trace-record-success" in
  check bool "fresh (keeper, trace) is due" true
    (R.cadence_due ~keeper_id:kid ~trace_id:tid);
  R.cadence_record_success ~keeper_id:kid ~trace_id:tid;
  check bool "after success the next turn is not due" false
    (R.cadence_due ~keeper_id:kid ~trace_id:tid)

let test_cadence_record_attempt_defers () =
  let kid = "test-cadence-record-attempt" and tid = "trace-record-attempt" in
  check bool "fresh (keeper, trace) is due" true
    (R.cadence_due ~keeper_id:kid ~trace_id:tid);
  R.cadence_record_attempt ~keeper_id:kid ~trace_id:tid;
  check bool "after a completed non-success attempt the next turn is not due" false
    (R.cadence_due ~keeper_id:kid ~trace_id:tid)

(* [cadence_due] drives the real per-(keeper, trace) counter table (the gate
   [run_best_effort] uses). A fresh pair is due immediately, and successful
   structured extractions are due once per configured period. Asserted as
   period-invariants so they hold for any configured cadence. *)
let test_cadence_due_periodic () =
  let kid = "test-cadence-due-periodic" and tid = "trace-periodic" in
  let cadence = R.cadence_turns () in
  let periods = 4 in
  let dues = ref 0 in
  for _ = 1 to cadence * periods do
    if R.cadence_due ~keeper_id:kid ~trace_id:tid
    then (
      incr dues;
      R.cadence_record_success ~keeper_id:kid ~trace_id:tid)
  done;
  check int "exactly one extraction per cadence period" periods !dues

let test_cadence_due_independent_keepers () =
  let cadence = R.cadence_turns () in
  if cadence <= 1
  then () (* cadence 1: both due every turn, independence is trivial *)
  else (
    let ka = "test-cadence-due-ind-a" and ta = "trace-a"
    and kb = "test-cadence-due-ind-b" and tb = "trace-b" in
    (* Put ka into a persistent due state without recording a completed attempt. *)
    ignore (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    (* Put kb at counter 0 by recording success on its fresh due turn. *)
    ignore (R.cadence_due ~keeper_id:kb ~trace_id:tb);
    R.cadence_record_success ~keeper_id:kb ~trace_id:tb;
    (* ka remains due after skipped work; kb is mid-cycle and not due. *)
    check bool "ka stays due after skipped attempt" true
      (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    R.cadence_record_attempt ~keeper_id:ka ~trace_id:ta;
    check bool "ka backs off after completed non-success attempt" false
      (R.cadence_due ~keeper_id:ka ~trace_id:ta);
    check bool "kb advances on its own counter, not due on ka's schedule" false
      (R.cadence_due ~keeper_id:kb ~trace_id:tb))

(* A handoff rollover (a new trace_id for the same keeper) resets the cadence
   schedule in place. The table is keyed by keeper_id, so the rotated trace
   overwrites the keeper's single row rather than minting a new one — the
   previous trace's counter is intentionally not preserved (production never has
   two live traces for one keeper; meta.runtime.trace_id is the single active
   trace and rolls over sequentially). *)
let test_cadence_due_resets_on_trace_rollover () =
  let cadence = R.cadence_turns () in
  if cadence <= 1
  then () (* cadence 1: every turn due, rollover semantics are trivial *)
  else (
    let kid = "test-cadence-rollover" and ta = "trace-a" and tb = "trace-b" in
    (* Advance trace a past its fresh-due turn to a non-due turn. *)
    if R.cadence_due ~keeper_id:kid ~trace_id:ta
    then R.cadence_record_success ~keeper_id:kid ~trace_id:ta;
    check bool "trace a is mid-cycle, not due" false
      (R.cadence_due ~keeper_id:kid ~trace_id:ta);
    (* A new trace (rollover) is fresh and due immediately, overwriting the row. *)
    check bool "rolled-over trace is due immediately" true
      (R.cadence_due ~keeper_id:kid ~trace_id:tb);
    (* Rolling back to trace a is itself a rollover off trace b: fresh, due
       immediately — the old trace-a counter was not retained. *)
    check bool "returning to the prior trace is a fresh rollover, due immediately"
      true
      (R.cadence_due ~keeper_id:kid ~trace_id:ta))

(* Leak regression: the cadence table is keyed by keeper_id, so an unbounded
   number of trace rotations for one keeper must add exactly one row (the
   pre-fix (keeper, trace) keying added one row per rotation and never reclaimed
   it). Measured as a delta so concurrent rows from other tests do not matter. *)
let test_cadence_table_bounded_under_trace_rotation () =
  let kid = "test-cadence-rotation-bound" in
  let before = R.cadence_counter_entries () in
  for i = 1 to 64 do
    ignore (R.cadence_due ~keeper_id:kid ~trace_id:(Printf.sprintf "rot-trace-%d" i))
  done;
  check int "64 trace rotations add exactly one keeper row" 1
    (R.cadence_counter_entries () - before)

(* Pure rollover decision: a stored entry from a different trace, or no entry,
   is fresh (due immediately) and the returned value carries the current trace;
   a matching trace advances the stored counter. *)
let test_cadence_step_keyed () =
  check (pair (pair string int) bool) "unseen keeper is fresh, due, carries trace"
    (("t1", 3), true)
    (R.cadence_step_keyed ~cadence:3 ~current_trace:"t1" ~prior:None);
  check (pair (pair string int) bool) "matching trace advances mid-cycle, not due"
    (("t1", 2), false)
    (R.cadence_step_keyed ~cadence:3 ~current_trace:"t1" ~prior:(Some ("t1", 1)));
  check (pair (pair string int) bool)
    "rotated trace is fresh (due), discards prior counter, carries new trace"
    (("t2", 3), true)
    (R.cadence_step_keyed ~cadence:3 ~current_trace:"t2" ~prior:(Some ("t1", 2)))

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let test_durable_cadence_survives_a_fresh_read () =
  let base_path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "librarian-durable-cadence-%d-%d" (Unix.getpid ())
         (Random.bits ()))
  in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_path with _ -> ())
    (fun () ->
       Unix.mkdir base_path 0o700;
       let keeper_id = "durable-cadence" in
       let trace_id = "trace-a" in
       (match R.durable_cadence_due ~base_path ~keeper_id ~trace_id with
        | Ok true -> ()
        | Ok false -> Alcotest.fail "fresh durable cadence should be due"
        | Error detail -> Alcotest.fail detail);
       (match
          R.durable_cadence_record_completed_attempt ~base_path ~keeper_id ~trace_id
        with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       (match R.durable_cadence_due ~base_path ~keeper_id ~trace_id with
        | Ok due ->
          check bool "persisted reset delays the next provider attempt"
            (R.cadence_turns () <= 1) due
        | Error detail -> Alcotest.fail detail);
       (* A rotated trace must not inherit the previous trace's schedule:
          fresh means due immediately, at any configured cadence. *)
       (match R.durable_cadence_due ~base_path ~keeper_id ~trace_id:"trace-b" with
        | Ok true -> ()
        | Ok false ->
          Alcotest.fail "a new trace should be due immediately, not inherit"
       | Error detail -> Alcotest.fail detail))

let test_failed_cadence_backoff_write_is_surfaced () =
  match
    R.For_testing.persist_cadence_backoff
      ~should_defer:true
      ~write:(fun () -> Error "injected cadence write failure")
  with
  | Error "injected cadence write failure" -> ()
  | Error detail -> failf "unexpected cadence write error: %s" detail
  | Ok deferred ->
    failf
      "failed cadence write was reported as deferred=%b"
      deferred
;;

(* Strict parsing with bounded compatibility for real-world librarian provider
   drift. We accept exact JSON and exact JSON-string wrapping only. Markdown
   fences, prose-wrapped JSON, and embedded JSON must fall into the diagnostic
   fallback path instead of being accepted as a structured recognition output. *)

let stored_fact index : Types.fact =
  { claim = Printf.sprintf "stored-%d" index
  ; category = Types.Fact
  ; claim_kind = None
  ; source = { trace_id = "historical"; turn = index; tool_call_id = None }
  ; observed_by = []
  ; first_seen = Float.of_int index
  ; valid_until = None
  ; last_verified_at = None
  ; schema_version = Types.schema_version
  ; claim_id = None
  ; reinforcement_count = 0
  }
;;

let input ~trace_id : Lib.input =
  { trace_id
  ; generation = 0
  ; messages =
      [ { Agent_sdk.Types.role = Agent_sdk.Types.User
        ; content = [ Agent_sdk.Types.Text "current conversation" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ; { Agent_sdk.Types.role = Agent_sdk.Types.Assistant
        ; content = [ Agent_sdk.Types.Text "current response" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ; { Agent_sdk.Types.role = Agent_sdk.Types.User
        ; content = [ Agent_sdk.Types.Text "follow-up" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ; { Agent_sdk.Types.role = Agent_sdk.Types.Assistant
        ; content = [ Agent_sdk.Types.Text "decision" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ; { Agent_sdk.Types.role = Agent_sdk.Types.User
        ; content = [ Agent_sdk.Types.Text "final" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ]
  ; store = List.init 5 stored_fact
  }
;;

let parse_out raw =
  Lib.recognition_output_of_output_result
    ~now:1_000_000.0
    (input ~trace_id:"tolerant-t")
    raw
;;

let rejects name raw =
  match parse_out raw with
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s should be rejected" name
;;

let test_rejects_markdown_wrapped () =
  rejects "markdown-wrapped JSON" ("```json\n" ^ output_json_string ~operations:[] () ^ "\n```")
;;

let test_rejects_prose_wrapped_json () =
  rejects "prose before JSON" ("Here is the episode you requested:\n" ^ minimal_output_json ());
  rejects "prose after JSON" (minimal_output_json () ^ "\nDone.");
  rejects
    "prose around fenced JSON"
    ("Here is the episode you requested:\n```json\n"
     ^ minimal_output_json ()
     ^ "\n```\nDone.")
;;

let test_parses_json_string_wrapping () =
  let raw = `String (output_json_string ~operations:[] ()) |> Yojson.Safe.to_string in
  match parse_out raw with
  | Ok out ->
    check string "episode_summary" "s" out.Lib.episode_summary;
    check int "operations count" 0 (List.length out.Lib.operations)
  | Error error ->
    Alcotest.failf
      "JSON-string-wrapped object should parse, got %s"
      (Lib.parse_error_to_string error)
;;

let test_rejects_string_source_turn () =
  rejects
    "string source_turn"
    (output_json_string
       ~operations:[ add_op_json ~source_turn:(`String "3") () ]
       ())
;;

let expect_unexpected_field field raw =
  match parse_out raw with
  | Error (Lib.Unexpected_field got) -> check string "unexpected field" field got
  | Error error ->
    Alcotest.failf
      "expected Unexpected_field %s, got %s"
      field
      (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.failf "expected Unexpected_field %s" field
;;

let test_rejects_unexpected_episode_field () =
  let raw =
    `Assoc
      [ field_episode_summary, `String "s"
      ; field_operations, `List [ add_op_json () ]
      ; field_open_items, `List []
      ; field_constraints, `List []
      ; field_preserved_tool_refs, `List []
      ; "extra_episode_field", `String "drift"
      ]
    |> Yojson.Safe.to_string
  in
  expect_unexpected_field "extra_episode_field" raw
;;

let test_rejects_unexpected_claim_field () =
  let raw =
    output_json_string
      ~operations:[ add_op_json ~confidence:(`Float 0.9) () ]
      ()
  in
  expect_unexpected_field deprecated_field_confidence raw
;;

let test_rejects_foreign_non_null_operation_field () =
  (* An [add] carrying a non-null [index] is model confusion between ops and
     must reject, even though [index] is an accepted operation field. *)
  let raw =
    output_json_string
      ~operations:
        [ `Assoc
            [ field_op, `String "add"
            ; field_fact, claim_json ()
            ; field_index, `Int 2
            ]
        ]
      ()
  in
  match parse_out raw with
  | Error (Lib.Operation_schema_mismatch _) -> ()
  | Error error ->
    Alcotest.failf
      "expected Operation_schema_mismatch, got %s"
      (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "foreign non-null operation field should reject"
;;

let test_rejects_overlapping_operation_targets () =
  let raw =
    output_json_string
      ~operations:
        [ `Assoc
            [ field_op, `String "reinforce"
            ; field_index, `Int 0
            ; field_source_turn, `Int 4
            ]
        ; `Assoc
            [ field_op, `String "forget"
            ; field_index, `Int 0
            ; field_reason, `String "superseded"
            ]
        ]
      ()
  in
  match parse_out raw with
  | Error (Lib.Operation_schema_mismatch _) -> ()
  | Error error ->
    Alcotest.failf
      "expected Operation_schema_mismatch, got %s"
      (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "overlapping operation targets must fail closed"
;;

let test_parses_all_operation_shapes () =
  let raw =
    output_json_string
      ~operations:
        [ add_op_json ~claim:"new knowledge" ()
        ; `Assoc
            [ field_op, `String "reinforce"
            ; field_index, `Int 0
            ; field_source_turn, `Int 4
            ]
        ; `Assoc
            [ field_op, `String "merge"
            ; Lib.wire_field_member_indices, `List [ `Int 1; `Int 2 ]
            ; field_claim, `String "merged claim"
            ; field_category, `String "lesson"
            ; field_source_turn, `Int 4
            ]
        ; `Assoc
            [ field_op, `String "revise"
            ; field_index, `Int 3
            ; field_claim, `String "revised claim"
            ; field_source_turn, `Int 4
            ]
        ; `Assoc
            [ field_op, `String "forget"
            ; field_index, `Int 4
            ; field_reason, `String "superseded"
            ]
        ]
      ()
  in
  match parse_out raw with
  | Error error -> Alcotest.failf "all-op output should parse, got %s" (Lib.parse_error_to_string error)
  | Ok out ->
    let labels = List.map Recognition.operation_label out.Lib.operations in
    check (list string) "operation order and shapes"
      [ "add"; "reinforce"; "merge"; "revise"; "forget" ]
      labels
;;

let test_revise_null_clears_expiry_instead_of_preserving_it () =
  let raw =
    output_json_string
      ~operations:
        [ `Assoc
            [ field_op, `String "revise"
            ; field_index, `Int 0
            ; field_claim, `String "durable correction"
            ; field_valid_for_days, `Null
            ; field_source_turn, `Int 4
            ]
        ]
      ()
  in
  match parse_out raw with
  | Ok { Lib.operations = [ Recognition.Revise { valid_until_update = Recognition.Clear_valid_until; _ } ]; _ } -> ()
  | Ok _ -> Alcotest.fail "revise null did not retain its clear-expiry meaning"
  | Error error ->
    Alcotest.failf "revise null should parse, got %s" (Lib.parse_error_to_string error)
;;

let test_rejects_single_member_merge () =
  rejects
    "merge with one member"
    (output_json_string
       ~operations:
         [ `Assoc
             [ field_op, `String "merge"
             ; Lib.wire_field_member_indices, `List [ `Int 1 ]
             ; field_claim, `String "m"
             ; field_category, `String "fact"
             ; field_source_turn, `Int 4
             ]
         ]
       ())
;;

let test_rejects_duplicate_member_merge () =
  (* [3; 3] names one stored fact: the >= 2 length check alone would accept it
     at the parse boundary and only Recognition.apply would reject it, after
     the exact-output candidate has already terminalized. *)
  rejects
    "merge with duplicate members"
    (output_json_string
       ~operations:
         [ `Assoc
             [ field_op, `String "merge"
             ; Lib.wire_field_member_indices, `List [ `Int 3; `Int 3 ]
             ; field_claim, `String "m"
             ; field_category, `String "fact"
             ; field_source_turn, `Int 4
             ]
         ]
       ())
;;

let test_rejects_indices_outside_visible_snapshot () =
  let out_of_range = 5 in
  List.iter
    (fun operation ->
       rejects
         "operation index outside the visible snapshot"
         (output_json_string ~operations:[ operation ] ()))
    [ `Assoc
        [ field_op, `String "reinforce"
        ; field_index, `Int out_of_range
        ; field_source_turn, `Int 4
        ]
    ; `Assoc
        [ field_op, `String "revise"
        ; field_index, `Int out_of_range
        ; field_claim, `String "corrected"
        ; field_source_turn, `Int 4
        ]
    ; `Assoc
        [ field_op, `String "forget"
        ; field_index, `Int out_of_range
        ; field_reason, `String "superseded"
        ]
    ; `Assoc
        [ field_op, `String "merge"
        ; Lib.wire_field_member_indices, `List [ `Int 0; `Int out_of_range ]
        ; field_claim, `String "merged"
        ; field_category, `String "fact"
        ; field_source_turn, `Int 4
        ]
    ]
;;

let test_rejects_reinforce_turn_outside_conversation_slice () =
  rejects
    "reinforce source_turn outside conversation slice"
    (output_json_string
       ~operations:
         [ `Assoc
             [ field_op, `String "reinforce"
             ; field_index, `Int 0
             ; field_source_turn, `Int 5
             ]
         ]
       ())
;;

let test_revise_claim_kind_tri_state_parses () =
  let parse_kind field =
    output_json_string
      ~operations:
        [ `Assoc
            ([ field_op, `String "revise"
             ; field_index, `Int 0
             ; field_claim, `String "corrected"
             ; field_source_turn, `Int 4
             ]
             @ field)
        ]
      ()
    |> parse_out
  in
  let expected =
    [ ( [ Lib.wire_field_claim_kind_update, `String "keep"
        ; Lib.wire_field_claim_kind, `Null
        ]
      , function Recognition.Keep_claim_kind -> true | _ -> false )
    ; ( [ Lib.wire_field_claim_kind_update, `String "clear"
        ; Lib.wire_field_claim_kind, `Null
        ]
      , function Recognition.Clear_claim_kind -> true | _ -> false )
    ; ( [ Lib.wire_field_claim_kind_update, `String "set"
        ; Lib.wire_field_claim_kind, `String "durable_knowledge"
        ]
      , function
        | Recognition.Set_claim_kind Types.Durable_knowledge -> true
        | _ -> false )
    ]
  in
  List.iter
    (fun (field, matches) ->
       match parse_kind field with
       | Ok
           { Lib.operations =
               [ Recognition.Revise { claim_kind_update; _ } ]
           ; _
           } when matches claim_kind_update -> ()
       | Ok _ -> fail "claim_kind update lost its tri-state meaning"
       | Error error ->
         failf
           "valid revise claim_kind was rejected: %s"
           (Lib.parse_error_to_string error))
    expected
;;

let test_rejects_non_string_revise_category () =
  (* A wrong-typed category must reject the candidate, not silently mean
     "keep the stored category" the way an intentional null does. *)
  rejects
    "revise with non-string category"
    (output_json_string
       ~operations:
         [ `Assoc
             [ field_op, `String "revise"
             ; field_index, `Int 0
             ; field_claim, `String "corrected"
             ; field_category, `Int 3
             ; field_source_turn, `Int 4
             ]
         ]
       ())
;;

let test_rejects_blank_revise_category () =
  rejects
    "revise with blank category"
    (output_json_string
       ~operations:
         [ `Assoc
             [ field_op, `String "revise"
             ; field_index, `Int 0
             ; field_claim, `String "corrected"
             ; field_category, `String "  "
             ; field_source_turn, `Int 4
             ]
         ]
       ())
;;

let test_rejects_unknown_op () =
  rejects
    "unknown op token"
    (output_json_string
       ~operations:[ `Assoc [ field_op, `String "remember" ] ]
       ())
;;

let test_parse_result_reports_error () =
  match parse_out "not json" with
  | Error (Lib.Invalid_json _) -> ()
  | Error error ->
    Alcotest.failf "expected Invalid_json, got %s" (Lib.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "expected typed parse error"
;;

let test_rejects_multiple_json_objects () =
  rejects
    "multiple JSON objects"
    (minimal_output_json () ^ "\n" ^ minimal_output_json ~claim:"d" ())
;;

let test_rejects_model_thinking_leak () =
  rejects
    "thinking leak before JSON"
    ("<thinking>I should output JSON now.</thinking>\n" ^ minimal_output_json ())
;;

let test_rejects_malformed_json () =
  rejects
    "malformed JSON"
    {|{"episode_summary":"s","operations":[{"op":"add","fact":{"claim":"c","category":"fact","source_turn":0}}],|}
;;

let test_parses_nested_braces_inside_string () =
  let raw = minimal_output_json ~claim:"Keep literal { braces } in memory" () in
  match parse_out raw with
  | Ok out ->
    (match out.Lib.operations with
     | [ Recognition.Add fact ] ->
       check string "claim with braces parsed"
         "Keep literal { braces } in memory"
         fact.Masc.Keeper_memory_os_types.claim
     | ops -> Alcotest.failf "expected one add, got %d ops" (List.length ops))
  | Error error ->
    Alcotest.failf
      "valid JSON with braces in a string should parse, got %s"
      (Lib.parse_error_to_string error)
;;

let test_missing_lists_default_to_empty () =
  let raw =
    `Assoc
      [ field_episode_summary, `String "s"
      ; field_operations, `List [ add_op_json () ]
      ]
    |> Yojson.Safe.to_string
  in
  match parse_out raw with
  | Ok out ->
    check int "open_items empty" 0 (List.length out.Lib.open_items);
    check int "constraints empty" 0 (List.length out.Lib.constraints);
    check int "preserved_tool_refs empty" 0 (List.length out.Lib.preserved_tool_refs)
  | Error error ->
    Alcotest.failf
      "missing optional lists should default to empty, got %s"
      (Lib.parse_error_to_string error)
;;

let test_invalid_source_turn_string_rejected () =
  rejects
    "invalid source_turn"
    (output_json_string
       ~operations:[ add_op_json ~source_turn:(`String "not-a-number") () ]
       ())
;;

let () =
  Eio_main.run @@ fun _env ->
  run "keeper_librarian_retry"
    [
      ( "cadence",
        [
          test_case "fresh then every cadence" `Quick test_cadence_fresh_then_every_cadence;
          test_case "cadence 1 always due" `Quick test_cadence_one_always_due;
          test_case "step transitions" `Quick test_cadence_step_transitions;
          test_case "record success resets" `Quick test_cadence_record_success_resets;
          test_case "record attempt defers" `Quick test_cadence_record_attempt_defers;
          test_case "cadence_due fires once per period" `Quick test_cadence_due_periodic;
          test_case "cadence_due is per-keeper" `Quick test_cadence_due_independent_keepers;
          test_case "cadence_due resets on trace rollover" `Quick
            test_cadence_due_resets_on_trace_rollover;
          test_case "cadence table bounded under trace rotation" `Quick
            test_cadence_table_bounded_under_trace_rotation;
          test_case "cadence_step_keyed rollover decision" `Quick test_cadence_step_keyed;
          test_case "durable cadence survives a fresh read" `Quick
            test_durable_cadence_survives_a_fresh_read;
          test_case "failed cadence backoff write is surfaced" `Quick
            test_failed_cadence_backoff_write_is_surfaced;
        ] );
      ( "strict_parsing",
        [
          test_case "rejects markdown-wrapped JSON" `Quick test_rejects_markdown_wrapped;
          test_case "rejects prose-wrapped JSON" `Quick test_rejects_prose_wrapped_json;
          test_case "rejects unexpected episode field" `Quick
            test_rejects_unexpected_episode_field;
          test_case "rejects unexpected claim field" `Quick test_rejects_unexpected_claim_field;
          test_case "rejects foreign non-null operation field" `Quick
            test_rejects_foreign_non_null_operation_field;
          test_case "rejects overlapping operation targets" `Quick
            test_rejects_overlapping_operation_targets;
          test_case "parses all operation shapes" `Quick test_parses_all_operation_shapes;
          test_case "revise null clears expiry" `Quick
            test_revise_null_clears_expiry_instead_of_preserving_it;
          test_case "rejects single-member merge" `Quick test_rejects_single_member_merge;
          test_case "rejects duplicate-member merge" `Quick
            test_rejects_duplicate_member_merge;
          test_case "rejects indices outside visible snapshot" `Quick
            test_rejects_indices_outside_visible_snapshot;
          test_case "rejects reinforce turn outside conversation slice" `Quick
            test_rejects_reinforce_turn_outside_conversation_slice;
          test_case "revise claim_kind parses as tri-state" `Quick
            test_revise_claim_kind_tri_state_parses;
          test_case "rejects non-string revise category" `Quick
            test_rejects_non_string_revise_category;
          test_case "rejects blank revise category" `Quick
            test_rejects_blank_revise_category;
          test_case "rejects unknown op" `Quick test_rejects_unknown_op;
          test_case "parses JSON-string-wrapped object" `Quick test_parses_json_string_wrapping;
          test_case "rejects string source_turn" `Quick test_rejects_string_source_turn;
          test_case "parse result reports typed error" `Quick test_parse_result_reports_error;
          test_case "rejects multiple JSON objects" `Quick test_rejects_multiple_json_objects;
          test_case "rejects model thinking leak" `Quick test_rejects_model_thinking_leak;
          test_case "rejects malformed JSON" `Quick test_rejects_malformed_json;
          test_case "parses nested braces inside string" `Quick
            test_parses_nested_braces_inside_string;
          test_case "missing lists default to empty" `Quick test_missing_lists_default_to_empty;
          test_case "rejects invalid source_turn string" `Quick test_invalid_source_turn_string_rejected;
        ] );
    ]
