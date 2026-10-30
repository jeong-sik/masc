module Decode = Masc.Tui_decode_asks

type draft_response =
  | Draft_chose of string list
  | Draft_wrote of string
  | Draft_skipped

type draft = {
  d_ask : Decode.ask_key;
  d_responses : (string * draft_response) list;
}

type answer_feedback = {
  af_asker : Decode.ask_asker;
  af_ask_id : string;
  af_source_turn_ref : Ids.Turn_ref.t option;
  af_receipt : (Decode.answer_receipt, string) result;
  af_submitted_label : string option;
}

let answer_feedback ?source_turn_ref ~asker ~ask_id ~submitted_label receipt =
  let af_submitted_label = match receipt with
    | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_recorded _))
    | Ok (Decode.Installation_answer_receipt Decode.Installation_answer_recorded) -> Some submitted_label
    | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_already_recorded _
                                        | Decode.Ask_answer_written_unconfirmed _ | Decode.Ask_answer_refused _))
    | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_already_answered _
                                              | Decode.Installation_answer_withdrawn _
                                              | Decode.Installation_answer_refused _))
    | Error _ -> None in
  { af_asker = asker; af_ask_id = ask_id; af_source_turn_ref = source_turn_ref;
    af_receipt = receipt; af_submitted_label }

let asker_to_json = function
  | Decode.Ask_keeper name -> `Assoc ["keeper", `String name]
  | Decode.Ask_installation { ai_declaration_id; _ } -> `Assoc ["declaration_id", `String ai_declaration_id]

