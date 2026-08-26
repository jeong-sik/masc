(* See .mli. *)

let ( let* ) = Result.bind

let is_blank s = String.trim s = ""

(* {1 Choices} *)

type invalid_choice =
  | Choice_id_blank
  | Choice_label_blank

type choice = {
  choice_id : string;
  label : string;
  description : string option;
}

let choice ~choice_id ~label ?description () =
  if is_blank choice_id then Error Choice_id_blank
  else if is_blank label then Error Choice_label_blank
  else Ok { choice_id; label; description }

(* {1 Questions} *)

type answer_mode =
  | Single
  | Multi

type free_text =
  | Free_text_allowed of { hint : string option }
  | Choices_only

type invalid_question =
  | Question_id_blank
  | Header_blank
  | Prompt_blank
  | No_way_to_answer
  | Duplicate_choice_ids of string list

type question = {
  question_id : string;
  header : string;
  prompt : string;
  choices : choice list;
  mode : answer_mode;
  free_text : free_text;
}

(* Ids that appear more than once, each reported once, in first-seen order. *)
let duplicates_of ids =
  let rec go seen dups = function
    | [] -> List.rev dups
    | id :: rest ->
        if List.mem id seen && not (List.mem id dups) then go seen (id :: dups) rest
        else go (id :: seen) dups rest
  in
  go [] [] ids

let question ~question_id ~header ~prompt ~choices ~mode ~free_text =
  if is_blank question_id then Error Question_id_blank
  else if is_blank header then Error Header_blank
  else if is_blank prompt then Error Prompt_blank
  else
    let answerable =
      match (choices, free_text) with
      | [], Choices_only -> false
      | [], Free_text_allowed _ -> true
      | _ :: _, (Choices_only | Free_text_allowed _) -> true
    in
    if not answerable then Error No_way_to_answer
    else
      match duplicates_of (List.map (fun c -> c.choice_id) choices) with
      | [] -> Ok { question_id; header; prompt; choices; mode; free_text }
      | dups -> Error (Duplicate_choice_ids dups)

(* {1 Asks} *)

type invalid_ask =
  | Ask_id_blank
  | Keeper_name_blank
  | No_questions
  | Duplicate_question_ids of string list

type ask = {
  ask_id : string;
  keeper_name : string;
  questions : question list;
  context : string option;
  turn_id : int option;
  task_id : string option;
  goal_id : string option;
  continuation : Keeper_continuation_channel.t;
  asked_at : float;
}

let ask ~ask_id ~keeper_name ~questions ?context ?turn_id ?task_id ?goal_id
    ~continuation ~asked_at () =
  if is_blank ask_id then Error Ask_id_blank
  else if is_blank keeper_name then Error Keeper_name_blank
  else if questions = [] then Error No_questions
  else
    match duplicates_of (List.map (fun q -> q.question_id) questions) with
    | [] ->
        Ok
          {
            ask_id;
            keeper_name;
            questions;
            context;
            turn_id;
            task_id;
            goal_id;
            continuation;
            asked_at;
          }
    | dups -> Error (Duplicate_question_ids dups)

(* {1 Answers} *)

type response =
  | Chose of { choice_ids : string list }
  | Wrote of string
  | Skipped

type answer = {
  question_id : string;
  response : response;
}

type invalid_answer =
  | Unknown_question of { question_id : string }
  | Unknown_choice of { question_id : string; choice_id : string }
  | Duplicate_choice of { question_id : string; choice_id : string }
  | Multiple_choices_for_single of { question_id : string; count : int }
  | Empty_selection of { question_id : string }
  | Free_text_not_offered of { question_id : string }
  | Free_text_blank of { question_id : string }
  | Answered_twice of { question_id : string }
  | Unanswered of { question_id : string }

let validate_chose (q : question) choice_ids =
  let question_id = q.question_id in
  let empty =
    match choice_ids with [] -> [ Empty_selection { question_id } ] | _ :: _ -> []
  in
  let cardinality =
    match q.mode with
    | Single ->
        let count = List.length choice_ids in
        if count > 1 then [ Multiple_choices_for_single { question_id; count } ] else []
    | Multi -> []
  in
  let dups =
    List.map
      (fun choice_id -> Duplicate_choice { question_id; choice_id })
      (duplicates_of choice_ids)
  in
  let unknown =
    List.filter_map
      (fun choice_id ->
        if List.exists (fun c -> String.equal c.choice_id choice_id) q.choices then None
        else Some (Unknown_choice { question_id; choice_id }))
      choice_ids
  in
  empty @ cardinality @ dups @ unknown

