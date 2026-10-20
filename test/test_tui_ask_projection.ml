(* Answering from the terminal. Every case here is one the operator can reach
   with two keys, so a regression shows up as a wrong keystroke, not a wrong
   type. *)

module Ask = Masc_tui_ask_projection

let choice id label : Masc.Tui_decode_asks.ask_choice =
  { ac_id = id; ac_label = label; ac_description = None }

let question ?(mode = Masc.Tui_decode_asks.Ask_single) ?(free_text = Masc.Tui_decode_asks.Ask_choices_only)
    ?(choices = [ choice "yes" "Yes"; choice "no" "No" ]) id : Masc.Tui_decode_asks.ask_question =
  {
    aq_id = id;
    aq_header = "Header";
    aq_prompt = "Prompt for " ^ id;
    aq_mode = mode;
    aq_free_text = free_text;
    aq_choices = choices;
  }

let row ?(resolution = Masc.Tui_decode_asks.Ask_open) ?(questions = [ question "q1" ]) id : Masc.Tui_decode_asks.ask_row =
  {
    ar_keeper = "asker";
    ar_id = id;
    ar_asked_at = 1.0;
    ar_source_turn_ref = None; ar_context = None;
    ar_questions = questions;
    ar_resolution = resolution;
  }

let chosen draft q =
  match Ask.response_for draft ~question:q with
  | Some (Ask.Draft_chose ids) -> ids
  | Some (Ask.Draft_wrote text) -> [ "wrote:" ^ text ]
  | Some Ask.Draft_skipped -> [ "skipped" ]
  | None -> []

let check_ids = Alcotest.(check (list string))

let single = question "q1"
let multi = question ~mode:Masc.Tui_decode_asks.Ask_multi "q1"
let yes = choice "yes" "Yes"
let no = choice "no" "No"

let test_draft_for_keeps_matching_ask () =
  let d = Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:single ~choice:yes in
  let kept = Ask.draft_for (Some d) ~row:(row "a1") in
  check_ids "selection survives" [ "yes" ] (chosen kept single)

let test_draft_for_resets_on_other_ask () =
  let d = Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:single ~choice:yes in
  let fresh = Ask.draft_for (Some d) ~row:(row "a2") in
  Alcotest.(check string) "adopts the new ask" "a2" (Ask.draft_ask_id fresh);
  check_ids "nothing carried over" [] (chosen fresh single)

let test_single_replaces () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:single ~choice:yes in
  let d = Ask.toggle_choice d ~question:single ~choice:no in
  check_ids "one at a time" [ "no" ] (chosen d single)

let test_single_repick_clears () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:single ~choice:yes in
  let d = Ask.toggle_choice d ~question:single ~choice:yes in
  check_ids "a mis-press needs no second key" [] (chosen d single);
  Alcotest.(check bool) "back to unanswered" true (Ask.response_for d ~question:single = None)

let test_multi_keeps_pick_order () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:multi ~choice:no in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  check_ids "order the operator picked" [ "no"; "yes" ] (chosen d multi)

let test_multi_removes () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:multi ~choice:no in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  let d = Ask.toggle_choice d ~question:multi ~choice:no in
  check_ids "removed the first" [ "yes" ] (chosen d multi)

let test_multi_emptied_is_unanswered () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  Alcotest.(check bool) "empty selection is not an answer" true
    (Ask.response_for d ~question:multi = None)

let test_free_text_slot_for_choices_only () =
  let slot = Ask.free_text_slot ~ask_id:"a1" single in
  Alcotest.(check (option string)) "no author hint needed" None (Ask.free_text_hint slot);
  let draft = Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot ~text:"another route" in
  match Ask.response_for draft ~question:single with
  | Some (Ask.Draft_wrote "another route") -> ()
  | _ -> Alcotest.fail "alternative was not drafted"

let test_free_text_slot_carries_hint () =
  let q = question ~free_text:(Masc.Tui_decode_asks.Ask_free_text_allowed { aft_hint = Some "one line" }) "q1" in
  Alcotest.(check (option string)) "hint reaches the editor" (Some "one line")
    (Ask.free_text_hint (Ask.free_text_slot ~ask_id:"a1" q))

let test_alternative_shortcut () =
  List.iter (fun (count, expected) ->
    let choices = List.init count (fun i -> choice (string_of_int i) "choice") in
    let q = question ~choices "q1" in
    Alcotest.(check (option int)) "unambiguous next digit" expected (Ask.alternative_position q)
  ) [0, None; 1, Some 2; 4, Some 5; 8, Some 9; 9, None; 12, None]

let text_question_named id =
  question ~free_text:(Masc.Tui_decode_asks.Ask_free_text_allowed { aft_hint = None }) ~choices:[] id

let text_question = text_question_named "q1"

let slot_of = Ask.free_text_slot ~ask_id:"a1"

(* The panel draws the caret on a row, and the editor holds a slot rather than
   a row index; without a way back to the question id the surface would have to
   store that id a second time and the two could disagree. *)
let test_free_text_slot_names_its_question () =
  Alcotest.(check string) "the slot names the question it writes to" "q7"
    (Ask.free_text_question_id (slot_of (text_question_named "q7")))

(* masc_ask numbers every ask's questions from q1, so two open asks both have
   a q1. Text typed for one must not land in the other's draft when a
   snapshot moves the cursor while the operator types. *)
let test_free_text_slot_writes_only_its_own_ask () =
  let slot = Ask.free_text_slot ~ask_id:"a1" text_question in
  Alcotest.(check string) "the slot names its ask" "a1" (Ask.free_text_ask_id slot);
  let other = Ask.set_text (Ask.empty_draft ~ask_id:"a2") ~slot ~text:"meant for a1" in
  Alcotest.(check bool) "another ask's q1 stays unanswered" true
    (Ask.response_for other ~question:text_question = None);
  match Ask.response_for (Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot ~text:"meant for a1")
          ~question:text_question with
  | Some (Ask.Draft_wrote "meant for a1") -> ()
  | _ -> Alcotest.fail "the slot's own ask did not get the text"

let test_set_text_records () =
  let d = Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot:(slot_of text_question) ~text:"ship it" in
  check_ids "text is the answer" [ "wrote:ship it" ] (chosen d text_question)

let test_blank_text_clears () =
  let slot = slot_of text_question in
  let d = Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot ~text:"draft" in
  let d = Ask.set_text d ~slot ~text:"   " in
  Alcotest.(check bool) "an emptied editor means unanswered" true
    (Ask.response_for d ~question:text_question = None)