let answer_feedback_to_json feedback =
  let delivery = function
    | Decode.Ask_wake_stored -> `String "stored"
    | Decode.Ask_wake_pending _ -> `String "pending" in
  let recording, delivery = match feedback.af_receipt with
    | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_recorded outcome)) -> "recorded", delivery outcome
    | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_already_recorded { aar_delivery; _ })) ->
        "already_recorded", delivery aar_delivery
    | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_written_unconfirmed _)) -> "winner_unconfirmed", `Null
    | Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_refused _)) -> "refused", `Null
    | Ok (Decode.Installation_answer_receipt Decode.Installation_answer_recorded) -> "recorded", `Null
    | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_already_answered _)) ->
        "already_recorded", `Null
    | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_withdrawn _)) -> "withdrawn", `Null
    | Ok (Decode.Installation_answer_receipt (Decode.Installation_answer_refused _)) -> "refused", `Null
    | Error _ -> "unconfirmed", `Null in
  `Assoc ["asker", asker_to_json feedback.af_asker; "ask_id", `String feedback.af_ask_id;
    "source_turn_ref", (match feedback.af_source_turn_ref with
      | None -> `Null | Some reference -> Ids.Turn_ref.to_yojson reference);
    "recording", `String recording; "delivery", delivery]

type followup_failure =
  | Followup_read_failed of string
  | Followup_cancelled
  | Followup_not_started of string
  | Followup_withdrawn
type followup_result = (unit, followup_failure) result
let followup_failure_text = function
  | Followup_read_failed detail -> detail
  | Followup_cancelled -> "Answer follow-up observation cancelled; any received sources are retained."
  | Followup_not_started detail -> "Answer follow-up observation did not start: " ^ detail
  | Followup_withdrawn -> "Answer follow-up observation withdrawn; any received sources are retained."
let followup_result_to_json result =
  let state=match result with
    | Ok () -> "complete" | Error (Followup_read_failed _) -> "failed"
    | Error Followup_cancelled -> "cancelled" | Error (Followup_not_started _) -> "not_started"
    | Error Followup_withdrawn -> "withdrawn" in
  `Assoc ["state",`String state]

type followup_source_state = Followup_pending | Followup_received | Followup_unconfirmed
type 'a followup_observation = {
  fo_value : 'a option;
  fo_state : followup_source_state;
}
type followup_view = {
  fv_identity : Decode.ask_followup_identity option;
  fv_reactions : Decode.ask_reactions followup_observation;
  fv_tools : Decode.ask_tool_actions followup_observation;
  fv_task : Decode.ask_linked_task followup_observation;
}
type followup_phase = Followup_receiving | Followup_finished of followup_result
type followup = {
  fu_view : followup_view;
  fu_stream : Decode.ask_followup_stream;
  fu_phase : followup_phase;
}

let stale_reactions = function
  | Decode.Ask_reactions_observed old ->
      Decode.Ask_reactions_observed {old with ar_evidence_current=false}
  | Ask_reactions_unavailable -> Ask_reactions_unavailable

let stale_tools = function
  | Decode.Ask_tools_observed old -> Decode.Ask_tools_observed {old with at_evidence_current=false}
  | Ask_tools_unavailable -> Ask_tools_unavailable

let stale_task = function
  | Decode.Ask_task_observed old -> Decode.Ask_task_observed {old with akt_evidence_current=false}
  | (Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _) as old -> old

let begin_followup ~previous =
  let prior = Option.map (fun previous -> previous.fu_view) previous in
  let source stale project = {
    fo_value=Option.bind prior (fun view -> Option.map stale (project view).fo_value);
    fo_state=Followup_pending;
  } in
  {fu_view={fv_identity=Option.bind prior (fun view -> view.fv_identity);
     fv_reactions=source stale_reactions (fun view -> view.fv_reactions);
     fv_tools=source stale_tools (fun view -> view.fv_tools);
     fv_task=source stale_task (fun view -> view.fv_task)};
   fu_stream=Decode.empty_ask_followup_stream;fu_phase=Followup_receiving}

let followup_view reading = reading.fu_view

let merge_reactions (fresh : Decode.ask_reactions) (prior : Decode.ask_reactions option) =
  match fresh, prior with
  | Decode.Ask_reactions_unavailable, Some old -> stale_reactions old
  | Ask_reactions_observed fresh, Some (Ask_reactions_observed old) ->
      let retain fresh old = match fresh with Some _ -> fresh | None -> old in
      let needs_prior fresh old = Option.is_none fresh && Option.is_some old in
      let retained =
        needs_prior fresh.ar_turn_started_at old.ar_turn_started_at
        || needs_prior fresh.ar_turn_finished_at old.ar_turn_finished_at
        || needs_prior fresh.ar_queue_settled_at old.ar_queue_settled_at
        || needs_prior fresh.ar_queue_cancelled_at old.ar_queue_cancelled_at in
      Decode.Ask_reactions_observed {fresh with
        ar_evidence_current=fresh.ar_evidence_current && not retained;
        ar_turn_started_at=retain fresh.ar_turn_started_at old.ar_turn_started_at;
        ar_turn_finished_at=retain fresh.ar_turn_finished_at old.ar_turn_finished_at;
        ar_queue_settled_at=retain fresh.ar_queue_settled_at old.ar_queue_settled_at;
        ar_queue_cancelled_at=retain fresh.ar_queue_cancelled_at old.ar_queue_cancelled_at}
  | ((Ask_reactions_unavailable | Ask_reactions_observed _) as fresh),
      (None | Some Ask_reactions_unavailable) -> fresh

let merge_tools (fresh : Decode.ask_tool_actions) (prior : Decode.ask_tool_actions option) =
  match fresh, prior with
  | Decode.Ask_tools_unavailable, Some old -> stale_tools old
  | Ask_tools_observed fresh, Some (Ask_tools_observed old) when fresh.at_count < old.at_count ->
      Decode.Ask_tools_observed {old with at_evidence_current=false}
  | (Ask_tools_observed _ as fresh), (None | Some (Ask_tools_observed _ | Ask_tools_unavailable)) -> fresh
  | Ask_tools_unavailable, None -> Ask_tools_unavailable

let linked_id = function
  | Decode.Ask_task_unlinked -> None
  | Ask_task_missing id | Ask_task_unavailable id -> Some id
  | Ask_task_observed value -> Some value.akt_task_id

let merge_task (fresh : Decode.ask_linked_task) (prior : Decode.ask_linked_task option) =
  match prior with
  | Some old when linked_id old <> linked_id fresh ->
      Error "answer follow-up changed original linked Task identity"
  | Some old -> Ok (match fresh, old with
      | (Decode.Ask_task_missing _ | Ask_task_unavailable _), Ask_task_observed _ -> stale_task old
      | (Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ | Ask_task_observed _),
          (Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _ | Ask_task_observed _) -> fresh)
  | None -> Ok fresh

let observe_followup reading event =
  match reading.fu_phase with
  | Followup_finished _ -> Error "answer follow-up read has already finished"
  | Followup_receiving ->
    Result.bind (Decode.accept_ask_followup_event reading.fu_stream event) (fun stream ->
      let view = reading.fu_view in
      let identity = match event with
        | Decode.Ask_followup_started identity | Ask_followup_source (identity, _)
        | Ask_followup_completed identity -> identity in
      match view.fv_identity with
      | Some prior when prior.afi_answered_at <> identity.afi_answered_at
          || prior.afi_stimulus_id <> identity.afi_stimulus_id ->
          Error "answer follow-up changed original answer identity"
      | Some _ | None ->
        let received value = {fo_value=Some value;fo_state=Followup_received} in
        let updated = match event with
          | Decode.Ask_followup_started _ | Ask_followup_completed _ -> Ok view
          | Ask_followup_source (_, Ask_followup_reactions value) ->
              Ok {view with fv_reactions=received (merge_reactions value view.fv_reactions.fo_value)}
          | Ask_followup_source (_, Ask_followup_tools value) ->
              Ok {view with fv_tools=received (merge_tools value view.fv_tools.fo_value)}
          | Ask_followup_source (_, Ask_followup_task value) ->
              Result.map (fun value -> {view with fv_task=received value})
                (merge_task value view.fv_task.fo_value) in
        Result.map (fun view -> {reading with
          fu_view={view with fv_identity=Some identity};fu_stream=stream}) updated)

let followup_completion reading = match reading.fu_phase with
  | Followup_receiving -> None | Followup_finished result -> Some result
let finish_followup reading result = match reading.fu_phase with
  | Followup_finished prior -> reading,prior
  | Followup_receiving ->
    let result = match result with
      | Error _ as error -> error
      | Ok () -> Decode.finish_ask_followup_stream reading.fu_stream
          |> Result.map_error (fun detail -> Followup_read_failed detail) in
    let finish source = {source with fo_state=(match source.fo_state with
      | Followup_pending -> Followup_unconfirmed
      | (Followup_received | Followup_unconfirmed) as state -> state)} in
    let view = reading.fu_view in
    {reading with fu_phase=Followup_finished result;fu_view={view with
      fv_reactions=finish view.fv_reactions;fv_tools=finish view.fv_tools;fv_task=finish view.fv_task}}, result

let followup_to_json reading =
  let view = reading.fu_view in
  let clock = function None -> `Null | Some at -> `Float at in
  let source encode source = `Assoc [
    "state", `String (match source.fo_state with Followup_pending -> "pending"
      | Followup_received -> "received" | Followup_unconfirmed -> "unconfirmed");
    "observation", (match source.fo_value with None -> `Null | Some value -> encode value)] in
  let reactions = function
    | Decode.Ask_reactions_unavailable -> `Assoc ["state", `String "unavailable"]
    | Ask_reactions_observed value -> `Assoc ["state", `String "observed";
        "evidence_current", `Bool value.ar_evidence_current;
        "evidence_complete", `Bool value.ar_evidence_complete;
        "turn_started_at", clock value.ar_turn_started_at;
        "turn_finished_at", clock value.ar_turn_finished_at;
        "queue_settled_at", clock value.ar_queue_settled_at;
        "queue_cancelled_at", clock value.ar_queue_cancelled_at] in
  let tools = function
    | Decode.Ask_tools_unavailable -> `Assoc ["state", `String "unavailable"]
    | Ask_tools_observed value -> `Assoc (["state", `String "observed";
        "evidence_current", `Bool value.at_evidence_current;
        "observed_tool_results", `Int value.at_count;
        "tool_result_outcomes", `Assoc [
          "succeeded", `Int value.at_outcomes.ato_succeeded;
          "deferred", `Int value.at_outcomes.ato_deferred;
          "failed", `Int value.at_outcomes.ato_failed;
          "unsettled", `Int value.at_outcomes.ato_unsettled;
          "malformed", `Int value.at_outcomes.ato_malformed];
        "first_tool_result_recorded_at", clock value.at_first_recorded_at]
        @ (match value.at_latest with None -> [] | Some action ->
          ["latest_execution_id", `String action.ata_execution_id;
           "latest_physical_execution_id", `String action.ata_physical_execution_id;
           "latest_trace_id", `String action.ata_trace_id;
           "latest_keeper_turn_id", `Int action.ata_keeper_turn_id;
           "latest_outcome", `String (Tool_result.recorded_call_outcome_to_string action.ata_outcome);
           "latest_tool_result_recorded_at", `Float action.ata_recorded_at])) in
  let task = function
    | Decode.Ask_task_unlinked -> `Assoc ["state", `String "unlinked"]
    | Ask_task_missing id -> `Assoc ["state", `String "missing";"id", `String id]
    | Ask_task_unavailable id -> `Assoc ["state", `String "unavailable";"id", `String id]
    | Ask_task_observed value -> `Assoc ["state", `String "observed";"id", `String value.akt_task_id;
        "evidence_current", `Bool value.akt_evidence_current;
        "phase", `String (Masc_domain.task_status_to_string value.akt_status);
        "location", `String (match value.akt_location with Ask_task_backlog -> "backlog" | Ask_task_archive -> "archive");
        "observed_at", `Float value.akt_observed_at] in
  `Assoc ["completion", (match followup_completion reading with None -> `Null | Some result -> followup_result_to_json result);
    "identity", (match view.fv_identity with None -> `Null | Some identity ->
      `Assoc ["answered_at", `Float identity.afi_answered_at;"stimulus_id", `String identity.afi_stimulus_id]);
    "reaction_evidence", source reactions view.fv_reactions;
    "tool_actions", source tools view.fv_tools;"linked_task", source task view.fv_task]

type origin = {
  ao_keeper_name : string;
  ao_ask_id : string;
  ao_source_turn_ref : Ids.Turn_ref.t option;
}

let origin_of_row (row : Decode.ask_row) = match row.ar_asker with
  | Decode.Ask_keeper name ->
      Some {ao_keeper_name=name;ao_ask_id=row.ar_id;ao_source_turn_ref=row.ar_source_turn_ref}
  | Decode.Ask_installation _ -> None

let origin_of_feedback feedback = match feedback.af_asker with
  | Decode.Ask_keeper name ->
      Some {ao_keeper_name=name;ao_ask_id=feedback.af_ask_id;ao_source_turn_ref=feedback.af_source_turn_ref}
  | Decode.Ask_installation _ -> None

let same_origin left right =
  String.equal left.ao_keeper_name right.ao_keeper_name
  && String.equal left.ao_ask_id right.ao_ask_id
  && Option.equal Ids.Turn_ref.equal left.ao_source_turn_ref right.ao_source_turn_ref

let origin_to_json origin =
  `Assoc ["keeper",`String origin.ao_keeper_name;"ask_id",`String origin.ao_ask_id;
    "source_turn_ref",(match origin.ao_source_turn_ref with
      | None -> `Null | Some reference -> Ids.Turn_ref.to_yojson reference)]

let empty_draft ~ask = { d_ask = ask; d_responses = [] }
let draft_ask draft = draft.d_ask

let draft_for existing ~(row : Decode.ask_row) =
  match existing with
  | Some draft when Decode.equal_ask_key draft.d_ask (Decode.ask_key row) -> draft
  | Some _ | None -> empty_draft ~ask:(Decode.ask_key row)

let response_for draft ~(question : Decode.ask_question) =
  List.assoc_opt question.aq_id draft.d_responses

(* A human line for what the draft answers, in the labels the operator saw
   rather than the choice ids the wire carries: chosen labels joined per
   question, a written answer quoted, a skipped question named. Empty when the
   draft has answered nothing, so the caller can fall back to the Keeper name
   alone. *)
let summarize_answer draft ~(row : Decode.ask_row) =
  let per_question (question : Decode.ask_question) =
    match response_for draft ~question with
    | None -> None
    | Some (Draft_chose ids) ->
        let label_of id =
          List.find_opt
            (fun (choice : Decode.ask_choice) -> String.equal choice.ac_id id)
            question.aq_choices
          |> Option.map (fun (choice : Decode.ask_choice) -> choice.ac_label)
        in
        (match List.filter_map label_of ids with
         | [] -> None
         | labels -> Some (String.concat ", " labels))
    | Some (Draft_wrote text) -> Some (Printf.sprintf "\"%s\"" text)
    | Some Draft_skipped -> Some "skipped"
  in
  String.concat "; " (List.filter_map per_question row.ar_questions)

(* The asks still waiting on a human, in wire order. One filter for every
   caller: the panel draws these rows, the footer names the keys that work on
   the one under the cursor, and the executable answers it. Three copies of
   this predicate is how the cursor and the drawn list come to disagree about
   which ask is selected. *)
let open_rows (snapshot : Decode.asks_snapshot) =
  List.filter
    (fun (row : Decode.ask_row) ->
      match row.ar_resolution with
      | Decode.Ask_open -> true
      | Decode.Ask_answered _ | Decode.Ask_withdrawn _ -> false)
    snapshot.asn_rows

let open_asks (snapshot : Decode.asks_snapshot) = List.map Decode.ask_key (open_rows snapshot)

(* Asks open in [current] that were not open in [previous] — the questions
   that arrived since the last read. A poll that re-reads the same open asks
   returns none, and a first read (no previous) returns none rather than every
   open ask, so a caller rings once as each new question arrives and not for
   the state the session started in. *)
let newly_opened_asks ~previous ~current =
  match previous with
  | None -> []
  | Some previous ->
      let before = open_asks previous in
      List.filter (fun ask -> not (List.exists (Decode.equal_ask_key ask) before)) (open_asks current)

(* Ring for a question that just arrived only when the operator is not already
   watching the asks surface -- the panel is in front of them there, so a bell
   would say what they can see. [arrived] empty means nothing arrived. The
   watching flag is passed in rather than read here: the surface an operator is
   on, and later whether the window has focus, are the caller's to know. *)
let should_ring_for_new_ask ~arrived ~operator_is_watching_asks =
  (match arrived with [] -> false | _ :: _ -> true)
  && not operator_is_watching_asks

let without question_id responses =
  List.filter (fun (id, _) -> not (String.equal id question_id)) responses

let record draft ~question_id response =
  { draft with d_responses = (question_id, response) :: without question_id draft.d_responses }

let forget draft ~question_id =
  { draft with d_responses = without question_id draft.d_responses }

let clear draft ~(question : Decode.ask_question) =
  forget draft ~question_id:question.aq_id

let skip draft ~(question : Decode.ask_question) =
  record draft ~question_id:question.aq_id Draft_skipped

let selected_ids draft ~question_id =
  match List.assoc_opt question_id draft.d_responses with
  | Some (Draft_chose ids) -> ids
  | Some (Draft_wrote _) | Some Draft_skipped | None -> []

let toggle_choice draft ~(question : Decode.ask_question)
    ~(choice : Decode.ask_choice) =
  let question_id = question.aq_id in
  let chosen = selected_ids draft ~question_id in
  let already = List.exists (String.equal choice.ac_id) chosen in
  let next =
    match question.aq_mode with
    | Decode.Ask_single -> if already then [] else [ choice.ac_id ]
    | Decode.Ask_multi ->
        if already then List.filter (fun id -> not (String.equal id choice.ac_id)) chosen
        else chosen @ [ choice.ac_id ]
  in
  match next with
  | [] -> forget draft ~question_id
  | ids -> record draft ~question_id (Draft_chose ids)

type free_text_slot = {
  fts_ask : Decode.ask_key;
  fts_question_id : string;
  fts_hint : string option;
}

let free_text_slot ~ask (question : Decode.ask_question) =
  match question.aq_free_text with
  | Decode.Ask_free_text_allowed { aft_hint } ->
      { fts_ask = ask; fts_question_id = question.aq_id; fts_hint = aft_hint }
  | Decode.Ask_choices_only ->
      { fts_ask = ask; fts_question_id = question.aq_id; fts_hint = None }

(* Digits are single-key shortcuts. Above eight offered choices, [t] remains
   the unambiguous text key; a two-digit "10" would select "1" first. *)
let alternative_position (question : Decode.ask_question) =
  let count = List.length question.aq_choices in
  if count > 0 && count < 9 then Some (count + 1) else None

let free_text_hint slot = slot.fts_hint
let free_text_ask slot = slot.fts_ask
let free_text_question_id slot = slot.fts_question_id

(* Question ids are only unique inside one ask (masc_ask numbers every ask's
   questions from q1), so a slot writes into its own ask's draft and nowhere
   else. *)
let set_text draft ~slot ~text =
  let question_id = slot.fts_question_id in
  if not (Decode.equal_ask_key draft.d_ask slot.fts_ask) then draft
  else if String.trim text = "" then forget draft ~question_id
  else record draft ~question_id (Draft_wrote text)

let response_json = function
  | Draft_chose ids ->
      `Assoc
        [
          ("kind", `String "chose");
          ("choice_ids", `List (List.map (fun id -> `String id) ids));
        ]
  | Draft_wrote text -> `Assoc [ ("kind", `String "wrote"); ("text", `String text) ]
  | Draft_skipped -> `Assoc [ ("kind", `String "skipped") ]

let answer_json question_id response =
  `Assoc [ ("question_id", `String question_id); ("response", response_json response) ]

type readiness =
  | Ready of Yojson.Safe.t
  | Missing of Decode.ask_question list
  | Not_open

let readiness draft ~(row : Decode.ask_row) =
  match row.ar_resolution with
  | Decode.Ask_answered _ | Decode.Ask_withdrawn _ -> Not_open
  | Decode.Ask_open ->
      let belongs = Decode.equal_ask_key draft.d_ask (Decode.ask_key row) in
      let paired =
        List.map
          (fun (question : Decode.ask_question) ->
            let response =
              if belongs then List.assoc_opt question.aq_id draft.d_responses else None
            in
            (question, response))
          row.ar_questions
      in
      let missing =
        List.filter_map
          (fun (question, response) -> if response = None then Some question else None)
          paired
      in
      if missing <> [] then Missing missing
      else
        Ready
          (`List
            (List.filter_map
               (fun ((question : Decode.ask_question), response) ->
                 Option.map (answer_json question.aq_id) response)
               paired))

let request_body ~answers ~session_id =
  let session =
    match session_id with
    | Some value when String.trim value <> "" -> [ ("session_id", `String value) ]
    | Some _ | None -> []
  in
  `Assoc (("answers", answers) :: session)

let installation_request_body ~declaration_id ~ask_id ~answers ~session_id =
  match request_body ~answers ~session_id with
  | `Assoc fields -> `Assoc (("declaration_id", `String declaration_id) :: ("ask_id", `String ask_id) :: fields)
  | other -> other

type gate =
  | Ask_gate_blocked_inflight
  | Ask_gate_arm of Decode.ask_key
  | Ask_gate_submit

let gate_transition ~inflight ~pending ~ask =
  if inflight then Ask_gate_blocked_inflight
  else
    match pending with
    | Some armed when Decode.equal_ask_key armed ask -> Ask_gate_submit
    | Some _ | None -> Ask_gate_arm ask

type cursor = On of int | Released of int

let initial_cursor = On 0

let bounded_position ~position rows = min (max 0 position) (max 0 (List.length rows - 1))

let reconcile_cursor ~current_rows ~cursor ~next_rows =
  match cursor with
  | Released position -> Released (bounded_position ~position next_rows)
  | On position -> (
      match List.nth_opt current_rows (max 0 position) with
      (* No ask was under the cursor -- the list was empty or not read yet --
         so the operator has not chosen anything that could go missing. *)
      | None -> On (bounded_position ~position next_rows)
      | Some (selected : Decode.ask_row) -> (
          match
            List.find_index
              (fun (row : Decode.ask_row) -> Decode.equal_ask_key (Decode.ask_key selected) (Decode.ask_key row))
              next_rows
          with
          | Some index -> On index
          | None -> Released (bounded_position ~position next_rows)))

let selected_index rows = function
  | Released _ -> None
  | On position ->
      if position >= 0 && position < List.length rows then Some position else None

let selected_row rows cursor =
  Option.bind (selected_index rows cursor) (List.nth_opt rows)

let move_cursor rows cursor ~delta =
  match (rows, cursor) with
  | [], _ -> cursor
  | _ :: _, Released position -> On (bounded_position ~position rows)
  | _ :: _, On position -> On (bounded_position ~position:(position + delta) rows)
