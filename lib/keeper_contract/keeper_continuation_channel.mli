(** Keeper continuation-channel provenance.

    [Routed] reuses {!Keeper_chat_connector.t}; [Unrouted] is the explicit
    fail-closed state when the originating connector cannot be determined. *)

type t =
  | Routed of Keeper_chat_connector.t
  | Unrouted of { reason : string }

val routed : Keeper_chat_connector.t -> t
val unrouted : string -> t
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val to_string : t -> string

