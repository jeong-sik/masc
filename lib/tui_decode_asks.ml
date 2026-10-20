let member key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> value
  | None -> `Null

type ask_choice = {
  ac_id : string;
  ac_label : string;
  ac_description : string option;
}

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_free_text =
  | Ask_free_text_allowed of { aft_hint : string option }
  | Ask_choices_only

type ask_question = {
  aq_id : string;
  aq_header : string;
  aq_prompt : string;
  aq_mode : ask_mode;
  aq_free_text : ask_free_text;
  aq_choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of {
      aa_answered_at : float;
      aa_question_ids : string list;
    }
  | Ask_withdrawn of {
      aw_reason : string;
      aw_withdrawn_at : float;
    }

type ask_asker =
  | Ask_keeper of string
  | Ask_installation of { ai_declaration_id : string; ai_title : string }

let ask_asker_label = function
  | Ask_keeper name -> name
  | Ask_installation { ai_title; _ } -> ai_title

type ask_row = {
  ar_asker : ask_asker;
  ar_id : string;
  ar_asked_at : float;
  ar_source_turn_ref : Ids.Turn_ref.t option;
  ar_context : string option;
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

type ask_key = { ak_asker : ask_asker; ak_id : string }

let ask_key (row : ask_row) = { ak_asker = row.ar_asker; ak_id = row.ar_id }

let equal_ask_asker left right = match left, right with
  | Ask_keeper left, Ask_keeper right -> String.equal left right
  | Ask_installation left, Ask_installation right ->
      String.equal left.ai_declaration_id right.ai_declaration_id
  | Ask_keeper _, Ask_installation _ | Ask_installation _, Ask_keeper _ -> false

let equal_ask_key left right =
  String.equal left.ak_id right.ak_id && equal_ask_asker left.ak_asker right.ak_asker

type asks_snapshot = {
  asn_keeper : string option;
  asn_open_count : int;
  asn_rows : ask_row list;
}

let ( let* ) = Result.bind

let ask_string json key =
  match member key json with
  | `String s -> Ok s
  | `Null -> Error (Printf.sprintf "asks: '%s' is required" key)
  | _ -> Error (Printf.sprintf "asks: '%s' must be a string" key)

let ask_string_opt json key =
  match member key json with `String s -> Some s | _ -> None

let ask_float json key =
  match member key json with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error (Printf.sprintf "asks: '%s' must be a number" key)

let ask_int json key =
  match member key json with
  | `Int i -> Ok i
  | _ -> Error (Printf.sprintf "asks: '%s' must be an integer" key)

let ask_list json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> Ok []
  | _ -> Error (Printf.sprintf "asks: '%s' must be an array" key)

let rec ask_map_results f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = ask_map_results f rest in
      Ok (y :: ys)

let decode_ask_choice json =
  let* ac_id = ask_string json "choice_id" in
  let* ac_label = ask_string json "label" in
  Ok { ac_id; ac_label; ac_description = ask_string_opt json "description" }

let decode_ask_mode json =
  let* label = ask_string json "mode" in
  match label with
  | "single" -> Ok Ask_single
  | "multi" -> Ok Ask_multi
  | other -> Error (Printf.sprintf "asks: unknown mode '%s'" other)

let decode_ask_free_text json =
  match member "free_text" json with
  | `Null -> Ok Ask_choices_only
  | free_text_json -> (
      match member "allowed" free_text_json with
      | `Bool false -> Ok Ask_choices_only
      | `Bool true ->
          Ok (Ask_free_text_allowed { aft_hint = ask_string_opt free_text_json "hint" })
      | `Null -> Error "asks: free_text is missing 'allowed'"
      | _ -> Error "asks: free_text.allowed must be a boolean")

let decode_ask_question json =
  let* aq_id = ask_string json "question_id" in
  let* aq_header = ask_string json "header" in
  let* aq_prompt = ask_string json "prompt" in
  let* aq_mode = decode_ask_mode json in
  let* aq_free_text = decode_ask_free_text json in
  let* choice_items = ask_list json "choices" in
  let* aq_choices = ask_map_results decode_ask_choice choice_items in
  Ok { aq_id; aq_header; aq_prompt; aq_mode; aq_free_text; aq_choices }

let decode_ask_resolution json =
  let* state = ask_string json "state" in
  match state with
  | "open" -> Ok Ask_open
  | "answered" ->
      let* aa_answered_at = ask_float json "answered_at" in
      let* id_items = ask_list json "answered_question_ids" in
      let* aa_question_ids =
        ask_map_results
          (function
            | `String id -> Ok id
            | _ -> Error "asks: answered_question_ids must be strings")
          id_items
      in
      Ok (Ask_answered { aa_answered_at; aa_question_ids })
  | "withdrawn" ->
      let* aw_reason = ask_string json "reason" in
      let* aw_withdrawn_at = ask_float json "withdrawn_at" in
      Ok (Ask_withdrawn { aw_reason; aw_withdrawn_at })
  | other -> Error (Printf.sprintf "asks: unknown resolution state '%s'" other)

