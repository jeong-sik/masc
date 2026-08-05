module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

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
  mutable last_seen : float;
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

(** {1 Identity Registry} *)

module Registry : sig
  type registry

  val create : unit -> registry
  val register : registry -> t -> t
  val find_by_session : registry -> string -> t option
  val find_by_name : registry -> string -> t option
  val touch : registry -> string -> unit -> unit
  val unregister : registry -> string -> unit
  val list_all : registry -> t list
  (** All explicitly registered identities. [last_seen] remains observation
      data and is not used as lifecycle authority. *)
  val count : registry -> int
end

(** {1 Utilities} *)

val has_capability : t -> string -> bool
val to_display_string : t -> string
val same_agent : t -> t -> bool

(** {1 JSON Serialization} *)

val channel_to_yojson : channel -> Yojson.Safe.t
val channel_of_yojson : Yojson.Safe.t -> (channel, string) Result.t
val to_yojson : t -> Yojson.Safe.t

