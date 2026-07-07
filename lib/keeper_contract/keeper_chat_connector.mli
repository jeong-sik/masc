(** Shared keeper chat connector identity.

    This is the single source of truth for the closed connector set used by the
    keeper chat queue and continuation-channel provenance. *)

type t =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