let decode_ask_row json =
  let* keeper = ask_string json "keeper" in
  let* ar_id = ask_string json "ask_id" in
  let* ar_asked_at = ask_float json "asked_at" in
  let* ar_source_turn_ref = match json with
    | `Assoc fields ->
        (match List.filter (fun (key,_) -> String.equal key "source_turn_ref") fields with
         | [_,`Null] -> Ok None
         | [_,value] -> Ids.Turn_ref.of_yojson value |> Result.map Option.some
         | [] | _::_ -> Error "asks: exactly one source_turn_ref is required")
    | _ -> Error "asks: a question row must be an object" in
  let* question_items = ask_list json "questions" in
  let* ar_questions = ask_map_results decode_ask_question question_items in
  let* ar_resolution = decode_ask_resolution (member "resolution" json) in
  Ok
    {
      ar_asker = Ask_keeper keeper;
      ar_id;
      ar_asked_at;
      ar_source_turn_ref;
      ar_context = ask_string_opt json "context";
      ar_questions;
      ar_resolution;
    }

let validate_asks_workspace ~expected_base_path ~expected_masc_root json =
    match json with
    | `Assoc fields ->
      let* () = match List.filter (fun (name,_) -> String.equal name "state_ready") fields with
        | [_, `Bool true] -> Ok ()
        | _ -> Error "asks: response workspace readiness is unconfirmed" in
      (match List.filter (fun (name,_) -> String.equal name "workspace") fields with
       | [_, `Assoc workspace] when List.length workspace=2 ->
         (match List.assoc_opt "base_path" workspace, List.assoc_opt "masc_root" workspace with
          | Some (`String base), Some (`String root)
            when expected_base_path<>"" && expected_masc_root<>"" &&
              not (Filename.is_relative expected_base_path) &&
              not (Filename.is_relative expected_masc_root) &&
              String.equal base expected_base_path && String.equal root expected_masc_root -> Ok ()
          | _ -> Error "asks: response workspace does not match this request")
       | _ -> Error "asks: one complete response workspace is required")
    | _ -> Error "asks: response must be an object"

let decode_asks_snapshot ~expected_base_path ~expected_masc_root json =
  let* () = validate_asks_workspace ~expected_base_path ~expected_masc_root json in
  let asn_keeper = ask_string_opt json "keeper" in
  let* asn_open_count = ask_int json "open_count" in
  let* row_items = ask_list json "asks" in
  let* asn_rows = ask_map_results decode_ask_row row_items in
  Ok { asn_keeper; asn_open_count; asn_rows }

let installation_row_fields =
  [ "declaration_id"; "title"; "ask_id"; "asked_at"; "context"; "questions"; "resolution" ]

let decode_installation_ask_row = function
  | `Assoc fields as json ->
      let names = List.map fst fields in
      if List.sort String.compare names <> List.sort String.compare installation_row_fields then
        Error "installation asks: a row has exactly declaration_id, title, ask_id, asked_at, \
               context, questions and resolution"
      else
        let* ai_declaration_id = ask_string json "declaration_id" in
        let* ai_title = ask_string json "title" in
        let* ar_id = ask_string json "ask_id" in
        let* ar_asked_at = ask_float json "asked_at" in
        let* ar_context = match member "context" json with
          | `Null -> Ok None
          | `String text -> Ok (Some text)
          | _ -> Error "installation asks: context must be a string or null" in
        let* question_items = ask_list json "questions" in
        let* ar_questions = ask_map_results decode_ask_question question_items in
        let* ar_resolution = decode_ask_resolution (member "resolution" json) in
        Ok { ar_asker = Ask_installation { ai_declaration_id; ai_title }; ar_id; ar_asked_at;
             ar_source_turn_ref = None; ar_context; ar_questions; ar_resolution }
  | _ -> Error "installation asks: a row must be an object"

let decode_installation_asks = function
  | `Assoc [ "asks", `List rows ] -> ask_map_results decode_installation_ask_row rows
  | _ -> Error "installation asks: the response is exactly {\"asks\": [...]}"

type installation_answer_receipt =
  | Installation_answer_recorded
  | Installation_answer_already_answered of { iaa_answered_at : float }
  | Installation_answer_withdrawn of { iaw_withdrawn_at : float }
  | Installation_answer_refused of string

let decode_installation_answer_receipt ~expected_declaration_id ~expected_ask_id ~status_code json =
  let named key expected =
    match member key json with
    | `String value when String.equal value expected -> Ok ()
    | _ -> Error (Printf.sprintf "installation answer: the receipt does not name %s %s" key expected) in
  let error_text () = match member "error" json with
    | `String text -> Ok text
    | _ -> Error "installation answer: a refusal carries its error" in
  match status_code with
  | 200 ->
      let* () = named "declaration_id" expected_declaration_id in
      let* () = named "ask_id" expected_ask_id in
      (match member "recorded" json with
       | `Bool true -> Ok Installation_answer_recorded
       | _ -> Error "installation answer: a 200 receipt says recorded = true")
  | 409 ->
      let* () = named "ask_id" expected_ask_id in
      (match member "state" json with
       | `String "answered" ->
           let* iaa_answered_at = ask_float json "answered_at" in
           Ok (Installation_answer_already_answered { iaa_answered_at })
       | `String "withdrawn" ->
           let* iaw_withdrawn_at = ask_float json "withdrawn_at" in
           Ok (Installation_answer_withdrawn { iaw_withdrawn_at })
       | _ -> Error "installation answer: a conflict names answered or withdrawn")
  | 400 ->
      let* text = error_text () in
      let* reasons = ask_list json "invalid_answers" in
      let* reasons =
        List.fold_right (fun reason acc ->
            let* acc = acc in
            match reason with
            | `String reason -> Ok (reason :: acc)
            | _ -> Error "installation answer: every invalid answer is a string")
          reasons (Ok [])
      in
      Ok (Installation_answer_refused (String.concat "; " (text :: reasons)))
  | 404 ->
      let* text = error_text () in
      Ok (Installation_answer_refused text)
  | status ->
      (* A 500 or anything else leaves recording unconfirmed, not refused. *)
      Error (Printf.sprintf "installation answer: HTTP %d leaves the answer unconfirmed" status)

let with_installation_asks snapshot rows =
  let open_rows = List.filter (fun row -> match row.ar_resolution with
    | Ask_open -> true | Ask_answered _ | Ask_withdrawn _ -> false) rows in
  { snapshot with asn_open_count = snapshot.asn_open_count + List.length open_rows;
                  asn_rows = snapshot.asn_rows @ rows }

type ask_tool_action = {
  ata_execution_id : string;
  ata_physical_execution_id : string;
  ata_trace_id : string;
  ata_keeper_turn_id : int;
  ata_tool : string;
  ata_recorded_at : float;
  ata_outcome : Tool_result.recorded_call_outcome;
}

type ask_tool_outcomes = {
  ato_succeeded : int; ato_deferred : int; ato_failed : int;
  ato_unsettled : int; ato_malformed : int;
}
type ask_tool_actions =
  | Ask_tools_unavailable
  | Ask_tools_observed of {
      at_count : int;
      at_outcomes : ask_tool_outcomes;
      at_first_recorded_at : float option;
      at_latest : ask_tool_action option;
      at_evidence_current : bool;
    }

type ask_task_location = Ask_task_backlog | Ask_task_archive
type ask_linked_task =
  | Ask_task_unlinked
  | Ask_task_missing of string
  | Ask_task_unavailable of string
  | Ask_task_observed of {
      akt_task_id : string;
      akt_location : ask_task_location;
      akt_status : Masc_domain.task_status;
      akt_observed_at : float;
      akt_evidence_current : bool;
    }

type ask_reactions =
  | Ask_reactions_unavailable
  | Ask_reactions_observed of {
      ar_turn_started_at : float option;
      ar_turn_finished_at : float option;
      ar_queue_settled_at : float option;
      ar_queue_cancelled_at : float option;
      ar_evidence_complete : bool;
      ar_evidence_current : bool;
    }

type ask_followup = {
  af_answered_at : float;
  af_stimulus_id : string;
  af_reactions : ask_reactions;
  af_tool_actions : ask_tool_actions;
  af_linked_task : ask_linked_task;
}

let followup_field json name = match json with
  | `Assoc fields ->
    (match List.filter (fun (key,_) -> String.equal key name) fields with
     | [_,value] -> Ok value
     | _ -> Error ("answer follow-up field is missing or duplicated: " ^ name))
  | _ -> Error "answer follow-up must be an object"

let followup_string json name =
  let* value = followup_field json name in
  match value with `String value -> Ok value | _ -> Error ("invalid answer follow-up string: " ^ name)

let followup_finite = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error "answer follow-up clock is not finite"

let decode_followup_reactions reactions =
  let single = followup_field and string = followup_string and finite = followup_finite in
        let* reaction_state = string reactions "state" in
        match reaction_state with
          | "unavailable" -> Ok Ask_reactions_unavailable
          | "observed" ->
            let clock name = let* value = single reactions name in match value with
              | `Null -> Ok None
              | value -> finite value |> Result.map Option.some in
            let* ar_turn_started_at = clock "turn_started_at" in
            let* ar_turn_finished_at = clock "turn_finished_at" in
            let* ar_queue_settled_at = clock "queue_settled_at" in
            let* ar_queue_cancelled_at = clock "queue_cancelled_at" in
            let* complete = single reactions "evidence_complete" in
            let* ar_evidence_complete = match complete with
              | `Bool value -> Ok value
              | _ -> Error "answer follow-up evidence completeness is invalid" in
            Ok (Ask_reactions_observed {ar_turn_started_at;ar_turn_finished_at;
              ar_queue_settled_at;ar_queue_cancelled_at;ar_evidence_complete;ar_evidence_current=true})
          | _ -> Error "answer follow-up reaction evidence state is invalid"

let decode_followup_tools actions =
  let single = followup_field and string = followup_string and finite = followup_finite in
        let* action_state = string actions "state" in
        match action_state with
          | "unavailable" -> Ok Ask_tools_unavailable
          | "observed" ->
              let* count = single actions "observed_count" in
              let* at_count = match count with
                | `Int value when value>=0 -> Ok value
                | _ -> Error "answer Tool observation count is invalid" in
              let* outcomes = single actions "outcomes" in
              let outcome_count key = let* value = single outcomes key in match value with
                | `Int value when value>=0 -> Ok value
                | _ -> Error "answer Tool outcome count is invalid" in
              let* ato_succeeded = outcome_count "succeeded" in
              let* ato_deferred = outcome_count "deferred" in
              let* ato_failed = outcome_count "failed" in
              let* ato_unsettled = outcome_count "unsettled" in
              let* ato_malformed = outcome_count "malformed" in
              let* remaining = List.fold_left (fun remaining value ->
                  let* remaining = remaining in
                  if value>remaining then Error "answer Tool outcome counts exceed observations"
                  else Ok (remaining-value)) (Ok at_count)
                [ato_succeeded;ato_deferred;ato_failed;ato_unsettled;ato_malformed] in
              let* () = if remaining=0 then Ok () else Error "answer Tool outcome counts omit observations" in
              let at_outcomes = {ato_succeeded;ato_deferred;ato_failed;ato_unsettled;ato_malformed} in
              let* first = single actions "first_recorded_at" in
              let* at_first_recorded_at = match first with
                | `Null -> Ok None | value -> finite value |> Result.map Option.some in
              let* latest = single actions "latest" in
              let* at_latest = match latest with
                | `Null -> Ok None
                | value ->
                    let nonempty key = let* text = string value key in
                      if text="" then Error ("empty Tool observation " ^ key) else Ok text in
                    let* ata_execution_id = nonempty "execution_id" in
                    let* ata_physical_execution_id = nonempty "physical_execution_id" in
                    let* ata_trace_id = nonempty "trace_id" in
                    let* ata_tool = nonempty "tool" in
                    let* turn = single value "keeper_turn_id" in
                    let* ata_keeper_turn_id = match turn with
                      | `Int n when n>=0 -> Ok n | _ -> Error "answer Tool turn identity is invalid" in
                    let* recorded = single value "recorded_at" in
                    let* ata_recorded_at = finite recorded in
                    let* outcome = string value "outcome" in
                    let* ata_outcome = Tool_result.recorded_call_outcome_of_string outcome in
                    let bucket = match ata_outcome with
                      | Tool_result.Recorded_succeeded -> ato_succeeded
                      | Recorded_deferred -> ato_deferred
                      | Recorded_failed -> ato_failed
                      | Recorded_unsettled -> ato_unsettled
                      | Recorded_malformed -> ato_malformed in
                    let* () = if bucket>0 then Ok () else Error "latest Tool outcome is absent from counts" in
                    Ok (Some {ata_execution_id;ata_physical_execution_id;ata_trace_id;ata_keeper_turn_id;ata_tool;ata_recorded_at;ata_outcome}) in
              (match at_count, at_first_recorded_at, at_latest with
               | 0, None, None -> Ok (Ask_tools_observed {at_count;at_outcomes;at_first_recorded_at;at_latest;at_evidence_current=true})
               | n, Some first, Some last when n>0 && first<=last.ata_recorded_at ->
                   Ok (Ask_tools_observed {at_count;at_outcomes;at_first_recorded_at;at_latest;at_evidence_current=true})
               | _ -> Error "answer Tool count and observation clocks disagree")
          | _ -> Error "unknown answer Tool observation state"

let decode_followup_task linked =
  let single = followup_field and string = followup_string and finite = followup_finite in
        let* linked_state = string linked "state" in
        let task_id () = let* value = string linked "task_id" in
          if String.trim value = "" then Error "linked Task identity is blank" else Ok value in
        match linked_state with
          | "unlinked" ->
              (match linked with
               | `Assoc [_] -> Ok Ask_task_unlinked
               | _ -> Error "unlinked Task observation contains a binding or extra evidence")
          | "missing" -> let* id = task_id () in Ok (Ask_task_missing id)
          | "unavailable" -> let* id = task_id () in Ok (Ask_task_unavailable id)
          | "observed" ->
              let* akt_task_id = task_id () in
              let* location = string linked "location" in
              let* akt_location = match location with
                | "backlog" -> Ok Ask_task_backlog | "archive" -> Ok Ask_task_archive
                | _ -> Error "unknown linked Task location" in
              let* observed_at = single linked "observed_at" in
              let* akt_observed_at = finite observed_at in
              let* status = single linked "status" in
              let* akt_status = Task_status_observation.of_yojson status in
              Ok (Ask_task_observed {akt_task_id; akt_location; akt_status; akt_observed_at;
                akt_evidence_current = true})
          | _ -> Error "unknown linked Task observation state"

