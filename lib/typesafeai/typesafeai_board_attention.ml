module Judgment = Keeper_board_attention_judgment

type judged =
  { verdict : Judgment.t
  ; provenance : Keeper_board_attention_candidate.system_one_provenance
  }

let ( let* ) = Result.bind

(* Jev picks between the Board-attention decisions themselves, offered and
   read back under the labels the LLM lane uses for them. The options and the
   labels come from the variant, so a new decision reaches Jev without an edit
   here, and [describe] does not compile until it says what that decision
   means. *)
let relevance_choices =
  Typesafeai_types.choice_set
    ~options:Judgment.all_of_decision
    ~label:Judgment.decision_to_string
    ~describe:(function
      | Judgment.Relevant ->
        Some
          "The current signal itself directly addresses this keeper, requests or assigns the role described by its instructions, or contains a concrete request specific to that role; general topic or capability overlap alone is insufficient."
      | Judgment.Not_relevant ->
        Some
          "The current signal is aimed elsewhere, is general discussion or noise, only overlaps with the keeper's broad capabilities, or does not require this keeper to act.")
;;

let relevance_question_id = "relevance"

let relevance_question ~choices candidate =
  Typesafeai_types.choice_of_set
    ~instructions:
      (Printf.sprintf
         "Does the current Board signal in items[0] itself require attention, review, or action from keeper %S based only on keeper_role? General capability overlap is not sufficient."
         candidate.Keeper_board_attention_candidate.keeper_name)
    choices
;;

let rationale
      ({ Typesafeai_types.choice; probabilities; confidence } :
        Judgment.decision Typesafeai_types.decoded_choice)
  =
  let label = Judgment.decision_to_string in
  let probabilities =
    List.map
      (fun (decision, probability) -> Printf.sprintf "%s:%.2f" (label decision) probability)
      probabilities
    |> String.concat ", "
  in
  Printf.sprintf
    "TypeSafe AI Jev: %s (confidence=%.2f, %s)"
    (label choice)
    confidence
    probabilities
;;

let judge_candidate ?clock ~api_key ~candidate () =
  let* choices = relevance_choices in
  let* state =
    Keeper_board_attention_candidate.singleton_judgment_request
      candidate
  in
  let* evaluated =
    Typesafeai_client.evaluate
      ?clock
      ~api_key
      ~state
      ~questions:[ relevance_question_id, relevance_question ~choices candidate ]
      ()
    |> Result.map_error Typesafeai_client.failure_to_string
  in
  let response = evaluated.Typesafeai_client.response in
  let* answer =
    match List.assoc_opt relevance_question_id response.answers with
    | Some answer -> Ok answer
    | None -> Error "typesafeai: response missing answer for relevance question"
  in
  let* (decided : Judgment.decision Typesafeai_types.decoded_choice) =
    Typesafeai_types.decode_choice choices answer
  in
  Ok
    { verdict =
        { Judgment.decision = decided.Typesafeai_types.choice
        ; rationale = rationale decided
        }
    ; provenance =
        { Keeper_board_attention_candidate.destination_uri =
            evaluated.destination_uri
        ; answering_model_id = response.model
        ; request_body_sha256 = evaluated.request_body_sha256
        }
    }
;;
