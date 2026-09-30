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

let ( let* ) = Result.bind

(* The explicit uncertainty choice delegates to the full lane. A decided
   answer's confidence goes back to the caller, which sends a decision below
   its settle floor to the full lane as well. *)
let relevance_choices =
  Typesafeai_types.choice_set
    ~options:(List.map (fun decision -> Settled decision) Judgment.all_of_decision @ [Uncertain])
    ~label:decision_label
    ~describe:(function
      | Settled Judgment.Relevant ->
        Some
          "The current signal itself requires this keeper's concrete attention, review, or action for one of keeper_role.board_interests; general topic or capability overlap alone is insufficient."
      | Settled Judgment.Not_relevant ->
        Some
          "The current signal is aimed elsewhere, is general discussion or noise, only overlaps with a board interest, or does not require this keeper to act."
      | Uncertain -> Some "The current signal does not provide enough evidence to decide; request a full judgment by the review lane.")
;;

let relevance_question_id = "relevance"

let relevance_question ~choices candidate =
  Typesafeai_types.choice_of_set
    ~instructions:
      (Printf.sprintf
         "Does the current Board signal in items[0] itself require concrete attention, review, or action from keeper %S for one of keeper_role.board_interests? General topic or capability overlap is not sufficient. Choose uncertain when you cannot establish either decision from the supplied signal."
         candidate.Keeper_board_attention_candidate.keeper_name)
    choices
;;

let rationale
      ({ Typesafeai_types.choice; probabilities; confidence } :
        decision Typesafeai_types.decoded_choice)
  =
  let label = decision_label in
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

let judge_candidate ?clock ~destinations ~candidate () =
  let* choices = relevance_choices in
  let* state =
    Keeper_board_attention_candidate.singleton_judgment_request
      candidate
  in
  let* evaluated =
    Typesafeai_client.evaluate
      ?clock
      ~destinations
      ~state
      ~questions:[ relevance_question_id, relevance_question ~choices candidate ]
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
