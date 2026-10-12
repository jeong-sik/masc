(** Keeper_tooling.Response - provider response acceptance and keeper reply text
    normalization. *)

let normalize_response_text ~(text : string) ~(tool_names : string list) ()
  : (string, string) result
  =
  let trimmed = String.trim text in
  if trimmed <> ""
  then Ok text
  else (
    match tool_names with
    | [] -> Error "keeper turn completed with no textual reply"
    | _ -> Ok "")
;;

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
  let response_shape = Agent_core.Response_shape.content_shape response shape in
  if response.stop_reason = Agent_core.Types.MaxTokens
  then
    Some
      { kind = No_usable_progress
      ; reason = Agent_core.Response_shape.diagnostic_summary response
      ; response_shape = Some response_shape
      }
  else if not (Agent_core.Response_shape.has_deliverable_content shape) then
    Some
      { kind = No_usable_progress
      ; reason = Agent_core.Response_shape.diagnostic_summary response
      ; response_shape = Some response_shape
      }
  else None
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

let response_has_text_or_tool_progress (response : Agent_core.Types.api_response) =
  Option.is_none (response_accept_rejection response)
;;

type completion_policy = Require_progress | Allow_quiet_final

let is_quiet_final ~policy (response : Agent_core.Types.api_response) =
  match policy, response.stop_reason with
  | Allow_quiet_final, Agent_core.Types.EndTurn ->
    (match Agent_core.Response_shape.content_shape response
        (Agent_core.Response_shape.summarize response) with
     | Blank_text_only -> true
     | Empty | Thinking_only | Tool_result_only | Media_only
     | Mixed_without_deliverable_content | Has_deliverable_content -> false)
  | Require_progress, _ -> false
  | Allow_quiet_final,
    (StopToolUse | MaxTokens | StopSequence | Refusal | ContentFilter
    | RepetitionTruncation | PauseTurn | Compaction | ContextWindowExceeded
    | UnmatchedToolCalls | Unknown _) -> false
;;

let accepts_response ~policy response =
  response_has_text_or_tool_progress response || is_quiet_final ~policy response
;;
