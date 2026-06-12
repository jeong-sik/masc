(** Keeper_tool_response - provider response acceptance and keeper reply text
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
    | _ ->
      Ok
        (Printf.sprintf
           "Completed without a textual reply. Tools used: %s."
           (String.concat ", " tool_names)))
;;

type accept_rejection_kind =
  | No_usable_progress
  | Predicate_rejected

type accept_rejection =
  { kind : accept_rejection_kind
  ; reason : string
  }

let accept_rejection_kind_to_string = function
  | No_usable_progress -> "no_usable_progress"
  | Predicate_rejected -> "predicate_rejected"
;;

let response_accept_rejection (response : Agent_sdk.Types.api_response) =
  if Agent_sdk.Response_shape.ended_without_deliverable_content response
  then
    Some
      { kind = No_usable_progress
      ; reason = Agent_sdk.Response_shape.diagnostic_summary response
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
    { kind = Predicate_rejected
    ; reason =
        Printf.sprintf
          "response rejected by accept (runtime=%s); \
           built_in_progress_contract=accepted"
          runtime_id
    }
;;

let response_has_text_or_tool_progress (response : Agent_sdk.Types.api_response) =
  Option.is_none (response_accept_rejection response)
;;