type ask_followup_identity = { afi_answered_at : float; afi_stimulus_id : string }
type ask_followup_source =
  | Ask_followup_reactions of ask_reactions
  | Ask_followup_tools of ask_tool_actions
  | Ask_followup_task of ask_linked_task
type ask_followup_event =
  | Ask_followup_started of ask_followup_identity
  | Ask_followup_source of ask_followup_identity * ask_followup_source
  | Ask_followup_completed of ask_followup_identity

let decode_followup_context ~expected_base_path ~expected_masc_root ~keeper_name ~ask_id json =
  let* () = validate_asks_workspace ~expected_base_path ~expected_masc_root json in
  let* keeper = followup_string json "keeper" in
  let* answer_id = followup_string json "answer_progress_for" in
  if not (String.equal keeper keeper_name && String.equal answer_id ask_id) then
    Error "answer follow-up belongs to a different Keeper or question"
  else followup_field json "answer_progress"

let decode_followup_identity progress =
  let* answered_at = followup_field progress "answered_at" in
  let* afi_answered_at = followup_finite answered_at in
  let* afi_stimulus_id = followup_string progress "stimulus_id" in
  if String.equal afi_stimulus_id "" then Error "answer follow-up source identity is empty"
  else Ok {afi_answered_at;afi_stimulus_id}

