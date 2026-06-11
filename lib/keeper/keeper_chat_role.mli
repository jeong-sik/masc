(** Keeper_chat_role — typed message-role types for the keeper chat lane.

    Centralises the [role] type used by [keeper_chat_events] and
    [keeper_chat_store] so that serialisation and pattern matching
    are consistent across the chat pipeline.

    @since 2.146.0 *)

(** {1 Types} *)

type t = User | Assistant
(** [t] represents the actor of a chat message.
    [User] = human operator, [Assistant] = keeper/agent. *)

(** {1 Construction} *)

val of_string : string -> (t, [> `Msg of string ]) result
(** [of_string s] parses ["user"] / ["assistant"] (case-insensitive).
    Returns [Error (`Msg ...)] for unrecognised values. *)

val to_string : t -> string
(** [to_string t] returns ["user"] or ["assistant"]. *)

(** {1 JSON helpers} *)

val to_yojson : t -> Yojson.Safe.t
(** [to_yojson t] returns [`String "user"] or [`String "assistant"]. *)

val of_yojson : Yojson.Safe.t -> (t, [> `Msg of string ]) result
(** [of_yojson json] wraps [of_string] on the string value.
    Returns [Error] for non-string or unrecognised values. *)