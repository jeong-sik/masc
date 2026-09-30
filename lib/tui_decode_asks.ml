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

type ask_row = {
  ar_keeper : string;
  ar_id : string;
  ar_asked_at : float;
  ar_context : string option;
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

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
  let* ar_keeper = ask_string json "keeper" in
  let* ar_id = ask_string json "ask_id" in
  let* ar_asked_at = ask_float json "asked_at" in
  let* question_items = ask_list json "questions" in
  let* ar_questions = ask_map_results decode_ask_question question_items in
  let* ar_resolution = decode_ask_resolution (member "resolution" json) in
  Ok
    {
      ar_keeper;
      ar_id;
      ar_asked_at;
      ar_context = ask_string_opt json "context";
      ar_questions;
      ar_resolution;
    }

let decode_asks_snapshot json =
  let asn_keeper = ask_string_opt json "keeper" in
  let* asn_open_count = ask_int json "open_count" in
  let* row_items = ask_list json "asks" in
  let* asn_rows = ask_map_results decode_ask_row row_items in
  Ok { asn_keeper; asn_open_count; asn_rows }
