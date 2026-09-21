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
          "The post directly mentions, requests, assigns tasks to, or concerns this keeper's instructions."
      | Judgment.Not_relevant ->
        Some
          "The post is aimed at a different keeper, is general noise, or does not require this keeper to act.")
;;

let relevance_question_id = "relevance"

let relevance_question ~choices candidate =
  Typesafeai_types.choice_of_set
    ~instructions:
      (Printf.sprintf
         "Does the Board post in items[0] require attention, review, or action from keeper %S based on keeper_context?"
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

let judge_candidate ?clock ~api_key ~candidate ~material () =
  let* choices = relevance_choices in
  let state =
    Keeper_board_attention_candidate.singleton_judgment_request
      candidate
      material
  in
  let* evaluated =
    Typesafeai_client.evaluate
      ?clock
      ~api_key
      ~state
      ~questions:[ relevance_question_id, relevance_question ~choices candidate ]
      ()
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