let decode_ask_followup ~expected_base_path ~expected_masc_root ~keeper_name ~ask_id json =
  let* progress = decode_followup_context ~expected_base_path ~expected_masc_root ~keeper_name ~ask_id json in
  let* state = followup_string progress "state" in
  match state with
  | "unavailable" -> Error "answer follow-up evidence is unavailable"
  | "observed" ->
    let* identity = decode_followup_identity progress in
    let* reactions = followup_field progress "reaction_evidence" in
    let* af_reactions = decode_followup_reactions reactions in
    let* tools = followup_field progress "tool_actions" in
    let* af_tool_actions = decode_followup_tools tools in
    let* task = followup_field progress "linked_task" in
    let* af_linked_task = decode_followup_task task in
    Ok {af_answered_at=identity.afi_answered_at;af_stimulus_id=identity.afi_stimulus_id;
      af_reactions;af_tool_actions;af_linked_task}
  | _ -> Error "unknown answer follow-up state"

let decode_ask_followup_event ~expected_base_path ~expected_masc_root ~keeper_name ~ask_id json =
  let* progress = decode_followup_context ~expected_base_path ~expected_masc_root ~keeper_name ~ask_id json in
  let* identity = decode_followup_identity progress in
  let* phase = followup_string progress "state" in
  match phase with
  | "started" -> Ok (Ask_followup_started identity)
  | "complete" -> Ok (Ask_followup_completed identity)
  | "source" ->
    let* source = followup_string progress "source" in
    let* value = followup_field progress "value" in
    let* source = match source with
      | "reaction_evidence" -> decode_followup_reactions value |> Result.map (fun value -> Ask_followup_reactions value)
      | "tool_actions" -> decode_followup_tools value |> Result.map (fun value -> Ask_followup_tools value)
      | "linked_task" -> decode_followup_task value |> Result.map (fun value -> Ask_followup_task value)
      | _ -> Error "unknown answer follow-up source" in
    Ok (Ask_followup_source (identity,source))
  | _ -> Error "unknown answer follow-up stream phase"

