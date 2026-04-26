(** Mention parsing module - Stateless/Stateful/Broadcast routing modes *)

(** Mention routing mode *)
type mode =
  | Stateless of string (** @agent → pick one available *)
  | Stateful of string (** @agent-adj-animal → specific agent *)
  | Broadcast of string (** @@agent → all of type *)
  | None (** No mention found *)

(** Convert mode to human-readable string *)
val mode_to_string : mode -> string

(** Extract base agent type from mention/nickname
    e.g., "local-gentle-gecko" → "local" *)
val agent_type_of_mention : string -> string

(** Check if mention follows nickname pattern (agent-adj-animal) *)
val is_nickname : string -> bool

(** Parse @mention from message content

    Priority:
    1. @@agent → Broadcast
    2. @agent-adj-animal → Stateful
    3. @agent → Stateless
*)
val parse : string -> mode

(** Extract raw mention target (backward-compatible) *)
val extract : string -> string option

(** Get target agents based on mode and available agents *)
val resolve_targets : mode -> available_agents:string list -> string list

(** Check whether content contains an exact direct mention for a target *)
val is_mentioned : string -> string -> bool

(** Check whether content contains an exact direct mention for any target *)
val any_mentioned : targets:string list -> string -> bool
