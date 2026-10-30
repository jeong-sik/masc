module Types = Typesafeai_types
module Judgment = Keeper_memory_recall_judgment
module Candidates = Keeper_memory_recall_candidates
module Ids = Set.Make (String)
module By_id = Map.Make (String)

type request_kind =
  | Candidate_question
  | Turn_question
  | Time_question

let request_kind_token = function
  | Candidate_question -> "candidates"
  | Turn_question -> "turn"
  | Time_question -> "time"

type request =
  { kind : request_kind
  ; state : Yojson.Safe.t
  ; questions : (string * Types.question) list
  }

type build_error =
  | Duplicate_candidate_id of string
  | Choice_set_invalid of string
  | Guidance_unavailable of string

type 'a answer =
  | Answered of 'a Types.decoded_choice
  | Not_decoded of string

(* Decoding depends only on the closed protocol labels. Criterion descriptions
   are external policy captured separately by [load_guidance]. *)
let candidate_choices =
  Types.choice_set ~options:Judgment.all_of_candidate_decision
    ~label:Judgment.candidate_decision_label ~describe:(fun _ -> None)
let time_choices =
  Types.choice_set ~options:Judgment.all_of_time_nature
    ~label:Judgment.time_nature_label ~describe:(fun _ -> None)
let turn_choices =
  Types.choice_set ~options:Judgment.all_of_turn_need
    ~label:Judgment.turn_need_label ~describe:(fun _ -> None)
let turn_question_id = "turn"

type guidance = {
  candidates : Types.question By_id.t;
  times : Types.question By_id.t;
  turn : Types.question;
}

let load_guidance ~question_ids =
  let ( let* ) = Result.bind in
  let prompt key = Prompt_registry.resolve_and_render_prompt_template key []
    |> Result.map snd |> Result.map_error (fun detail -> Guidance_unavailable detail) in
  let choices options label describe =
    Types.choice_set ~options ~label ~describe
    |> Result.map_error (fun detail -> Choice_set_invalid detail) in
  let* () = match question_ids with
    | [] -> Error (Guidance_unavailable "Recall guidance requires original candidate IDs")
    | _ :: _ -> Ok () in
  let* possibly_needed = prompt Prompt_names.keeper_recall_candidate_possibly_needed in
  let* not_needed = prompt Prompt_names.keeper_recall_candidate_not_needed in
  let* standing = prompt Prompt_names.keeper_recall_time_standing in
  let* time_bound = prompt Prompt_names.keeper_recall_time_bound in
  let* yes = prompt Prompt_names.keeper_recall_turn_yes in
  let* no = prompt Prompt_names.keeper_recall_turn_no in
  let* unsure = prompt Prompt_names.keeper_recall_turn_unsure in
  let* candidate_choices = choices Judgment.all_of_candidate_decision Judgment.candidate_decision_label
    (function Judgment.Possibly_needed -> Some possibly_needed | Not_needed -> Some not_needed) in
  let* time_choices = choices Judgment.all_of_time_nature Judgment.time_nature_label
    (function Judgment.Standing -> Some standing | Time_bound -> Some time_bound) in
  let* turn_choices = choices Judgment.all_of_turn_need Judgment.turn_need_label
    (function Judgment.Needs_knowledge -> Some yes | Needs_no_knowledge -> Some no | Unsure -> Some unsure) in
  let* turn_instructions = prompt Prompt_names.keeper_recall_turn in
  let render_questions key choices =
    let resolution = Prompt_registry.resolve_prompt key in
    List.fold_left (fun result id ->
      let* questions = result in
      let* instructions = Prompt_registry.render_resolved_prompt_template key resolution ["question_id",id]
        |> Result.map_error (fun detail -> Guidance_unavailable detail) in
      Ok (By_id.add id (Types.choice_of_set choices ~instructions) questions))
      (Ok By_id.empty) question_ids in
  let* candidates = render_questions Prompt_names.keeper_recall_candidate candidate_choices in
  let* times = render_questions Prompt_names.keeper_recall_time time_choices in
  Ok {candidates;times;turn=Types.choice_of_set turn_choices ~instructions:turn_instructions}

let first_duplicate ids =
  let rec go seen = function
    | [] -> None
    | id :: rest -> if Ids.mem id seen then Some id else go (Ids.add id seen) rest in
  go Ids.empty ids

let piece_request ~kind ~state_head ~questions piece =
  let ( let* ) = Result.bind in
  let candidates = Candidates.piece_candidates piece in
  let ids = List.map Candidates.id candidates in
  match first_duplicate ids with
  | Some id -> Error (Duplicate_candidate_id id)
  | None ->
    let* questions = List.fold_left (fun result id ->
      let* captured = result in
      let* question = By_id.find_opt id questions |> Option.to_result
        ~none:(Guidance_unavailable ("No captured recall question for original candidate " ^ id)) in
      Ok ((id,question)::captured)) (Ok []) ids in
    let questions = List.rev questions in
    Ok { kind
       ; state = `Assoc (state_head @ ["candidates", `List (List.map Candidates.line candidates)])
       ; questions }

let decode_one choices answer =
  match Types.decode_choice choices answer with
  | Ok decoded -> Answered decoded
  | Error detail -> Not_decoded detail

let decode_piece ~choices piece (response : Types.eval_response) =
  let ids = List.map Candidates.id (Candidates.piece_candidates piece) in
  let all_not_decoded detail = List.map (fun id -> id, Not_decoded detail) ids in
  match choices with
  | Error detail -> all_not_decoded detail
  | Ok choices ->
    let known = Ids.of_list ids in
    let answer_ids = List.map fst response.answers in
    if Option.is_some (first_duplicate answer_ids)
       || List.exists (fun id -> not (Ids.mem id known)) answer_ids
    then all_not_decoded "response has a duplicate or unknown answer id"
    else
      let answers = By_id.of_list response.answers in
      List.map (fun id ->
        id, (match By_id.find_opt id answers with
             | None -> Not_decoded "answer is missing"
             | Some answer -> decode_one choices answer)) ids

let candidate_request ~guidance ~purpose piece =
  piece_request ~kind:Candidate_question ~state_head:["purpose", purpose]
    ~questions:guidance.candidates piece

let decode_candidates piece response =
  decode_piece ~choices:candidate_choices piece response

let candidate_result ~id = function
  | Answered decoded -> Judgment.Decided { id; decision = decoded.Types.choice }
  | Not_decoded _ -> Judgment.Undecided { id; reason = Judgment.Invalid_answer }

let turn_request ~guidance ~purpose =
  Ok { kind = Turn_question
     ; state = `Assoc ["purpose", purpose]
     ; questions = [turn_question_id, guidance.turn] }

let decode_turn (response : Types.eval_response) =
  match turn_choices, response.answers with
  | Error detail, (_ :: _ | []) -> Not_decoded detail
  | Ok choices, [id, answer] when String.equal id turn_question_id ->
    decode_one choices answer
  | Ok _, ([] | _ :: _) -> Not_decoded "turn question needs exactly one answer under its own id"

let turn_answer = function
  | Answered decoded -> Judgment.Turn_answered decoded.Types.choice
  | Not_decoded _ -> Judgment.Turn_question_failed

(* The question is about the memory alone, so the turn input stays out of the
   request. *)
let time_request ~guidance piece =
  piece_request ~kind:Time_question ~state_head:[] ~questions:guidance.times piece

let decode_time piece response = decode_piece ~choices:time_choices piece response

let time_mark = function
  | Answered decoded -> Judgment.Marked decoded.Types.choice
  | Not_decoded _ -> Judgment.Time_unjudged
