open Base
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

(** Agent_card — A2A v0.3 agent card generation and caching.

    Builds the JSON agent card for Agent-to-Agent protocol discovery.

    @since 0.1.0 *)

(** {1 Types} *)

type provider = {
  organization : string;
  url : string option;
}

val provider_to_yojson : provider -> Yojson.Safe.t
val provider_of_yojson : Yojson.Safe.t -> (provider, string) Result.t
val show_provider : provider -> string
val equal_provider : provider -> provider -> bool

type skill = {
  id : string;
  name : string;
  description : string option;
  tags : string list;
  input_modes : string list;
  output_modes : string list;
  tool_count : int;
}

val skill_to_yojson : skill -> Yojson.Safe.t
val skill_of_yojson : Yojson.Safe.t -> (skill, string) Result.t
val show_skill : skill -> string
val equal_skill : skill -> skill -> bool

type binding = {
  protocol : string;
  url : string;
}

val binding_to_yojson : binding -> Yojson.Safe.t
val binding_of_yojson : Yojson.Safe.t -> (binding, string) Result.t
val show_binding : binding -> string
val equal_binding : binding -> binding -> bool

type security_scheme = {
  scheme_type : string;
  bearer_format : string option;
  api_key_name : string option;
  api_key_in : string option;
}

val security_scheme_to_yojson : security_scheme -> Yojson.Safe.t
val security_scheme_of_yojson :
  Yojson.Safe.t -> (security_scheme, string) Result.t
val show_security_scheme : security_scheme -> string
val equal_security_scheme : security_scheme -> security_scheme -> bool

type agent_capabilities = {
  streaming : bool;
  push_notifications : bool;
  extended_agent_card : bool;
}

type string_assoc = (string * string) list

type agent_card_signature = {
  protected_header : string;
  signature : string;
  header : string_assoc;
}

type agent_card = {
  name : string;
  version : string;
  description : string option;
  provider : provider option;
  protocol_versions : string list;
  capabilities : agent_capabilities;
  skills : skill list;
  supported_interfaces : binding list;
  security_schemes : (string * security_scheme) list;
  default_input_modes : string list;
  default_output_modes : string list;
  extensions : (string * Yojson.Safe.t) list;
  signatures : agent_card_signature list;
  icon_url : string option;
  documentation_url : string option;
  created_at : string;
  updated_at : string;
}

val show_agent_card : agent_card -> string
val equal_agent_card : agent_card -> agent_card -> bool

(** {1 Serialization} *)

val capabilities_to_json : agent_capabilities -> Yojson.Safe.t
val capabilities_of_json : Yojson.Safe.t -> agent_capabilities
val signature_to_json : agent_card_signature -> Yojson.Safe.t
val signature_of_json : Yojson.Safe.t -> agent_card_signature option
val to_json : agent_card -> Yojson.Safe.t
val from_json : Yojson.Safe.t -> (agent_card, string) Result.t

(** {1 Construction} *)

val now_iso8601 : unit -> string
val skills_from_tools : Types.tool_schema list -> skill list
val runtime_supported_interfaces : host:string -> port:int -> binding list
val generate_default :
  ?port:int -> ?host:string -> ?schemas:Types.tool_schema list -> unit -> agent_card

(** {1 Immutable Updates} *)

val with_interfaces : agent_card -> binding list -> agent_card
val with_bindings : agent_card -> binding list -> agent_card
val with_extension : agent_card -> string -> Yojson.Safe.t -> agent_card

(** {1 Cache} *)

val get_cached :
  ?port:int -> ?host:string -> schemas:Types.tool_schema list -> unit ->
  agent_card * string
val invalidate_cache : unit -> unit