let validate_response (q : question) response =
  match response with
  | Skipped -> []
  | Wrote text -> (
      match q.free_text with
      | Choices_only -> [ Free_text_not_offered { question_id = q.question_id } ]
      | Free_text_allowed _ ->
          if is_blank text then [ Free_text_blank { question_id = q.question_id } ] else [])
  | Chose { choice_ids } -> validate_chose q choice_ids

let parse_answers ~ask ~submissions =
  let question_by_id question_id =
    List.find_opt (fun (q : question) -> String.equal q.question_id question_id) ask.questions
  in
  let submitted_twice =
    List.map
      (fun question_id -> Answered_twice { question_id })
      (duplicates_of (List.map fst submissions))
  in
  let per_submission =
    List.concat_map
      (fun (question_id, response) ->
        match question_by_id question_id with
        | None -> [ Unknown_question { question_id } ]
        | Some q -> validate_response q response)
      submissions
  in
  let unanswered =
    List.filter_map
      (fun (q : question) ->
        if List.exists (fun (qid, _) -> String.equal qid q.question_id) submissions then None
        else Some (Unanswered { question_id = q.question_id }))
      ask.questions
  in
  match submitted_twice @ per_submission @ unanswered with
  | _ :: _ as errors -> Error errors
  | [] ->
      (* Every question has exactly one submission naming a known id, so the
         lookup below cannot miss. *)
      Ok
        (List.filter_map
           (fun (q : question) ->
             match List.assoc_opt q.question_id submissions with
             | Some response -> Some { question_id = q.question_id; response }
             | None -> None)
           ask.questions)

(* {1 Responders} *)

type responder = {
  surface : Surface_ref.t;
  actor_id : string option;
  display_name : string option;
}

(* {1 Events} *)

type event =
  | Asked of ask
  | Answered of {
      ask_id : string;
      answers : answer list;
      responder : responder;
      answered_at : float;
    }
  | Withdrawn of { ask_id : string; reason : string; withdrawn_at : float }

type resolution =
  | Open
  | Answered_by of {
      answers : answer list;
      responder : responder;
      answered_at : float;
    }
  | Withdrawn_because of { reason : string; withdrawn_at : float }

(* Applies [f] to the row for [ask_id] when that row is still [Open]. A row
   already resolved keeps its first terminal event, so two surfaces racing to
   answer resolve to whichever write landed first. Rows are few per keeper, so
   the scan per event is left linear rather than indexed. *)
let resolve rows ask_id f =
  List.map
    (fun (id, (a, r)) ->
      if String.equal id ask_id then
        match r with
        | Open -> (id, (a, f))
        | Answered_by _ | Withdrawn_because _ -> (id, (a, r))
      else (id, (a, r)))
    rows

let fold_events events =
  let rows =
    List.fold_left
      (fun rows event ->
        match event with
        | Asked a ->
            if List.exists (fun (id, _) -> String.equal id a.ask_id) rows then rows
            else (a.ask_id, (a, Open)) :: rows
        | Answered { ask_id; answers; responder; answered_at } ->
            resolve rows ask_id (Answered_by { answers; responder; answered_at })
        | Withdrawn { ask_id; reason; withdrawn_at } ->
            resolve rows ask_id (Withdrawn_because { reason; withdrawn_at }))
      [] events
  in
  List.rev rows

let open_asks events =
  List.filter_map
    (fun (_, (a, r)) ->
      match r with
      | Open -> Some a
      | Answered_by _ | Withdrawn_because _ -> None)
    (fold_events events)

(* {1 Labels} *)

let answer_mode_to_string = function Single -> "single" | Multi -> "multi"

let answer_mode_of_string = function
  | "single" -> Some Single
  | "multi" -> Some Multi
  | _ -> None

let invalid_choice_to_string = function
  | Choice_id_blank -> "choice_id is blank"
  | Choice_label_blank -> "choice label is blank"

let invalid_question_to_string = function
  | Question_id_blank -> "question_id is blank"
  | Header_blank -> "header is blank"
  | Prompt_blank -> "prompt is blank"
  | No_way_to_answer -> "question offers no choices and refuses free text"
  | Duplicate_choice_ids ids -> "duplicate choice_id: " ^ String.concat ", " ids

let invalid_ask_to_string = function
  | Ask_id_blank -> "ask_id is blank"
  | Keeper_name_blank -> "keeper_name is blank"
  | No_questions -> "ask carries no questions"
  | Duplicate_question_ids ids -> "duplicate question_id: " ^ String.concat ", " ids