let test_skip_counts_as_answered () =
  let d = Ask.skip (Ask.empty_draft ~ask_id:"a1") ~question:single in
  check_ids "declining is an answer" [ "skipped" ] (chosen d single)

let test_clear_removes () =
  let d = Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:single ~choice:yes in
  let d = Ask.clear d ~question:single in
  Alcotest.(check bool) "cleared" true (Ask.response_for d ~question:single = None)

let missing_ids = function
  | Ask.Missing questions ->
      List.map (fun (q : Masc.Tui_decode_asks.ask_question) -> q.aq_id) questions
  | Ask.Ready _ -> [ "<ready>" ]
  | Ask.Not_open -> [ "<not-open>" ]

let two_questions = [ question "q1"; question "q2" ]

let test_missing_lists_every_gap_at_once () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  check_ids "one round trip, not two" [ "q1"; "q2" ] (missing_ids (Ask.readiness d ~row:r))

let test_missing_shrinks_as_answered () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.skip (Ask.empty_draft ~ask_id:"a1") ~question:(List.nth two_questions 0) in
  check_ids "only the gap remains" [ "q2" ] (missing_ids (Ask.readiness d ~row:r))

let test_ready_follows_ask_order_not_draft_order () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.skip d ~question:(List.nth two_questions 1) in
  let d = Ask.toggle_choice d ~question:(List.nth two_questions 0) ~choice:yes in
  match Ask.readiness d ~row:r with
  | Ask.Ready json ->
      let ids =
        match json with
        | `List items ->
            List.filter_map
              (function
                | `Assoc fields -> (
                    match List.assoc_opt "question_id" fields with
                    | Some (`String id) -> Some id
                    | Some _ | None -> None)
                | _ -> None)
              items
        | _ -> []
      in
      check_ids "the ask decides the order" [ "q1"; "q2" ] ids
  | Ask.Missing _ | Ask.Not_open -> Alcotest.fail "expected ready"

let test_ready_encodes_each_shape () =
  let questions = [ question "q1"; question "q2"; text_question_named "q3" ] in
  let r = row ~questions "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:(List.nth questions 0) ~choice:yes in
  let d = Ask.skip d ~question:(List.nth questions 1) in
  let d = Ask.set_text d ~slot:(slot_of (List.nth questions 2)) ~text:"because" in
  match Ask.readiness d ~row:r with
  | Ask.Ready json ->
      Alcotest.(check string)
        "wire shape the endpoint decodes"
        {|[{"question_id":"q1","response":{"kind":"chose","choice_ids":["yes"]}},{"question_id":"q2","response":{"kind":"skipped"}},{"question_id":"q3","response":{"kind":"wrote","text":"because"}}]|}
        (Yojson.Safe.to_string json)
  | Ask.Missing _ | Ask.Not_open -> Alcotest.fail "expected ready"

let test_answered_row_is_not_open () =
  let r =
    row ~resolution:(Masc.Tui_decode_asks.Ask_answered { aa_answered_at = 2.0; aa_question_ids = [ "q1" ] }) "a1"
  in
  check_ids "first write settled it" [ "<not-open>" ] (missing_ids (Ask.readiness (Ask.empty_draft ~ask_id:"a1") ~row:r))

let test_withdrawn_row_is_not_open () =
  let r =
    row ~resolution:(Masc.Tui_decode_asks.Ask_withdrawn { aw_reason = "moot"; aw_withdrawn_at = 2.0 }) "a1"
  in
  check_ids "withdrawn" [ "<not-open>" ] (missing_ids (Ask.readiness (Ask.empty_draft ~ask_id:"a1") ~row:r))

let test_foreign_draft_contributes_nothing () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.skip (Ask.empty_draft ~ask_id:"OTHER") ~question:(List.nth two_questions 0) in
  check_ids "everything missing, which is true" [ "q1"; "q2" ] (missing_ids (Ask.readiness d ~row:r))

let test_request_body_omits_blank_session () =
  let body = Ask.request_body ~answers:(`List []) ~session_id:(Some "  ") in
  Alcotest.(check string) "no empty session field" {|{"answers":[]}|} (Yojson.Safe.to_string body)

let test_request_body_carries_session_and_no_identity () =
  let body = Ask.request_body ~answers:(`List []) ~session_id:(Some "s1") in
  Alcotest.(check string) "the body names the session, never who answered"
    {|{"answers":[],"session_id":"s1"}|}
    (Yojson.Safe.to_string body)

let gate_name = function
  | Ask.Ask_gate_blocked_inflight -> "blocked"
  | Ask.Ask_gate_arm id -> "arm:" ^ id
  | Ask.Ask_gate_submit -> "submit"

let test_gate_blocks_while_inflight () =
  Alcotest.(check string) "one answer at a time" "blocked"
    (gate_name (Ask.gate_transition ~inflight:true ~pending:(Some "a1") ~ask_id:"a1"))

let test_gate_arms_first () =
  Alcotest.(check string) "first press arms" "arm:a1"
    (gate_name (Ask.gate_transition ~inflight:false ~pending:None ~ask_id:"a1"))

let test_gate_submits_on_second_press () =
  Alcotest.(check string) "second press sends" "submit"
    (gate_name (Ask.gate_transition ~inflight:false ~pending:(Some "a1") ~ask_id:"a1"))

let test_gate_rearms_on_a_different_ask () =
  Alcotest.(check string) "moving the cursor disarms the old one" "arm:a2"
    (gate_name (Ask.gate_transition ~inflight:false ~pending:(Some "a1") ~ask_id:"a2"))

let rows ids = List.map (fun id -> row id) ids

let cursor_t =
  Alcotest.testable
    (fun fmt -> function
      | Ask.On position -> Format.fprintf fmt "On %d" position
      | Ask.Released position -> Format.fprintf fmt "Released %d" position)
    ( = )

let selected_id rows cursor =
  Option.map (fun (row : Masc.Tui_decode_asks.ask_row) -> row.ar_id) (Ask.selected_row rows cursor)

let test_cursor_follows_the_ask () =
  Alcotest.check cursor_t "same ask, new index" (Ask.On 2)
    (Ask.reconcile_cursor ~current_rows:(rows [ "a1"; "a2" ]) ~cursor:(Ask.On 1)
       ~next_rows:(rows [ "x"; "y"; "a2" ]))

let test_cursor_releases_when_ask_is_gone () =
  Alcotest.check cursor_t "nothing selected, resume where it was" (Ask.Released 1)
    (Ask.reconcile_cursor ~current_rows:(rows [ "a1"; "a2" ]) ~cursor:(Ask.On 1)
       ~next_rows:(rows [ "x"; "y" ]))

let test_cursor_clamps_to_shorter_list () =
  Alcotest.check cursor_t "released and clamped" (Ask.Released 0)
    (Ask.reconcile_cursor ~current_rows:(rows [ "a1"; "a2"; "a3" ]) ~cursor:(Ask.On 2)
       ~next_rows:(rows [ "x" ]))

(* ask0319873c920b4606: the operator answered the first ask; the re-read
   dropped it and the account question slid into position 0. The same keys,
   pressed again four seconds later, answered that question with its first
   choice without it ever being chosen. *)
let test_answered_ask_does_not_select_the_next () =
  let before = rows [ "answered"; "unread" ] and after = rows [ "unread" ] in
  let cursor = Ask.reconcile_cursor ~current_rows:before ~cursor:(Ask.On 0) ~next_rows:after in
  Alcotest.(check (option string)) "no ask is selected" None (selected_id after cursor)

let test_first_read_selects_the_first_ask () =
  let next_rows = rows [ "a1"; "a2" ] in
  let cursor = Ask.reconcile_cursor ~current_rows:[] ~cursor:Ask.initial_cursor ~next_rows in
  Alcotest.(check (option string)) "nothing was chosen yet" (Some "a1") (selected_id next_rows cursor)

let test_released_cursor_stays_released () =
  let next_rows = rows [ "a1"; "a2"; "a3" ] in
  let cursor =
    Ask.reconcile_cursor ~current_rows:(rows [ "a1" ]) ~cursor:(Ask.Released 1) ~next_rows
  in
  Alcotest.check cursor_t "a new arrival is not selected for the operator" (Ask.Released 1) cursor;
  Alcotest.(check (option string)) "no selection" None (selected_id next_rows cursor)

let test_move_from_released_selects_in_place () =
  let current = rows [ "unread"; "later" ] in
  let cursor = Ask.move_cursor current (Ask.Released 0) ~delta:1 in
  Alcotest.(check (option string)) "the first press selects, it does not skip"
    (Some "unread") (selected_id current cursor)

let test_move_clamps () =
  let current = rows [ "a1"; "a2" ] in
  Alcotest.check cursor_t "down at the end" (Ask.On 1) (Ask.move_cursor current (Ask.On 1) ~delta:1);
  Alcotest.check cursor_t "up at the top" (Ask.On 0) (Ask.move_cursor current (Ask.On 0) ~delta:(-1))

let test_move_on_empty_list_keeps_cursor () =
  Alcotest.check cursor_t "nothing to move to" (Ask.Released 0)
    (Ask.move_cursor [] (Ask.Released 0) ~delta:1)

let test_out_of_range_position_selects_nothing () =
  Alcotest.(check (option string)) "no row there" None (selected_id (rows [ "a1" ]) (Ask.On 5))

let snapshot rows : Masc.Tui_decode_asks.asks_snapshot =
  { asn_keeper = None; asn_open_count = List.length rows; asn_rows = rows }

let answered_row id =
  row
    ~resolution:(Masc.Tui_decode_asks.Ask_answered { aa_answered_at = 1.0; aa_question_ids = [] })
    id

(* One filter, three callers: the panel draws these rows, its footer names the
   keys that work on the one under the cursor, and the executable answers it. A
   second copy is how a cursor and the rows it indexes come apart. *)
let test_open_rows_keeps_only_what_is_waiting () =
  let rows = [ row "a1"; answered_row "a2"; row "a3" ] in
  Alcotest.(check (list string)) "the open ones, in wire order" [ "a1"; "a3" ]
    (List.map
       (fun (r : Masc.Tui_decode_asks.ask_row) -> r.Masc.Tui_decode_asks.ar_id)
       (Ask.open_rows (snapshot rows)))

let test_newly_opened_silent_on_first_read () =
  Alcotest.(check (list string)) "first read establishes a baseline silently" []
    (Ask.newly_opened_ask_ids ~previous:None ~current:(snapshot [ row "a1" ]))

let test_newly_opened_reports_arrival () =
  let before = snapshot [ row "a1" ] in
  let after = snapshot [ row "a1"; row "a2" ] in
  Alcotest.(check (list string)) "the ask that arrived" [ "a2" ]
    (Ask.newly_opened_ask_ids ~previous:(Some before) ~current:after)

let test_newly_opened_silent_on_reread () =
  let s = snapshot [ row "a1" ] in
  Alcotest.(check (list string)) "the same open asks ring nothing" []
    (Ask.newly_opened_ask_ids ~previous:(Some s) ~current:s)

let test_newly_opened_ignores_answered () =
  let before = snapshot [ row "a1" ] in
  let after = snapshot [ answered_row "a1"; row "a2" ] in
  Alcotest.(check (list string)) "a1 closing is not an arrival, a2 is" [ "a2" ]
    (Ask.newly_opened_ask_ids ~previous:(Some before) ~current:after)

let test_ring_when_arrival_and_not_watching () =
  Alcotest.(check bool) "arrival off the asks surface rings" true
    (Ask.should_ring_for_new_ask ~new_ids:[ "a1" ]
       ~operator_is_watching_asks:false)

let test_silent_when_watching_asks () =
  Alcotest.(check bool) "on the asks surface it stays silent" false
    (Ask.should_ring_for_new_ask ~new_ids:[ "a1" ]
       ~operator_is_watching_asks:true)

let test_silent_when_nothing_arrived () =
  Alcotest.(check bool) "no arrival, no ring, even off the surface" false
    (Ask.should_ring_for_new_ask ~new_ids:[] ~operator_is_watching_asks:false)

(* The producer's real row encoder feeds the decoder and answer draft.
   This proves the module split preserves the operator's choice identities
   and the server's free-text capability, beyond a hand-written JSON fixture. *)
let test_wire_question_reaches_the_answer_draft () =
  let valid = function
    | Ok value -> value
    | Error _ -> Alcotest.fail "could not construct the producer's question"
  in
  let module Domain = Masc.Keeper_ask in
  let choice = valid (Domain.choice ~choice_id:"later" ~label:"After lunch" ()) in
  let question = valid (Domain.question ~question_id:"window" ~header:"Window"
    ~prompt:"When?" ~choices:[choice] ~mode:Domain.Single
    ~free_text:Domain.Choices_only) in
  let ask = valid (Domain.ask ~ask_id:"wire-ask" ~keeper_name:"reader"
    ~questions:[question] ~context:"Choose a deployment window"
    ~source_turn_ref:(Ids.Turn_ref.make ~trace_id:"original-question-trace" ~absolute_turn:17)
    ~continuation:(Keeper_continuation_channel.unrouted "wire projection test") ~asked_at:42. ()) in
  let row = Masc.Keeper_ask_operator_projection.ask_row_json ~keeper_name:"reader"
    (ask.ask_id, (ask, Domain.Open)) in
  let snapshot = `Assoc [ "workspace", `Assoc ["base_path",`String "/wire";"masc_root",`String "/wire/.masc"];
    "state_ready",`Bool true; "keeper", `String "reader"; "open_count", `Int 1;
    "asks", `List [row] ] in
  match Masc.Tui_decode_asks.decode_asks_snapshot
      ~expected_base_path:"/wire" ~expected_masc_root:"/wire/.masc" snapshot with
  | Error error -> Alcotest.fail error
  | Ok snapshot ->
      (match Ask.open_rows snapshot with
       | [row] ->
           Alcotest.(check (option string)) "question source survives the canonical wire"
             (Some "original-question-trace#17") (Option.map Ids.Turn_ref.to_string row.ar_source_turn_ref);
           let origin = Ask.origin_of_row row in
           let feedback = Ask.answer_feedback ?source_turn_ref:row.ar_source_turn_ref
               ~keeper_name:row.ar_keeper ~ask_id:row.ar_id ~submitted_label:"private answer"
               (Ok (Masc.Tui_decode_asks.Ask_answer_recorded Masc.Tui_decode_asks.Ask_wake_stored)) in
           Alcotest.(check bool) "answer origin is the same original question" true
             (Ask.same_origin origin (Ask.origin_of_feedback feedback));
           Alcotest.(check (option string)) "context survives the wire"
             (Some "Choose a deployment window") row.ar_context;
           (match row.ar_questions with
            | [question] ->
                (match question.aq_free_text with
                 | Masc.Tui_decode_asks.Ask_free_text_allowed _ -> ()
                 | Masc.Tui_decode_asks.Ask_choices_only ->
                     Alcotest.fail "producer offers an operator alternative");
                (match question.aq_choices with
                 | [choice] ->
                     let draft = Ask.toggle_choice
                       (Ask.empty_draft ~ask_id:row.ar_id) ~question ~choice in
                     check_ids "the answer names the stable wire id"
                       ["later"] (chosen draft question)
                 | _ -> Alcotest.fail "expected one wire choice")
            | _ -> Alcotest.fail "expected one wire question")
       | _ -> Alcotest.fail "expected one open wire ask")

let test_question_source_is_explicit_and_unambiguous () =
  let decode source_fields =
    let row = `Assoc (["keeper",`String "reader";"ask_id",`String "wire-ask";
      "asked_at",`Float 42.;"context",`Null;"questions",`List [];
      "resolution",`Assoc ["state",`String "open"]] @ source_fields) in
    Masc.Tui_decode_asks.decode_asks_snapshot ~expected_base_path:"/wire"
      ~expected_masc_root:"/wire/.masc"
      (`Assoc ["workspace",`Assoc ["base_path",`String "/wire";"masc_root",`String "/wire/.masc"];
        "state_ready",`Bool true;"open_count",`Int 1;"asks",`List [row]]) in
  (match decode ["source_turn_ref",`Null] with
   | Ok {asn_rows=[row];_} ->
       Alcotest.(check bool) "unobserved source stays unobserved" true (row.ar_source_turn_ref=None)
   | Ok _ | Error _ -> Alcotest.fail "explicit unobserved source should remain readable");
  List.iter (fun source_fields -> Alcotest.(check bool)
      "missing, malformed or duplicate source cannot become current-turn provenance" true
      (Result.is_error (decode source_fields)))
    [ []; ["source_turn_ref",`Int 17]; ["source_turn_ref",`Bool false];
      ["source_turn_ref",`String "missing-turn"];
      ["source_turn_ref",`String "#17"];
      ["source_turn_ref",`Null;"source_turn_ref",`Null];
      ["source_turn_ref",`Null;"source_turn_ref",`String "forged#17"];
      ["source_turn_ref",`String "first#17";"source_turn_ref",`String "second#17"] ]

let test_unknown_wire_resolution_is_rejected () =
  let snapshot = Yojson.Safe.from_string {|{
    "workspace":{"base_path":"/wire","masc_root":"/wire/.masc"},
    "state_ready":true,
    "keeper":"reader", "open_count":0, "asks":[{
      "keeper":"reader", "ask_id":"wire-ask", "asked_at":42,
      "source_turn_ref":null, "context":null, "questions":[], "resolution":{"state":"future"}
    }]
  }|} in
  match Masc.Tui_decode_asks.decode_asks_snapshot
      ~expected_base_path:"/wire" ~expected_masc_root:"/wire/.masc" snapshot with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown resolution must not create an answerable ask"

let test_foreign_or_ambiguous_workspace_never_clears_questions () =
  let base = "base_path",`String "/wire" and root = "masc_root",`String "/wire/.masc" in
  let rows = ["state_ready",`Bool true;"keeper",`Null;"open_count",`Int 0;"asks",`List []] in
  let workspace = `Assoc [base;root] in
  let decode fields = Masc.Tui_decode_asks.decode_asks_snapshot
      ~expected_base_path:"/wire" ~expected_masc_root:"/wire/.masc" (`Assoc (fields @ rows)) in
  (match decode ["workspace",workspace] with
   | Ok snapshot -> Alcotest.(check int) "matching empty fleet is authoritative" 0 snapshot.asn_open_count
   | Error detail -> Alcotest.fail detail);
  List.iter (fun fields -> Alcotest.(check bool) "foreign or ambiguous empty fleet is refused" true
    (Result.is_error (decode fields)))
    [ []; ["workspace",`Null]; ["workspace",workspace;"workspace",workspace];
      ["workspace",`Assoc [base]]; ["workspace",`Assoc [root]];
      ["workspace",`Assoc [base;base;root]];
      ["workspace",`Assoc ["base_path",`String "/other";root]];
      ["workspace",`Assoc [base;"masc_root",`String "/other-root"]];
      ["workspace",workspace;"state_ready",`Bool false] ];
  List.iter (fun readiness ->
    Alcotest.(check bool) "booting or missing readiness cannot clear questions" true
      (Result.is_error (Masc.Tui_decode_asks.decode_asks_snapshot
        ~expected_base_path:"/wire" ~expected_masc_root:"/wire/.masc"
        (`Assoc (["workspace",workspace] @ readiness @ List.remove_assoc "state_ready" rows)))))
    [ []; ["state_ready",`Bool false]; ["state_ready",`String "true"] ]

let decode_answer_receipt ~status_code body =
  Masc.Tui_decode_asks.decode_ask_answer_receipt
    ~expected_ask_id:"wire-ask" ~status_code body

let test_recording_and_wake_delivery_are_separate () =
  let response delivered =
    Server_routes_http_keeper_stream.ask_answer_response
      ~ask_id:"wire-ask" ~actor:"operator" ~answer_count:1 ~open_remaining:0
      ~delivered
  in
  let status, body = response false in
  (match status with
   | `Internal_server_error -> ()
   | _ -> Alcotest.fail "a pending wake is a partial failure");
  (match decode_answer_receipt ~status_code:500 body with
   | Ok (Masc.Tui_decode_asks.Ask_answer_recorded (Ask_wake_pending _)) -> ()
   | _ -> Alcotest.fail "partial receipt must preserve confirmed recording");
  let status, body = response true in
  (match status with
   | `OK -> ()
   | _ -> Alcotest.fail "a stored wake is accepted");
  (match decode_answer_receipt ~status_code:200 body with
   | Ok (Masc.Tui_decode_asks.Ask_answer_recorded Ask_wake_stored) -> ()
   | _ -> Alcotest.fail "queue acceptance is distinct from answer consumption")

let test_conflict_keeps_the_canonical_winner () =
  List.iter (fun delivered ->
    let status, body = Server_routes_http_keeper_stream.ask_already_answered_response
        ~ask_id:"wire-ask" ~answers:[] ~answered_at:123. ~delivered in
    (match status with
     | `Conflict -> ()
     | _ -> Alcotest.fail "an existing winner remains a conflict");
    match decode_answer_receipt ~status_code:409 body with
    | Ok (Masc.Tui_decode_asks.Ask_answer_already_recorded
        { aar_answered_at = 123.; aar_delivery }) ->
        (match delivered, aar_delivery with
         | true, Ask_wake_stored | false, Ask_wake_pending _ -> ()
         | _ -> Alcotest.fail "conflict must preserve wake outcome")
    | _ -> Alcotest.fail "an existing answer cannot be attributed to the submitted choices")
    [false; true]

let receipt_body ?(ask_id = "wire-ask") ?(state = `Null)
    ?(recorded = `Bool true) ?(delivered = `Bool false) () =
  `Assoc ["ask_id", `String ask_id; "recorded", recorded; "delivered", delivered;
          "state", state; "error", `String "delivery storage unavailable";
          "answered_at", `Float 123.]

let test_unconfirmed_winner_is_not_a_recorded_submission () =
  let body = receipt_body ~state:(`String "recording_unconfirmed") () in
  match decode_answer_receipt ~status_code:500 body with
  | Ok (Masc.Tui_decode_asks.Ask_answer_written_unconfirmed _) -> ()
  | _ -> Alcotest.fail "append proof must not invent a canonical winner"

let test_answer_receipts_reject_incoherent_or_foreign_evidence () =
  let malformed = [
    500, receipt_body ~ask_id:"other-ask" ();
    200, receipt_body ();
    500, receipt_body ~delivered:(`Bool true) ();
    409, receipt_body ();
    409, receipt_body ~state:(`String "answered") ~recorded:`Null ();
    500, receipt_body ~recorded:(`String "true") ();
    500, receipt_body ~delivered:`Null ();
    503, receipt_body ();
    200, receipt_body ~state:(`String "future") ~delivered:(`Bool true) ();
    409, `Assoc ["ask_id", `String "wire-ask"; "recorded", `Bool true;
                "delivered", `Bool true; "state", `String "answered";
                "answered_at", `Float nan];
  ] in
  List.iter (fun (status_code, body) ->
    match decode_answer_receipt ~status_code body with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "incoherent evidence cannot authorize draft retirement") malformed

let test_refusal_and_missing_recording_evidence_are_distinct () =
  let body = `Assoc ["error", `String "invalid choice"] in
  (match decode_answer_receipt ~status_code:400 body with
   | Ok (Masc.Tui_decode_asks.Ask_answer_refused _) -> ()
   | _ -> Alcotest.fail "a server refusal keeps the answer editable");
  (match decode_answer_receipt ~status_code:500 body with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a generic server error leaves recording unconfirmed")

let test_feedback_preserves_receipt_and_canonical_winner () =
  let module Decode = Masc.Tui_decode_asks in
  let label = "reader: submitted private choice" in
  let cases =
    [ Ok (Decode.Ask_answer_recorded Decode.Ask_wake_stored), Some label, "recorded", `String "stored"
    ; Ok (Decode.Ask_answer_recorded (Decode.Ask_wake_pending "private server detail")),
        Some label, "recorded", `String "pending"
    ; Ok (Decode.Ask_answer_already_recorded { aar_delivery = Decode.Ask_wake_stored; aar_answered_at = 123. }),
        None, "already_recorded", `String "stored"
    ; Ok (Decode.Ask_answer_written_unconfirmed "private append detail"), None, "winner_unconfirmed", `Null
    ; Ok (Decode.Ask_answer_refused "private refusal detail"), None, "refused", `Null
    ; Error "private transport detail", None, "unconfirmed", `Null ] in
  List.iter (fun (receipt, expected_label, recording, delivery) ->
    let feedback = Ask.answer_feedback ~keeper_name:"reader" ~ask_id:"wire-ask"
      ~submitted_label:label receipt in
    Alcotest.(check (option string)) "only a new canonical answer owns its submitted labels"
      expected_label feedback.af_submitted_label;
    Alcotest.(check bool) "original typed receipt is preserved" true
      (feedback.af_receipt = receipt);
    let json = Ask.answer_feedback_to_json feedback in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "exact Keeper" "reader" (json |> member "keeper" |> to_string);
    Alcotest.(check string) "exact Ask" "wire-ask" (json |> member "ask_id" |> to_string);
    Alcotest.(check string) "recording fact" recording (json |> member "recording" |> to_string);
    Alcotest.(check bool) "delivery is not Keeper action" true ((json |> member "delivery") = delivery);
    Alcotest.(check (list string)) "receipt log contains metadata, no submitted/error bodies"
      ["ask_id"; "delivery"; "keeper"; "recording"; "source_turn_ref"]
      (json |> to_assoc |> List.map fst |> List.sort String.compare)) cases

let test_followup_protocol_keeps_exact_identity_and_unknowns () =
  let module Decode = Masc.Tui_decode_asks in
  let reactions = ["state",`String "observed";"turn_started_at",`Float 201.;
    "turn_finished_at",`Null;"queue_settled_at",`Null;"queue_cancelled_at",`Null;
    "evidence_complete",`Bool false] in
  let progress = ["state",`String "observed";"answered_at",`Float 200.;
    "stimulus_id",`String "original-source";"reaction_evidence",`Assoc reactions;
    "tool_actions", `Assoc ["state", `String "unavailable"];
    "linked_task", `Assoc ["state", `String "unlinked"]] in
  let fields = ["workspace",`Assoc ["base_path",`String "/workspace";"masc_root",`String "/workspace/.masc"];
    "state_ready",`Bool true;"keeper",`String "alpha";"answer_progress_for",`String "ask-original"] in
  let decode fields progress = Decode.decode_ask_followup ~expected_base_path:"/workspace"
    ~expected_masc_root:"/workspace/.masc" ~keeper_name:"alpha" ~ask_id:"ask-original"
    (`Assoc (fields @ ["answer_progress",`Assoc progress])) in
  let value = match decode fields progress with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "positive entry and incomplete evidence remain distinct from completion" true
    (match value.af_reactions with
     | Decode.Ask_reactions_observed {ar_turn_started_at=Some 201.;ar_turn_finished_at=None;
         ar_queue_settled_at=None;ar_evidence_complete=false;ar_evidence_current=true;_} -> true
     | Ask_reactions_observed _ | Ask_reactions_unavailable -> false);
  List.iter (fun fields -> Alcotest.(check bool) "foreign ambiguous or booting response cannot enter" true
    (Result.is_error (decode fields progress)))
    [("keeper",`String "beta")::List.remove_assoc "keeper" fields;
     ("answer_progress_for",`String "other")::List.remove_assoc "answer_progress_for" fields;
     ("keeper",`String "alpha")::fields;
     ("state_ready",`Bool false)::List.remove_assoc "state_ready" fields];
  List.iter (fun progress -> Alcotest.(check bool) "malformed evidence cannot become an empty success" true
    (Result.is_error (decode fields progress)))
    [List.remove_assoc "reaction_evidence" progress;
     ("state",`String "unknown")::List.remove_assoc "state" progress;
     List.remove_assoc "linked_task" progress];
  let with_reactions value = ("reaction_evidence", value)::List.remove_assoc "reaction_evidence" progress in
  List.iter (fun bad -> Alcotest.(check bool) "malformed reaction evidence stays unavailable" true
    (Result.is_error (decode fields (with_reactions (`Assoc bad)))))
    [List.remove_assoc "turn_started_at" reactions;
     ("turn_started_at",`Float nan)::List.remove_assoc "turn_started_at" reactions;
     ("turn_started_at",`Null)::reactions;
     ("state",`String "unknown")::List.remove_assoc "state" reactions;
     List.remove_assoc "evidence_complete" reactions];
  let task = ["state",`String "observed";"task_id",`String "task-original";
    "location",`String "archive";"observed_at",`Float 203.;
    "status",`Assoc ["status",`String "done";"assignee",`String "other-worker";
      "completed_at",`String "2026-10-17T00:00:00Z";"notes",`String "must not retain"]] in
  let with_task value = ("linked_task",value)::List.remove_assoc "linked_task" progress in
  let observed_task = decode fields (with_task (`Assoc task)) |> Result.get_ok in
  Alcotest.(check bool) "original archived phase is independent of turn and Tool observations" true
    (match observed_task.af_linked_task with
     | Decode.Ask_task_observed value -> value.akt_task_id="task-original"
         && value.akt_location=Decode.Ask_task_archive && value.akt_evidence_current
         && (match value.akt_status with Masc_domain.Done {notes=None;_} -> true
             | Done {notes=Some _;_} | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _ -> false)
         && (match observed_task.af_reactions with
             | Decode.Ask_reactions_observed {ar_turn_finished_at=None;_} -> true
             | Ask_reactions_observed _ | Ask_reactions_unavailable -> false)
     | Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ -> false);
  let bad_task key value = (key,value)::List.remove_assoc key task in
  List.iter (fun bad -> Alcotest.(check bool) "malformed Task evidence cannot imply completion" true
    (Result.is_error (decode fields (with_task (`Assoc bad)))))
    [bad_task "state" (`String "completed");bad_task "task_id" (`String " ");
     bad_task "location" (`String "recovery");bad_task "observed_at" (`Float nan);
     ("task_id",`String "duplicate")::task;
     bad_task "status" (`Assoc ["status",`String "done"]);
     bad_task "status" (`Assoc ["status",`String "done";"assignee",`String " ";
       "completed_at",`String "2026-10-17T00:00:00Z"]);
     bad_task "status" (`Assoc ["status",`String "done";"assignee",`String "owner";
       "completed_at",`String "invalid"]);
     bad_task "status" (`Assoc ["status",`String "todo";"status",`String "done"]);
     bad_task "status" (`Assoc ["status",`String "awaiting_verification";
       "assignee",`String "owner";"started_at",`String "2026-10-17T00:00:00Z";
       "submitted_at",`String "2026-10-17T00:00:00Z";"verification_id",`String ""])];
  let actions = `Assoc ["state", `String "observed"; "observed_count", `Int 1;
    "outcomes", `Assoc ["succeeded",`Int 1;"deferred",`Int 0;"failed",`Int 0;
      "unsettled",`Int 0;"malformed",`Int 0];
    "first_recorded_at", `Float 202.; "latest", `Assoc ["execution_id", `String "logical-one";
      "physical_execution_id", `String "physical-one";
      "trace_id", `String "original-trace"; "keeper_turn_id", `Int 17;
      "tool", `String "Read"; "recorded_at", `Float 202.;"outcome",`String "succeeded"]] in
  let with_actions value = ("tool_actions", value)::List.remove_assoc "tool_actions" progress in
  let observed = match decode fields (with_actions actions) with
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  let partial_progress = ("reaction_evidence", `Assoc ["state", `String "unavailable"])
      :: List.remove_assoc "reaction_evidence" (with_task (`Assoc task)) in
  let partial_progress = ("tool_actions", actions)::List.remove_assoc "tool_actions" partial_progress in
  let partial = decode fields partial_progress |> Result.get_ok in
  Alcotest.(check bool) "unavailable reactions preserve independent Tool and original Task observations" true
    (partial.af_reactions=Decode.Ask_reactions_unavailable
      && (match partial.af_tool_actions with
          | Decode.Ask_tools_observed {at_count=1;_} -> true
          | Ask_tools_observed _ | Ask_tools_unavailable -> false)
      && (match partial.af_linked_task with
          | Decode.Ask_task_observed {akt_task_id="task-original";_} -> true
          | Ask_task_observed _ | Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ -> false));
  Alcotest.(check bool) "Tool evidence retains the exact physical invocation and input turn" true
    (match observed.af_tool_actions with
     | Decode.Ask_tools_observed {at_count=1;at_latest=Some action;_} ->
         action.ata_execution_id="logical-one" && action.ata_physical_execution_id="physical-one"
         && action.ata_trace_id="original-trace"
         && action.ata_keeper_turn_id=17
         && action.ata_outcome=Tool_result.Recorded_succeeded
     | Decode.Ask_tools_observed _ | Decode.Ask_tools_unavailable -> false);
  let replace_field key value = function
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> Alcotest.fail "fixture was not an object" in
  let outcomes = Yojson.Safe.Util.member "outcomes" actions in
  List.iter (fun broken -> Alcotest.(check bool) "outcome cohorts reject omission, excess, negative and duplicate buckets" true
      (Result.is_error (decode fields (with_actions (replace_field "outcomes" broken actions)))))
    [replace_field "succeeded" (`Int 0) outcomes;
     replace_field "failed" (`Int 1) outcomes;
     replace_field "deferred" (`Int (-1)) outcomes;
     (match outcomes with `Assoc values -> `Assoc (("succeeded",`Int 1)::values) | _ -> assert false)];
  let latest = Yojson.Safe.Util.member "latest" actions in
  let set_latest value = replace_field "latest" value actions in
  List.iter (fun tag -> Alcotest.(check bool) "latest result must have a known nonempty outcome bucket" true
      (Result.is_error (decode fields (with_actions (set_latest (replace_field "outcome" (`String tag) latest))))))
    ["failed";"unknown"];
  let failed = replace_field "outcomes"
      (replace_field "failed" (`Int 1) (replace_field "succeeded" (`Int 0) outcomes))
      (set_latest (replace_field "outcome" (`String "failed") latest)) in
  let failed_partial = decode fields (("tool_actions",failed)::List.remove_assoc "tool_actions" partial_progress)
      |> Result.get_ok in
  Alcotest.(check bool) "a failed Tool receipt survives unavailable reactions beside an independently done original Task" true
    (match failed_partial.af_tool_actions,failed_partial.af_linked_task,failed_partial.af_reactions with
     | Decode.Ask_tools_observed {at_outcomes={ato_failed=1;_};at_latest=Some {ata_outcome=Tool_result.Recorded_failed;_};_},
       Ask_task_observed {akt_status=Masc_domain.Done _;_}, Ask_reactions_unavailable -> true
     | _ -> false);
  let malformed_physical value = match actions with
    | `Assoc fields -> `Assoc (List.map (fun (key,latest) ->
        if key<>"latest" then key,latest else match latest with
          | `Assoc identity -> key,`Assoc (value @ List.remove_assoc "physical_execution_id" identity)
          | _ -> Alcotest.fail "latest identity is not an object") fields)
    | _ -> Alcotest.fail "Tool observation is not an object" in
  List.iter (fun physical -> Alcotest.(check bool) "physical identity must be present, nonempty and unambiguous" true
    (Result.is_error (decode fields (with_actions (malformed_physical physical)))))
    [[];["physical_execution_id",`String ""];
     ["physical_execution_id",`String "first";"physical_execution_id",`String "second"]];
  Alcotest.(check bool) "a count without matching Tool identities cannot be accepted" true
    (Result.is_error (decode fields (with_actions (`Assoc ["state",`String "observed";
       "observed_count",`Int 1; "outcomes",outcomes; "first_recorded_at",`Null; "latest",`Null]))))

let test_followup_stream_requires_each_original_source () =
  let module Decode = Masc.Tui_decode_asks in
  let frame ?(at=200.) ?(keeper="alpha") phase fields =
    `Assoc ["workspace",`Assoc ["base_path",`String "/workspace";"masc_root",`String "/workspace/.masc"];
      "state_ready",`Bool true;"keeper",`String keeper;"answer_progress_for",`String "ask-original";
      "answer_progress",`Assoc (["state",`String phase;"answered_at",`Float at;
        "stimulus_id",`String "original-source"] @ fields)] in
  let decode json = Decode.decode_ask_followup_event ~expected_base_path:"/workspace"
      ~expected_masc_root:"/workspace/.masc" ~keeper_name:"alpha" ~ask_id:"ask-original" json in
  let event phase fields = decode (frame phase fields) |> Result.get_ok in
  let source name value = event "source" ["source",`String name;"value",value] in
  let started = event "started" [] and completed = event "complete" [] in
  let task = source "linked_task" (`Assoc ["state",`String "unlinked"])
  and tools = source "tool_actions" (`Assoc ["state",`String "unavailable"])
  and reactions = source "reaction_evidence" (`Assoc ["state",`String "unavailable"]) in
  let accept stream event = Decode.accept_ask_followup_event stream event |> Result.get_ok in
  let reading = accept Decode.empty_ask_followup_stream started |> fun reading -> accept reading task in
  Alcotest.(check bool) "an early source does not claim a complete response" true
    (Result.is_error (Decode.finish_ask_followup_stream reading));
  List.iter (fun duplicate -> Alcotest.(check bool) "duplicate or premature terminal frames are refused" true
    (Result.is_error (Decode.accept_ask_followup_event reading duplicate))) [started;task;completed];
  let changed = decode (frame ~at:201. "source"
      ["source",`String "tool_actions";"value",`Assoc ["state",`String "unavailable"]]) |> Result.get_ok in
  Alcotest.(check bool) "another canonical answer time cannot finish an old source" true
    (Result.is_error (Decode.accept_ask_followup_event reading changed));
  Alcotest.(check bool) "another Keeper cannot borrow the stream" true
    (Result.is_error (decode (frame ~keeper:"beta" "started" [])));
  let complete = List.fold_left accept reading [tools;reactions;completed] in
  Alcotest.(check bool) "all independently settled sources authorize transport completion" true
    (Result.is_ok (Decode.finish_ask_followup_stream complete));
  Alcotest.(check bool) "a post-completion source cannot reopen a read" true
    (Result.is_error (Decode.accept_ask_followup_event complete task))

let () =
  Alcotest.run "TUI ask projection"
    [ ( "answer receipt",
        [ Alcotest.test_case "followup protocol preserves original identity and unknown evidence" `Quick
            test_followup_protocol_keeps_exact_identity_and_unknowns
        ; Alcotest.test_case "streamed followup requires each exact original source" `Quick
            test_followup_stream_requires_each_original_source
        ; Alcotest.test_case "question source is explicit and unambiguous" `Quick
            test_question_source_is_explicit_and_unambiguous
        ; Alcotest.test_case "retained feedback preserves original receipt and winner" `Quick
            test_feedback_preserves_receipt_and_canonical_winner
        ; Alcotest.test_case "recorded answer and wake outcome" `Quick
            test_recording_and_wake_delivery_are_separate
        ; Alcotest.test_case "canonical conflict and wake outcome" `Quick
            test_conflict_keeps_the_canonical_winner
        ; Alcotest.test_case "append proof without winner" `Quick
            test_unconfirmed_winner_is_not_a_recorded_submission
        ; Alcotest.test_case "foreign or incoherent evidence" `Quick
            test_answer_receipts_reject_incoherent_or_foreign_evidence
        ; Alcotest.test_case "refusal versus uncertainty" `Quick
            test_refusal_and_missing_recording_evidence_are_distinct
        ] );
      ( "wire",
        [ Alcotest.test_case "question reaches the answer draft" `Quick
            test_wire_question_reaches_the_answer_draft
        ; Alcotest.test_case "unknown resolution rejected" `Quick
            test_unknown_wire_resolution_is_rejected
        ; Alcotest.test_case "foreign or ambiguous workspace cannot clear questions" `Quick
            test_foreign_or_ambiguous_workspace_never_clears_questions
        ] );
      ( "draft",
        [
          Alcotest.test_case "keeps a matching ask" `Quick test_draft_for_keeps_matching_ask;
          Alcotest.test_case "resets on another ask" `Quick test_draft_for_resets_on_other_ask;
          Alcotest.test_case "clear removes" `Quick test_clear_removes;
          Alcotest.test_case "skip is an answer" `Quick test_skip_counts_as_answered;
        ] );
      ( "choices",
        [
          Alcotest.test_case "single replaces" `Quick test_single_replaces;
          Alcotest.test_case "single re-pick clears" `Quick test_single_repick_clears;
          Alcotest.test_case "multi keeps pick order" `Quick test_multi_keeps_pick_order;
          Alcotest.test_case "multi removes" `Quick test_multi_removes;
          Alcotest.test_case "multi emptied is unanswered" `Quick test_multi_emptied_is_unanswered;
        ] );
      ( "free text",
        [
          Alcotest.test_case "alternative for choices-only" `Quick
            test_free_text_slot_for_choices_only;
          Alcotest.test_case "next digit or t" `Quick test_alternative_shortcut;
          Alcotest.test_case "carries the hint" `Quick test_free_text_slot_carries_hint;
          Alcotest.test_case "names its question" `Quick
            test_free_text_slot_names_its_question;
          Alcotest.test_case "writes only its own ask" `Quick
            test_free_text_slot_writes_only_its_own_ask;
          Alcotest.test_case "records text" `Quick test_set_text_records;
          Alcotest.test_case "blank clears" `Quick test_blank_text_clears;
        ] );
      ( "readiness",
        [
          Alcotest.test_case "every gap at once" `Quick test_missing_lists_every_gap_at_once;
          Alcotest.test_case "shrinks as answered" `Quick test_missing_shrinks_as_answered;
          Alcotest.test_case "ask order wins" `Quick test_ready_follows_ask_order_not_draft_order;
          Alcotest.test_case "encodes each shape" `Quick test_ready_encodes_each_shape;
          Alcotest.test_case "answered is closed" `Quick test_answered_row_is_not_open;
          Alcotest.test_case "withdrawn is closed" `Quick test_withdrawn_row_is_not_open;
          Alcotest.test_case "foreign draft contributes nothing" `Quick
            test_foreign_draft_contributes_nothing;
        ] );
      ( "request",
        [
          Alcotest.test_case "omits blank session" `Quick test_request_body_omits_blank_session;
          Alcotest.test_case "carries session, no identity" `Quick test_request_body_carries_session_and_no_identity;
        ] );
      ( "gate",
        [
          Alcotest.test_case "blocked while inflight" `Quick test_gate_blocks_while_inflight;
          Alcotest.test_case "arms first" `Quick test_gate_arms_first;
          Alcotest.test_case "submits on second press" `Quick test_gate_submits_on_second_press;
          Alcotest.test_case "re-arms on a different ask" `Quick
            test_gate_rearms_on_a_different_ask;
        ] );
      ( "cursor",
        [
          Alcotest.test_case "follows the ask" `Quick test_cursor_follows_the_ask;
          Alcotest.test_case "releases when gone" `Quick test_cursor_releases_when_ask_is_gone;
          Alcotest.test_case "clamps" `Quick test_cursor_clamps_to_shorter_list;
          Alcotest.test_case "answered ask does not select the next" `Quick
            test_answered_ask_does_not_select_the_next;
          Alcotest.test_case "first read selects the first ask" `Quick
            test_first_read_selects_the_first_ask;
          Alcotest.test_case "released stays released" `Quick test_released_cursor_stays_released;
          Alcotest.test_case "move from released selects in place" `Quick
            test_move_from_released_selects_in_place;
          Alcotest.test_case "move clamps" `Quick test_move_clamps;
          Alcotest.test_case "move on empty list" `Quick test_move_on_empty_list_keeps_cursor;
          Alcotest.test_case "out of range selects nothing" `Quick
            test_out_of_range_position_selects_nothing;
        ] );
      ( "summary",
        [
        ] );
      ( "open rows",
        [
          Alcotest.test_case "keeps only what is waiting" `Quick
            test_open_rows_keeps_only_what_is_waiting;
        ] );
      ( "arrival",
        [
          Alcotest.test_case "silent on the first read" `Quick
            test_newly_opened_silent_on_first_read;
          Alcotest.test_case "reports an arrival" `Quick
            test_newly_opened_reports_arrival;
          Alcotest.test_case "silent on a re-read" `Quick
            test_newly_opened_silent_on_reread;
          Alcotest.test_case "ignores a closing ask" `Quick
            test_newly_opened_ignores_answered;
          Alcotest.test_case "rings off the asks surface" `Quick
            test_ring_when_arrival_and_not_watching;
          Alcotest.test_case "silent on the asks surface" `Quick
            test_silent_when_watching_asks;
          Alcotest.test_case "silent with no arrival" `Quick
            test_silent_when_nothing_arrived;
        ] );
    ]
