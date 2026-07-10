(** RFC-0232 P2 — producer-typed turn outcome.  See the interface for
    the contract; this module is the single mapping site from
    {!Runtime_agent.stop_reason} to the reply-surface outcome. *)

type t =
  | Visible_reply
  | Continuation_checkpoint
  | No_visible_reply

let equal a b =
  match (a, b) with
  | Visible_reply, Visible_reply
  | No_visible_reply, No_visible_reply
  | Continuation_checkpoint, Continuation_checkpoint ->
      true
  | (Visible_reply | Continuation_checkpoint | No_visible_reply), _ -> false

let to_label = function
  | Visible_reply -> "visible_reply"
  | Continuation_checkpoint -> "continuation_checkpoint"
  | No_visible_reply -> "no_visible_reply"

let of_label = function
  | "visible_reply" -> Some Visible_reply
  | "continuation_checkpoint" -> Some Continuation_checkpoint
  | "no_visible_reply" -> Some No_visible_reply
  | _ -> None

let wire_key = "turn_outcome"

let turn_ref_wire_key = "turn_ref"

let of_stop_reason = function
  | Runtime_agent.Completed -> Visible_reply
  | Runtime_agent.TurnBudgetExhausted _ -> Continuation_checkpoint
  | Runtime_agent.MutationBoundaryReached _ -> Continuation_checkpoint
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_to_blocking_approval _ -> Continuation_checkpoint

let of_result_surface ~response_text = function
  | Runtime_agent.Completed ->
      if String.trim response_text = "" then No_visible_reply else Visible_reply
  | Runtime_agent.TurnBudgetExhausted _ -> Continuation_checkpoint
  | Runtime_agent.MutationBoundaryReached _ -> Continuation_checkpoint
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_to_blocking_approval _ -> Continuation_checkpoint

let of_reply_payload payload =
  match payload with
  | None -> Visible_reply
  | Some json -> (
      match Json_util.get_string json wire_key with
      | None -> Visible_reply
      | Some label -> (
          match of_label label with
          | Some outcome -> outcome
          | None ->
              (* Unknown label: report, then fail toward persisting —
                 the bitten failure mode (#20870) was silent
                 non-persistence (watermark stall, keeper re-answering
                 the same message).  Never widen [of_label] itself. *)
              Log.Keeper.warn
                "turn_outcome: unknown label %S; treating as \
                 visible_reply"
                label;
              Visible_reply))

let turn_ref_of_reply_payload payload =
  (* RFC-0233 §7: read the turn's join key the keeper minted into the
     reply payload.  Parse, don't repair — an absent field (legacy or
     transport-failure rows) or a malformed value both decode to [None];
     [Ids.Turn_ref.of_string] never raises and never guesses. *)
  Option.bind payload (fun json ->
      match Json_util.get_string json turn_ref_wire_key with
      | None -> None
      | Some s -> Ids.Turn_ref.of_string s)
