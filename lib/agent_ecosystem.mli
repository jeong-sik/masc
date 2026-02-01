(** Agent Ecosystem - Extended Agent Identity for Second Brain

    @since 0.6.0
*)

(** {1 Agent Ecosystem Types} *)

(** Agent lifecycle type *)
type agent_type =
  | Resident   (** 🏛️ Daemon - always running *)
  | Visitor    (** 🚶 Session-based *)
  | Ephemeral  (** ⚡ Task-based *)

(** Agent persona - public identity *)
type persona = {
  name : string;
  role : string;
  traits : string list;
  avatar : string option;
}

(** Agent lineage - generational tracking *)
type lineage = {
  generation : int;
  parent_hash : string option;
  ancestors : string list;
  mutations : string list;
}

(** Extended agent identity *)
type extended = {
  base : Agent_identity.t;
  hash : string;
  agent_type : agent_type;
  persona : persona;
  lineage : lineage;
}

(** {1 Defaults} *)

val default_persona : string -> persona
val default_lineage : lineage

(** {1 Hash Generation} *)

val hash_of_session_key : string -> string

(** {1 Agent Type Utilities} *)

val agent_type_of_string : string -> agent_type
val string_of_agent_type : agent_type -> string
val agent_type_emoji : agent_type -> string

(** {1 Extended Identity Creation} *)

val extend : ?agent_type:agent_type -> ?persona:persona option -> ?lineage:lineage option -> Agent_identity.t -> extended
val from_mcp_params : Yojson.Safe.t -> extended
val from_agent_name : ?agent_type:agent_type -> ?role:string -> string -> extended
val anonymous : unit -> extended
val spawn_child : parent:extended -> child_name:string -> role:string -> extended
val add_mutation : extended -> string -> extended

(** {1 Utilities} *)

val to_display_string : extended -> string
val to_identity_card : extended -> string
val same_agent : extended -> extended -> bool

(** {1 Metadata-based Storage} *)

val to_base_with_metadata : extended -> Agent_identity.t
val from_base_with_metadata : Agent_identity.t -> extended

(** {1 JSON Serialization} *)

val agent_type_to_yojson : agent_type -> Yojson.Safe.t
val agent_type_of_yojson : Yojson.Safe.t -> (agent_type, string) result
val persona_to_yojson : persona -> Yojson.Safe.t
val persona_of_yojson : Yojson.Safe.t -> (persona, string) result
val lineage_to_yojson : lineage -> Yojson.Safe.t
val lineage_of_yojson : Yojson.Safe.t -> (lineage, string) result
val extended_to_yojson : extended -> Yojson.Safe.t
val extended_of_yojson : Yojson.Safe.t -> (extended, string) result

(** {1 Derived Functions} *)

val pp_agent_type : Format.formatter -> agent_type -> unit
val show_agent_type : agent_type -> string
val equal_agent_type : agent_type -> agent_type -> bool

val pp_persona : Format.formatter -> persona -> unit
val show_persona : persona -> string
val equal_persona : persona -> persona -> bool

val pp_lineage : Format.formatter -> lineage -> unit
val show_lineage : lineage -> string
val equal_lineage : lineage -> lineage -> bool

(** {1 Registry for Extended Identities} *)

module Registry : sig
  type t

  val create : unit -> t
  val register : t -> extended -> extended
  val find_by_hash : t -> string -> extended option
  val find_by_session : t -> string -> extended option
  val find_by_name : t -> string -> extended option
  val touch : t -> string -> unit
  val unregister : t -> string -> unit
  val list_by_type : t -> agent_type -> extended list
  val list_active : t -> within_seconds:float -> extended list
  val count : t -> int
  val count_by_type : t -> agent_type -> int
end