let invalid_answer_to_string = function
  | Unknown_question { question_id } -> "unknown question_id: " ^ question_id
  | Unknown_choice { question_id; choice_id } ->
      Printf.sprintf "question %s does not offer choice %s" question_id choice_id
  | Duplicate_choice { question_id; choice_id } ->
      Printf.sprintf "question %s selected choice %s more than once" question_id choice_id
  | Multiple_choices_for_single { question_id; count } ->
      Printf.sprintf "question %s takes one choice, got %d" question_id count
  | Empty_selection { question_id } -> "question " ^ question_id ^ " selected nothing"
  | Free_text_not_offered { question_id } ->
      "question " ^ question_id ^ " does not accept free text"
  | Free_text_blank { question_id } -> "question " ^ question_id ^ " got blank free text"
  | Answered_twice { question_id } -> "question " ^ question_id ^ " answered more than once"
  | Unanswered { question_id } -> "question " ^ question_id ^ " has no submission"

(* {1 JSON}

   Codecs live in this module rather than beside it because [choice],
   [question], [ask], and [answer] are private: a separate module could not
   rebuild them without a constructor that skips validation. Decoding routes
   every rebuilt value back through the smart constructors, so a hand-edited or
   truncated log line fails to parse instead of loading a question nobody can
   answer. *)

let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

let string_field key json =
  match member key json with
  | Some (`String s) -> Ok s
  | Some _ -> Error (key ^ ": expected string")
  | None -> Error (key ^ ": missing")

let string_option_field key json =
  match member key json with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ -> Error (key ^ ": expected string or null")

let int_option_field key json =
  match member key json with
  | None | Some `Null -> Ok None
  | Some (`Int i) -> Ok (Some i)
  | Some _ -> Error (key ^ ": expected int or null")

let float_field key json =
  match member key json with
  | Some (`Float f) -> Ok f
  | Some (`Int i) -> Ok (float_of_int i)
  | Some _ -> Error (key ^ ": expected number")
  | None -> Error (key ^ ": missing")

let list_field key json =
  match member key json with
  | Some (`List items) -> Ok items
  | Some _ -> Error (key ^ ": expected array")
  | None -> Error (key ^ ": missing")

let raw_field key json =
  match member key json with Some j -> Ok j | None -> Error (key ^ ": missing")

let string_list_of_json key items =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | `String s :: rest -> go (s :: acc) rest
    | _ -> Error (key ^ ": expected array of strings")
  in
  go [] items

let rec map_results f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = map_results f rest in
      Ok (y :: ys)

let string_option_to_json = function None -> `Null | Some s -> `String s
let int_option_to_json = function None -> `Null | Some i -> `Int i

let choice_to_json c =
  `Assoc
    [
      ("choice_id", `String c.choice_id);
      ("label", `String c.label);
      ("description", string_option_to_json c.description);
    ]

let choice_of_json json =
  let* choice_id = string_field "choice_id" json in
  let* label = string_field "label" json in
  let* description = string_option_field "description" json in
  Result.map_error invalid_choice_to_string (choice ~choice_id ~label ?description ())

let free_text_to_json = function
  | Choices_only -> `Assoc [ ("kind", `String "choices_only") ]
  | Free_text_allowed { hint } ->
      `Assoc [ ("kind", `String "allowed"); ("hint", string_option_to_json hint) ]

let free_text_of_json json =
  let* kind = string_field "kind" json in
  match kind with
  | "choices_only" -> Ok Choices_only
  | "allowed" ->
      let* hint = string_option_field "hint" json in
      Ok (Free_text_allowed { hint })
  | other -> Error ("free_text.kind: unknown value " ^ other)

let question_to_json (q : question) =
  `Assoc
    [
      ("question_id", `String q.question_id);
      ("header", `String q.header);
      ("prompt", `String q.prompt);
      ("choices", `List (List.map choice_to_json q.choices));
      ("mode", `String (answer_mode_to_string q.mode));
      ("free_text", free_text_to_json q.free_text);
    ]

let question_of_json json =
  let* question_id = string_field "question_id" json in
  let* header = string_field "header" json in
  let* prompt = string_field "prompt" json in
  let* choice_items = list_field "choices" json in
  let* choices = map_results choice_of_json choice_items in
  let* mode_label = string_field "mode" json in
  let* mode =
    match answer_mode_of_string mode_label with
    | Some m -> Ok m
    | None -> Error ("mode: unknown value " ^ mode_label)
  in
  let* free_text_json = raw_field "free_text" json in
  let* free_text = free_text_of_json free_text_json in
  Result.map_error invalid_question_to_string
    (question ~question_id ~header ~prompt ~choices ~mode ~free_text)

