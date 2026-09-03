module Decode = Masc.Tui_decode

type draft_response =
  | Draft_chose of string list
  | Draft_wrote of string
  | Draft_skipped

type draft = {
  d_ask_id : string;
  d_responses : (string * draft_response) list;
}

let empty_draft ~ask_id = { d_ask_id = ask_id; d_responses = [] }
let draft_ask_id draft = draft.d_ask_id

let draft_for existing ~(row : Decode.ask_row) =
  match existing with
  | Some draft when String.equal draft.d_ask_id row.ar_id -> draft
  | Some _ | None -> empty_draft ~ask_id:row.ar_id

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

let open_ask_ids (snapshot : Decode.asks_snapshot) =
  List.filter_map
    (fun (row : Decode.ask_row) ->
      match row.ar_resolution with
      | Decode.Ask_open -> Some row.ar_id
      | Decode.Ask_answered _ | Decode.Ask_withdrawn _ -> None)
    snapshot.asn_rows

(* Ask ids open in [current] that were not open in [previous] — the questions
   that arrived since the last read. A poll that re-reads the same open asks
   returns none, and a first read (no previous) returns none rather than every
   open ask, so a caller rings once as each new question arrives and not for
   the state the session started in. *)
let newly_opened_ask_ids ~previous ~current =
  match previous with
  | None -> []
  | Some previous ->
      let before = open_ask_ids previous in
      List.filter (fun id -> not (List.mem id before)) (open_ask_ids current)

(* Ring for a question that just arrived only when the operator is not already
   watching the asks surface -- the panel is in front of them there, so a bell
   would say what they can see. [new_ids] empty means nothing arrived. The
   watching flag is passed in rather than read here: the surface an operator is
   on, and later whether the window has focus, are the caller's to know. *)
let should_ring_for_new_ask ~new_ids ~operator_is_watching_asks =
  (match new_ids with [] -> false | _ :: _ -> true)
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

type free_text_slot = { fts_question_id : string; fts_hint : string option }

let free_text_slot (question : Decode.ask_question) =
  match question.aq_free_text with
  | Decode.Ask_free_text_allowed { aft_hint } ->
      Some { fts_question_id = question.aq_id; fts_hint = aft_hint }
  | Decode.Ask_choices_only -> None

let free_text_hint slot = slot.fts_hint

let set_text draft ~slot ~text =
  let question_id = slot.fts_question_id in
  if String.trim text = "" then forget draft ~question_id
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
      let belongs = String.equal draft.d_ask_id row.ar_id in
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

let request_body ~answers ~actor_id ~session_id =
  let optional key = function
    | Some value when String.trim value <> "" -> [ (key, `String value) ]
    | Some _ | None -> []
  in
  `Assoc
    (("answers", answers) :: (optional "actor_id" actor_id @ optional "session_id" session_id))

type gate =
  | Ask_gate_blocked_inflight
  | Ask_gate_arm of string
  | Ask_gate_submit

let gate_transition ~inflight ~pending ~ask_id =
  if inflight then Ask_gate_blocked_inflight
  else
    match pending with
    | Some armed when String.equal armed ask_id -> Ask_gate_submit
    | Some _ | None -> Ask_gate_arm ask_id

let fallback_cursor ~cursor rows = min (max 0 cursor) (max 0 (List.length rows - 1))

let reconcile_cursor ~current_rows ~cursor ~next_rows =
  let selected =
    if cursor < 0 then None
    else Option.map (fun (row : Decode.ask_row) -> row.ar_id) (List.nth_opt current_rows cursor)
  in
  match selected with
  | Some ask_id -> (
      match
        List.find_index (fun (row : Decode.ask_row) -> String.equal ask_id row.ar_id) next_rows
      with
      | Some index -> index
      | None -> fallback_cursor ~cursor next_rows)
  | None -> fallback_cursor ~cursor next_rows
