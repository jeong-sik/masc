(** RFC-0232 P2 — producer-typed turn outcome.  See the interface for
    the contract; this module is the single mapping site from
    {!Runtime_agent.stop_reason} to the reply-surface outcome. *)

type t =
  | Visible_reply
  | Continuation_checkpoint

let equal a b =
  match (a, b) with
  | Visible_reply, Visible_reply
  | Continuation_checkpoint, Continuation_checkpoint ->
      true
  | (Visible_reply | Continuation_checkpoint), _ -> false

let to_label = function
  | Visible_reply -> "visible_reply"
  | Continuation_checkpoint -> "continuation_checkpoint"

let of_label = function
  | "visible_reply" -> Some Visible_reply
  | "continuation_checkpoint" -> Some Continuation_checkpoint
  | _ -> None

let wire_key = "turn_outcome"

let of_stop_reason = function
  | Runtime_agent.Completed -> Visible_reply
  | Runtime_agent.TurnBudgetExhausted _ -> Continuation_checkpoint
  | Runtime_agent.MutationBoundaryReached _ -> Continuation_checkpoint

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