type ask_followup_stream =
  | Awaiting_followup
  | Receiving_followup of
      { identity : ask_followup_identity; reactions_seen : bool; tools_seen : bool; task_seen : bool }
  | Completed_followup

let empty_ask_followup_stream = Awaiting_followup
let same_followup_identity left right =
  left.afi_answered_at=right.afi_answered_at && String.equal left.afi_stimulus_id right.afi_stimulus_id

let accept_ask_followup_event stream event =
  match stream,event with
  | Awaiting_followup,Ask_followup_started identity ->
    Ok (Receiving_followup {identity;reactions_seen=false;tools_seen=false;task_seen=false})
  | Awaiting_followup,(Ask_followup_source _ | Ask_followup_completed _) -> Error "follow-up source arrived before start"
  | Receiving_followup _,Ask_followup_started _ -> Error "follow-up start repeated"
  | Receiving_followup reading,Ask_followup_source (identity,source) ->
    if not (same_followup_identity reading.identity identity) then Error "follow-up source changed original answer"
    else (match source with
      | Ask_followup_reactions _ ->
        if reading.reactions_seen then Error "follow-up reaction source repeated"
        else Ok (Receiving_followup {reading with reactions_seen=true})
      | Ask_followup_tools _ ->
        if reading.tools_seen then Error "follow-up Tool source repeated"
        else Ok (Receiving_followup {reading with tools_seen=true})
      | Ask_followup_task _ ->
        if reading.task_seen then Error "follow-up Task source repeated"
        else Ok (Receiving_followup {reading with task_seen=true}))
  | Receiving_followup reading,Ask_followup_completed identity ->
    if not (same_followup_identity reading.identity identity) then Error "follow-up completion changed original answer"
    else if reading.reactions_seen && reading.tools_seen && reading.task_seen then Ok Completed_followup
    else Error "follow-up completed before every source settled"
  | Completed_followup,(Ask_followup_started _ | Ask_followup_source _ | Ask_followup_completed _) ->
    Error "follow-up event arrived after completion"

