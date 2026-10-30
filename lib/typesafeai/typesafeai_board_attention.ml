module Judgment = Keeper_board_attention_judgment

type assessment =
  | Decided of Judgment.t
  | Needs_review of string

type decision = Settled of Judgment.decision | Uncertain

let decision_label = function
  | Settled decision -> Judgment.decision_to_string decision
  | Uncertain -> "uncertain"
;;

type judged =
  { assessment : assessment
  ; provenance : Keeper_board_attention_candidate.system_one_provenance
  ; confidence : float
  }

open Result.Syntax

(* The explicit uncertainty choice delegates to the full lane. A decided
   answer's confidence goes back to the caller, which sends a decision below
   its settle floor to the full lane as well. *)
let relevance_choices () =
  let* relevant = Prompt_registry.render_prompt_template Prompt_names.judge_board_policy_relevant [] in
  let* not_relevant = Prompt_registry.render_prompt_template Prompt_names.judge_board_policy_not_relevant [] in
  let* uncertain = Prompt_registry.render_prompt_template Prompt_names.judge_board_system_one_uncertain [] in
  let* board_policy = Prompt_registry.render_prompt_template Prompt_names.judge_board_policy
      ["relevant_rule", relevant; "not_relevant_rule", not_relevant] in
  let* choices = Typesafeai_types.choice_set
    ~options:(List.map (fun decision -> Settled decision) Judgment.all_of_decision @ [Uncertain])
    ~label:decision_label
    ~describe:(function
      | Settled Judgment.Relevant -> Some relevant
      | Settled Judgment.Not_relevant -> Some not_relevant
      | Uncertain -> Some uncertain)
  in
  Ok (choices, board_policy)
;;

let relevance_question_id = "relevance"

(* The keeper and its interests are in the question, and the state carries
   only the signal. With the keeper's role in the state, Jev answered relevant
   far more often: on 2026-10-01, over 26 cases where the two shapes
   disagreed, a blind judge reading the production rule sided with this
   shape 23 times. The same shape lets one request carry a question per
   keeper for the same signal. *)
let relevance_question ~board_policy ~choices ~interests candidate =
  let* instructions =
    Prompt_registry.render_prompt_template Prompt_names.judge_board_system_one
      [ "board_policy", board_policy
      ; "keeper_name_json", Yojson.Safe.to_string (`String candidate.Keeper_board_attention_candidate.keeper_name)
      ; "board_interests_json", Yojson.Safe.to_string (`List (List.map (fun interest -> `String interest) interests))
      ]
  in
  Ok (Typesafeai_types.choice_of_set ~instructions choices)
;;

let rationale
      ({ Typesafeai_types.choice; reported_probabilities; reported_probability_sum; confidence } :
        decision Typesafeai_types.decoded_choice)
  =
  let label = decision_label in
  let probabilities =
    List.map
      (fun (decision, probability) -> Printf.sprintf "%s:%.17g" (label decision) probability)
      reported_probabilities
    |> String.concat ", "
  in
  Printf.sprintf
    "TypeSafe AI Jev: %s (confidence=%.2f, reported_sum=%.17g, reported_values=%s)"
    (label choice)
    confidence
    reported_probability_sum
    probabilities
;;

let judge_candidate ?clock ~destinations ~candidate () =
  let* choices, board_policy = relevance_choices () in
  let* interests = Keeper_board_attention_candidate.board_interests candidate in
  let* question = relevance_question ~board_policy ~choices ~interests candidate in
  let state =
    `Assoc
      [ ( "signal"
        , Keeper_board_attention_candidate.signal_to_yojson
            candidate.Keeper_board_attention_candidate.signal )
      ]
  in
  let* evaluated =
    Typesafeai_client.evaluate
      ?clock
      ~destinations
      ~state
      ~questions:[ relevance_question_id, question ]
      ()
    |> Result.map_error Typesafeai_client.failure_to_string
  in
  (* The candidate's provenance names the destination that answered; the ones
     asked before it are said here, where the keeper's log is read. *)
  (match evaluated.Typesafeai_client.passed_over with
   | [] -> ()
   | passed_over ->
     Log.Keeper.warn
       ~keeper_name:candidate.Keeper_board_attention_candidate.keeper_name
       "board attention Jev: %s answered after %d destination(s) refused: %s"
       evaluated.destination.destination_uri
       (List.length passed_over)
       (Yojson.Safe.to_string
          (`List (List.map Typesafeai_client.attempt_to_yojson passed_over))));
  let response = evaluated.Typesafeai_client.response in
  let* answer =
    match List.assoc_opt relevance_question_id response.answers with
    | Some answer -> Ok answer
    | None -> Error "typesafeai: response missing answer for relevance question"
  in
  let* (decided : decision Typesafeai_types.decoded_choice) =
    Typesafeai_types.decode_choice choices answer
  in
  Ok
    { assessment =
        (match decided.Typesafeai_types.choice with
         | Settled decision -> Decided { Judgment.decision; rationale = rationale decided }
         | Uncertain -> Needs_review (rationale decided))
    ; provenance =
        { Keeper_board_attention_candidate.destination_uri =
            evaluated.destination.destination_uri
        ; answering_model_id = response.model
        ; request_body_sha256 = evaluated.request_body_sha256
        }
    ; confidence = decided.Typesafeai_types.confidence
    }
;;

let judge_candidates ?clock ~destinations ~(candidates : Keeper_board_attention_candidate.candidate list) () =
  match candidates with
  | [] -> Ok []
  | first :: _ ->
    let* choices, board_policy = relevance_choices () in
    let signal = Keeper_board_attention_candidate.signal_to_yojson first.signal in
    let rec questions seen = function
      | [] -> Ok []
      | candidate :: rest ->
        let id = candidate.Keeper_board_attention_candidate.candidate_id in
        if List.mem id seen then Error "typesafeai: duplicate candidate identity"
        else if Keeper_board_attention_candidate.signal_to_yojson candidate.signal <> signal
        then Error "typesafeai: event batch contains different signals"
        else
          let* interests = Keeper_board_attention_candidate.board_interests candidate in
          let* question = relevance_question ~board_policy ~choices ~interests candidate in
          let* tail = questions (id :: seen) rest in
          Ok ((id, question) :: tail)
    in
    let* questions = questions [] candidates in
    let* evaluated =
      Typesafeai_client.evaluate ?clock ~destinations
        ~state:(`Assoc ["signal", signal]) ~questions ()
      |> Result.map_error Typesafeai_client.failure_to_string
    in
    let response = evaluated.Typesafeai_client.response in
    let provenance =
      { Keeper_board_attention_candidate.destination_uri = evaluated.destination.destination_uri
      ; answering_model_id = response.model
      ; request_body_sha256 = evaluated.request_body_sha256
      }
    in
    let decode candidate =
      let* answer =
        match List.assoc_opt candidate.Keeper_board_attention_candidate.candidate_id response.answers with
        | Some answer -> Ok answer
        | None -> Error "typesafeai: response missing candidate answer"
      in
      let* decided = Typesafeai_types.decode_choice choices answer in
      Ok
        { assessment =
            (match decided.Typesafeai_types.choice with
             | Settled decision -> Decided { Judgment.decision; rationale = rationale decided }
             | Uncertain -> Needs_review (rationale decided))
        ; provenance
        ; confidence = decided.confidence
        }
    in
    Ok (List.map (fun candidate -> candidate, decode candidate) candidates)
;;
