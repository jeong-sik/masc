(** Keeper_tooling.Response - provider response acceptance. *)

type accept_rejection_kind =
  | No_usable_progress
  | Predicate_rejected

type accept_rejection =
  { kind : accept_rejection_kind
  ; reason : string
  ; response_shape : Agent_core.Response_shape.content_shape option
  }

let response_accept_rejection (response : Agent_core.Types.api_response) =
  let shape = Agent_core.Response_shape.summarize response in
  let content_shape = Agent_core.Response_shape.content_shape response shape in
  let accepted =
    match response.stop_reason, content_shape with
    | Agent_core.Types.MaxTokens, _ -> false
    | EndTurn, (Blank_text_only | Empty | Thinking_only) -> true
    | ( ( EndTurn | StopToolUse | StopSequence | Refusal | ContentFilter
        | RepetitionTruncation | PauseTurn | Compaction | ContextWindowExceeded
        | UnmatchedToolCalls | Unknown _ )
      , ( Blank_text_only | Empty | Thinking_only | Tool_result_only | Media_only
        | Mixed_without_deliverable_content | Has_deliverable_content ) ) ->
      Agent_core.Response_shape.has_deliverable_content shape
  in
  if accepted
  then None
  else
    Some
      { kind = No_usable_progress
      ; reason = Agent_core.Response_shape.diagnostic_summary response
      ; response_shape = Some content_shape
      }
;;

let accept_rejection_of_response ~runtime_id response =
  match response_accept_rejection response with
  | Some rejection ->
    { rejection with
      reason =
        Printf.sprintf
          "response rejected by accept (runtime=%s): %s"
          runtime_id
          rejection.reason
    }
  | None ->
    let shape = Agent_core.Response_shape.summarize response in
    { kind = Predicate_rejected
    ; reason =
        Printf.sprintf
          "response rejected by accept (runtime=%s); \
           built_in_progress_contract=accepted"
          runtime_id
    ; response_shape =
        Some (Agent_core.Response_shape.content_shape response shape)
    }
;;

let accepts_response (response : Agent_core.Types.api_response) =
  Option.is_none (response_accept_rejection response)
;;