let ask_to_json a =
  `Assoc
    [
      ("ask_id", `String a.ask_id);
      ("keeper_name", `String a.keeper_name);
      ("questions", `List (List.map question_to_json a.questions));
      ("context", string_option_to_json a.context);
      ("turn_id", int_option_to_json a.turn_id);
      ("task_id", string_option_to_json a.task_id);
      ("goal_id", string_option_to_json a.goal_id);
      ("continuation", Keeper_continuation_channel.to_yojson a.continuation);
      ("asked_at", `Float a.asked_at);
    ]

let ask_of_json json =
  let* ask_id = string_field "ask_id" json in
  let* keeper_name = string_field "keeper_name" json in
  let* question_items = list_field "questions" json in
  let* questions = map_results question_of_json question_items in
  let* context = string_option_field "context" json in
  let* turn_id = int_option_field "turn_id" json in
  let* task_id = string_option_field "task_id" json in
  let* goal_id = string_option_field "goal_id" json in
  let* continuation_json = raw_field "continuation" json in
  let* continuation = Keeper_continuation_channel.of_yojson continuation_json in
  let* asked_at = float_field "asked_at" json in
  Result.map_error invalid_ask_to_string
    (ask ~ask_id ~keeper_name ~questions ?context ?turn_id ?task_id ?goal_id ~continuation
       ~asked_at ())

let response_to_json = function
  | Chose { choice_ids } ->
      `Assoc
        [
          ("kind", `String "chose");
          ("choice_ids", `List (List.map (fun id -> `String id) choice_ids));
        ]
  | Wrote text -> `Assoc [ ("kind", `String "wrote"); ("text", `String text) ]
  | Skipped -> `Assoc [ ("kind", `String "skipped") ]

let response_of_json json =
  let* kind = string_field "kind" json in
  match kind with
  | "chose" ->
      let* items = list_field "choice_ids" json in
      let* choice_ids = string_list_of_json "choice_ids" items in
      Ok (Chose { choice_ids })
  | "wrote" ->
      let* text = string_field "text" json in
      Ok (Wrote text)
  | "skipped" -> Ok Skipped
  | other -> Error ("response.kind: unknown value " ^ other)

let answer_to_json a =
  `Assoc
    [ ("question_id", `String a.question_id); ("response", response_to_json a.response) ]

let answer_of_json json =
  let* question_id = string_field "question_id" json in
  let* response_json = raw_field "response" json in
  let* response = response_of_json response_json in
  Ok { question_id; response }

let responder_to_json r =
  `Assoc
    [
      ("surface", Surface_ref.to_json r.surface);
      ("actor_id", string_option_to_json r.actor_id);
      ("display_name", string_option_to_json r.display_name);
    ]

let responder_of_json json =
  let* surface_json = raw_field "surface" json in
  let* surface = Surface_ref.of_json surface_json in
  let* actor_id = string_option_field "actor_id" json in
  let* display_name = string_option_field "display_name" json in
  Ok { surface; actor_id; display_name }

let event_to_json = function
  | Asked a -> `Assoc [ ("event", `String "asked"); ("ask", ask_to_json a) ]
  | Answered { ask_id; answers; responder; answered_at } ->
      `Assoc
        [
          ("event", `String "answered");
          ("ask_id", `String ask_id);
          ("answers", `List (List.map answer_to_json answers));
          ("responder", responder_to_json responder);
          ("answered_at", `Float answered_at);
        ]
  | Withdrawn { ask_id; reason; withdrawn_at } ->
      `Assoc
        [
          ("event", `String "withdrawn");
          ("ask_id", `String ask_id);
          ("reason", `String reason);
          ("withdrawn_at", `Float withdrawn_at);
        ]

let event_of_json json =
  let* kind = string_field "event" json in
  match kind with
  | "asked" ->
      let* ask_json = raw_field "ask" json in
      let* a = ask_of_json ask_json in
      Ok (Asked a)
  | "answered" ->
      let* ask_id = string_field "ask_id" json in
      let* answer_items = list_field "answers" json in
      let* answers = map_results answer_of_json answer_items in
      let* responder_json = raw_field "responder" json in
      let* responder = responder_of_json responder_json in
      let* answered_at = float_field "answered_at" json in
      Ok (Answered { ask_id; answers; responder; answered_at })
  | "withdrawn" ->
      let* ask_id = string_field "ask_id" json in
      let* reason = string_field "reason" json in
      let* withdrawn_at = float_field "withdrawn_at" json in
      Ok (Withdrawn { ask_id; reason; withdrawn_at })
  | other -> Error ("event: unknown value " ^ other)
