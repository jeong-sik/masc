module Judgment = Keeper_board_attention_judgment

type judged =
  { verdict : Judgment.t
  ; model : string
  }

let ( let* ) = Result.bind

(* Jev picks between the Board-attention decisions themselves. The request's
   criteria and the decoding of its answer both come from this one set, so a
   decision cannot be offered under one name and read back under another. *)
let relevance_choices : Judgment.decision Typesafeai_types.choice_set =
  { Typesafeai_types.options = [ Judgment.Relevant; Judgment.Not_relevant ]
  ; label =
      (function
        | Judgment.Relevant -> "relevant"
        | Judgment.Not_relevant -> "not_relevant")
  ; describe =
      (function
        | Judgment.Relevant ->
          Some
            "The post directly mentions, requests, assigns tasks to, or concerns this keeper's instructions."
        | Judgment.Not_relevant ->
          Some
            "The post is aimed at a different keeper, is general noise, or does not require this keeper to act.")
  }
;;

let relevance_question_id = "relevance"

let relevance_question candidate =
  Typesafeai_types.choice_of_set
    ~instructions:
      (Printf.sprintf
         "Does the Board post in items[0] require attention, review, or action from keeper %S based on keeper_context?"
         candidate.Keeper_board_attention_candidate.keeper_name)
    relevance_choices
;;

let rationale
      ({ Typesafeai_types.choice; probabilities; confidence } :
        Judgment.decision Typesafeai_types.decoded_choice)
  =
  let label = relevance_choices.Typesafeai_types.label in
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
  let state =
    Keeper_board_attention_candidate.singleton_judgment_request
      candidate
      material
  in
  let* response =
    Typesafeai_client.evaluate
      ?clock
      ~api_key
      ~state
      ~questions:[ relevance_question_id, relevance_question candidate ]
      ()
  in
  let* answer =
    match List.assoc_opt relevance_question_id response.answers with
    | Some answer -> Ok answer
    | None -> Error "typesafeai: response missing answer for relevance question"
  in
  let* (decided : Judgment.decision Typesafeai_types.decoded_choice) =
    Typesafeai_types.decode_choice relevance_choices answer
  in
  Ok
    { verdict =
        { Judgment.decision = decided.Typesafeai_types.choice
        ; rationale = rationale decided
        }
    ; model = response.model
    }
;;
