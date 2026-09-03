(** RFC-0232 P2 — producer-typed turn outcome.  See the interface for
    the contract; this module is the single mapping site from
    {!Runtime_agent.stop_reason} to the reply-surface outcome. *)

type t =
  | Visible_reply
  | Continuation_checkpoint
  | Terminal_effect_settled
  | Awaiting_gate_approval
  | No_visible_reply

let equal a b =
  match (a, b) with
  | Visible_reply, Visible_reply
  | No_visible_reply, No_visible_reply
  | Terminal_effect_settled, Terminal_effect_settled
  | Awaiting_gate_approval, Awaiting_gate_approval
  | Continuation_checkpoint, Continuation_checkpoint ->
      true
  | ( Visible_reply
    | Continuation_checkpoint
    | Terminal_effect_settled
    | Awaiting_gate_approval
    | No_visible_reply ), _ ->
    false

let to_label = function
  | Visible_reply -> "visible_reply"
  | Continuation_checkpoint -> "continuation_checkpoint"
  | Terminal_effect_settled -> "external_effect_completed"
  | Awaiting_gate_approval -> "external_effect_pending"
  | No_visible_reply -> "no_visible_reply"

let of_label = function
  | "visible_reply" -> Some Visible_reply
  | "continuation_checkpoint" -> Some Continuation_checkpoint
  | "external_effect_completed" -> Some Terminal_effect_settled
  | "external_effect_pending" -> Some Awaiting_gate_approval
  | "no_visible_reply" -> Some No_visible_reply
  | _ -> None

let wire_key = "turn_outcome"

let turn_ref_wire_key = "turn_ref"

let of_stop_reason = function
  | Runtime_agent.Completed -> Visible_reply
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    Continuation_checkpoint
  | Runtime_agent.InputRequired _ -> Visible_reply

let of_result_surface ~response_text = function
  | Runtime_agent.Completed ->
      if String.trim response_text = "" then No_visible_reply else Visible_reply
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    Continuation_checkpoint
  | Runtime_agent.InputRequired _ -> Visible_reply

type decode_error =
  | Payload_missing
  | Payload_not_object
  | Turn_outcome_missing
  | Turn_outcome_duplicate
  | Turn_outcome_not_string
  | Turn_outcome_unknown of string

let decode_error_to_string = function
  | Payload_missing -> "keeper reply payload is missing"
  | Payload_not_object -> "keeper reply payload must be an object"
  | Turn_outcome_missing -> "keeper reply payload is missing turn_outcome"
  | Turn_outcome_duplicate ->
    "keeper reply payload contains duplicate turn_outcome fields"
  | Turn_outcome_not_string ->
    "keeper reply payload field turn_outcome must be a string"
  | Turn_outcome_unknown label ->
    Printf.sprintf "keeper reply payload contains unknown turn_outcome %S" label
;;

let of_reply_payload payload =
  match payload with
  | None -> Error Payload_missing
  | Some (`Assoc fields) ->
    (match
       List.filter_map
         (fun (key, value) ->
            if String.equal key wire_key then Some value else None)
         fields
     with
     | [] -> Error Turn_outcome_missing
     | [ `String label ] ->
       (match of_label label with
        | Some outcome -> Ok outcome
        | None -> Error (Turn_outcome_unknown label))
     | [ _ ] -> Error Turn_outcome_not_string
     | _ -> Error Turn_outcome_duplicate)
  | Some _ -> Error Payload_not_object

let turn_ref_of_reply_payload payload =
  (* RFC-0233 §7: read the turn's join key the keeper minted into the
     reply payload.  Parse, don't repair — an absent field (legacy or
     transport-failure rows) or a malformed value both decode to [None];
     [Ids.Turn_ref.of_string] never raises and never guesses. *)
  Option.bind payload (fun json ->
      match Json_util.get_string json turn_ref_wire_key with
      | None -> None
      | Some s -> Ids.Turn_ref.of_string s)
