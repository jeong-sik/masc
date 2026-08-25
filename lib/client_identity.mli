(** Agent Identity - Unified agent identification for MCP sessions

    @since 0.5.0
*)

(** Connection surface known to core.
    External platform names stay opaque so core does not depend on connector vendors. *)
type channel =
  | Api
  | Internal
  | External of string

(** Provenance of [agent_name]: caller-supplied vs system-minted
    fallback. Carried so the auth-fallback gate decides ephemerality
    from a typed origin instead of re-probing the name string. *)
type agent_name_origin =
  [ `Supplied
  | `System_fallback
  ]
[@@deriving to_yojson]

(** Agent identity record *)
type t = {
  uuid : string;              (** Permanent unique identifier *)
  session_key : string;
  agent_name : string;
  agent_name_origin : agent_name_origin;
      (** Provenance of [agent_name] (see {!agent_name_origin}). *)
  channel : channel option;
  user_id : string option;
  capabilities : string list;
  registered_at : float;
  last_seen : float;
  metadata : (string * string) list;
}

(** {1 Channel Utilities} *)

val channel_of_string : string -> channel
val string_of_channel : channel -> string

(** {1 Identity Creation} *)

val generate_uuid : agent_name:string -> string
(** Generate a canonical UUIDv7. [agent_name] remains display metadata and is
    not encoded in the identifier. Existing persisted identifiers stay
    readable because registry records treat this field as opaque text. *)
val generate_session_key : unit -> string
(** Generate a 32-character cryptographically random hex key. Its random
    prefix remains suitable for fallback display-name derivation. *)
val from_mcp_params : Yojson.Safe.t -> t
val anonymous : unit -> t

(** {1 Utilities} *)

val has_capability : t -> string -> bool
val to_display_string : t -> string
val same_agent : t -> t -> bool

(** {1 JSON Serialization} *)

val channel_to_yojson : channel -> Yojson.Safe.t
val channel_of_yojson : Yojson.Safe.t -> (channel, string) Result.t
val to_yojson : t -> Yojson.Safe.t
