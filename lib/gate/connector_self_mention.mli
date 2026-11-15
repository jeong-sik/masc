(** Connector_self_mention — who the bot's own mention stands for in one
    inbound connector message.

    One bot account (a Slack app, a Discord application) can serve channels
    bound to different Keepers, so the channel binding, not the account,
    says who the bot is in a given message. A connector renders mentions
    only after it has read that binding, and asks {!label} about each
    mentioned id before it uses the platform's display name. *)

type t =
  | Bot_user_id_unknown
      (** The connector has no bot user id, so no mention can be told
          apart as the bot's own; every mention renders by the platform's
          display name. *)
  | Bound_keeper of { bot_user_id : string; keeper_name : string }
      (** The bot is [bot_user_id] and the message's channel is bound to
          [keeper_name]. *)

val label : t -> user_id:string -> string option
(** [Some keeper_name] when [user_id] equals the bound bot's
    [bot_user_id], else [None]. Decided by id equality alone; display
    names are never compared. *)
