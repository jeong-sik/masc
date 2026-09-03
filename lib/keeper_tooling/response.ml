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

let accept_rejection_kind_to_string = function
  | No_usable_progress -> "no_usable_progress"
  | Predicate_rejected -> "predicate_rejected"
;;

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