let finish_ask_followup_stream = function
  | Completed_followup -> Ok ()
  | Awaiting_followup | Receiving_followup _ -> Error "follow-up stream ended before complete evidence delivery"

type ask_answer_delivery =
  | Ask_wake_stored
  | Ask_wake_pending of string

type ask_answer_receipt =
  | Ask_answer_recorded of ask_answer_delivery
  | Ask_answer_already_recorded of {
      aar_delivery : ask_answer_delivery;
      aar_answered_at : float;
    }
  | Ask_answer_written_unconfirmed of string
  | Ask_answer_refused of string

type answer_receipt =
  | Keeper_answer_receipt of ask_answer_receipt
  | Installation_answer_receipt of installation_answer_receipt

let decode_ask_answer_receipt ~expected_ask_id ~status_code json =
  let error_detail () =
    match member "error" json with
    | `String detail when String.trim detail <> "" -> Ok detail
    | _ -> Error "ask answer: error detail is required"
  in
  match member "recorded" json with
  | `Bool true ->
      let* ask_id = ask_string json "ask_id" in
      if not (String.equal ask_id expected_ask_id) then
        Error "ask answer: receipt belongs to another question"
      else
        let* delivery =
          match member "delivered" json with
          | `Bool true -> Ok Ask_wake_stored
          | `Bool false ->
              let* detail = error_detail () in
              Ok (Ask_wake_pending detail)
          | _ -> Error "ask answer: delivered must be a boolean"
        in
        (match status_code, member "state" json, delivery with
         | 200, `Null, Ask_wake_stored
         | 500, `Null, Ask_wake_pending _ -> Ok (Ask_answer_recorded delivery)
         | 500, `String "recording_unconfirmed", Ask_wake_pending detail ->
             Ok (Ask_answer_written_unconfirmed detail)
         | 409, `String "answered", (Ask_wake_stored | Ask_wake_pending _) ->
             let* answered_at = ask_float json "answered_at" in
             if not (Float.is_finite answered_at) then
               Error "ask answer: canonical answer time is not finite"
             else Ok (Ask_answer_already_recorded
               { aar_delivery = delivery; aar_answered_at = answered_at })
         | _, _, (Ask_wake_stored | Ask_wake_pending _) ->
             Error "ask answer: HTTP status contradicts recording or delivery evidence")
  | `Bool false | `Null ->
      if status_code >= 400 && status_code < 500 then
        (match member "state" json with
         | `String "answered" | `String "recording_unconfirmed" ->
             Error "ask answer: canonical recording receipt is missing"
         | _ ->
             let* detail = error_detail () in
             Ok (Ask_answer_refused detail))
      else Error "ask answer: recording is unconfirmed"
  | _ -> Error "ask answer: recorded must be a boolean"
