let min_confidence_threshold = 0.5

type judged =
  { verdict : Keeper_board_attention_judgment.t
  ; model : string
  }

let ( let* ) = Result.bind

let make_attention_question candidate =
  let question_id = "relevance" in
  let instructions =
    Printf.sprintf
      "Does the Board post in items[0] require attention, review, or action from keeper %S based on keeper_context?"
      candidate.Keeper_board_attention_candidate.keeper_name
  in
  let criteria =
    [ ( "relevant"
      , Some
          "The post directly mentions, requests, assigns tasks to, or concerns this keeper's instructions."
      )
    ; ( "not_relevant"
      , Some
          "The post is aimed at a different keeper, is general noise, or does not require this keeper to act."
      )
    ]
  in
  question_id, Typesafeai_types.Choice { instructions; criteria }
;;

let judge_candidate
      ?clock
      ?(confidence_threshold = min_confidence_threshold)
      ~api_key
      ~candidate
      ~material
      ()
  =
  let state =
    Keeper_board_attention_candidate.singleton_judgment_request
      candidate
      material
  in
  let q_id, q = make_attention_question candidate in
  let* response =
    Typesafeai_client.evaluate
      ?clock
      ~api_key
      ~state
      ~questions:[ q_id, q ]
      ()
  in
  let* verdict =
    match List.assoc_opt q_id response.answers with
    | Some (Typesafeai_types.Choice_answer { choice; confidence; probabilities }) ->
      if confidence < confidence_threshold
      then
        Error
          (Printf.sprintf
             "typesafeai: low confidence %.3f < %.3f for candidate %s, requesting fallback"
             confidence
             confidence_threshold
             candidate.candidate_id)
      else (
        match choice with
        | "relevant" ->
          let prob_str =
            List.map (fun (k, v) -> Printf.sprintf "%s:%.2f" k v) probabilities
            |> String.concat ", "
          in
          Ok
            { Keeper_board_attention_judgment.decision =
                Keeper_board_attention_judgment.Relevant
            ; rationale =
                Printf.sprintf
                  "TypeSafe AI Jev: relevant (confidence=%.2f, %s)"
                  confidence
                  prob_str
            }
        | "not_relevant" ->
          let prob_str =
            List.map (fun (k, v) -> Printf.sprintf "%s:%.2f" k v) probabilities
            |> String.concat ", "
          in
          Ok
            { Keeper_board_attention_judgment.decision =
                Keeper_board_attention_judgment.Not_relevant
            ; rationale =
                Printf.sprintf
                  "TypeSafe AI Jev: not_relevant (confidence=%.2f, %s)"
                  confidence
                  prob_str
            }
        | other ->
          Error
            (Printf.sprintf
               "typesafeai: unexpected choice %S for board-attention"
               other))
    | Some _ ->
      Error "typesafeai: expected choice answer for relevance question"
    | None ->
      Error "typesafeai: response missing answer for relevance question"
  in
  Ok { verdict; model = response.model }
;;
