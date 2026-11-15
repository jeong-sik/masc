(* Connector_self_mention — the bot's own mention names the Keeper the
   channel is bound to, whatever the platform calls the bot (#28401, #51900).
   The platform display name is another name: a Keeper that read "@KinoBot"
   for itself took it for a different bot and refused the turn. *)

type t =
  | Bot_user_id_unknown
  | Bound_keeper of { bot_user_id : string; keeper_name : string }

let label self ~user_id =
  match self with
  | Bot_user_id_unknown -> None
  | Bound_keeper { bot_user_id; keeper_name } ->
    if String.equal user_id bot_user_id then Some keeper_name else None
