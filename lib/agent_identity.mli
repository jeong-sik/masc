(** Agent Identity - Unified agent identification for MCP sessions

    @since 0.5.0
*)

(** Connection surface known to core.
    External platform names stay opaque so core does not depend on connector vendors. *)
type channel =
  | Api
  | Internal
  | External of string

(** Agent identity record *)
type t =
  { uuid : string (** Permanent unique identifier *)
  ; session_key : string
  ; agent_name : string
  ; channel : channel option
  ; user_id : string option
  ; room_id : string option
  ; capabilities : string list
  ; registered_at : float
  ; mutable last_seen : float
  ; metadata : (string * string) list
  }

(** {1 Channel Utilities} *)

val channel_of_string : string -> channel
val string_of_channel : channel -> string

(** {1 Identity Creation} *)

val generate_uuid : agent_name:string -> string
val generate_session_key : unit -> string
val from_mcp_params : Yojson.Safe.t -> t
val from_agent_name : string -> t
val anonymous : unit -> t

(** {1 Identity Registry} *)

module Registry : sig
  type registry

  val create : unit -> registry
  val register : registry -> t -> t
  val find_by_session : registry -> string -> t option
  val find_by_name : registry -> string -> t option
  val touch : registry -> string -> ?room_id:string -> unit -> unit
  val unregister : registry -> string -> unit
  val list_active : registry -> within_seconds:float -> t list
  val count : registry -> int
end

(** {1 Utilities} *)

val has_capability : t -> string -> bool
val to_display_string : t -> string
val same_agent : t -> t -> bool

(** {1 JSON Serialization} *)

val channel_to_yojson : channel -> Yojson.Safe.t
val channel_of_yojson : Yojson.Safe.t -> (channel, string) result
val to_yojson : t -> Yojson.Safe.t

(** {1 MAGI Archetype System} *)

(** MAGI archetypes for agent specialization *)
type archetype =
  | Melchior (** 🔬 Scientist *)
  | Balthasar (** 🪞 Mirror/Ethics *)
  | Casper (** ♟️ Strategist *)
  | Athena (** 🧠 Reasoner *)
  | Generalist (** 🌐 No specialization *)

val archetype_to_string : archetype -> string

(** Strict parse: returns [None] when the wire string is not one of the
    canonical archetype labels (with aliases). Prefer this over
    [archetype_of_string] for new code so drift is visible. Issue #8691. *)
val archetype_of_string_opt : string -> archetype option

(** Back-compat parse: returns [Generalist] on unknown strings and
    logs a warning so the typo is operator-visible. Issue #8691. *)
val archetype_of_string : string -> archetype

val archetype_emoji : archetype -> string
val get_archetype : t -> archetype
val set_archetype : t -> archetype -> t
val archetype_weight : archetype -> string -> float
