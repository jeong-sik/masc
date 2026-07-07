(** Shared keeper chat connector identity.

    This is the single source of truth for the closed connector set used by the
    keeper chat queue and continuation-channel provenance. *)

type t =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

type decode_error =
  | Missing_kind
  | Missing_discord_fields
  | Missing_slack_fields
  | Unsupported_kind of string

val to_yojson : t -> Yojson.Safe.t
val decode_error_to_string : decode_error -> string
val decode_error_to_chat_queue_source_string : decode_error -> string
val of_yojson_with_error : Yojson.Safe.t -> (t, decode_error) result
val of_yojson : Yojson.Safe.t -> (t, string) result
