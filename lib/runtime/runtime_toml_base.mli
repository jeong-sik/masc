(** The parts of the Runtime TOML parser that every layer reader uses: the
    error value and its accumulation helpers, the protocol-to-api-format
    table and the transport extraction. *)

type parse_error =
  { path : string
  ; message : string
  }
[@@deriving show]

(* --- Error accumulation --- *)

val error : string -> string -> parse_error list

val unknown_table_keys :
  path:string ->
  expected:string list -> (string * Otoml.t) list -> parse_error list

val typed_find :
  string ->
  string ->
  Otoml.t ->
  string -> (Otoml.t -> 'a) -> ('a option, parse_error list) result

val typed_find_or :
  string ->
  string ->
  Otoml.t ->
  string -> (Otoml.t -> 'a) -> default:'a -> ('a, parse_error list) result

val strict_float_find :
  string -> Otoml.t -> string -> (float option, parse_error list) result

val positive_finite_float_opt_field :
  path:string ->
  key:string ->
  (float option, parse_error list) result ->
  (float option, parse_error list) result

val required_non_empty_string :
  ?trim_result:bool ->
  Otoml.t ->
  path:string ->
  key:string -> message:string -> (string, parse_error list) result

val partition_results :
  ('a, parse_error list) result list -> ('a list, parse_error list) result

type editor_transport = Runtime_protocol.editor_transport = Endpoint | Command

type editor_semantics = Runtime_protocol.editor_semantics = Http_provider | Official_client

type editor_credential_policy = Runtime_protocol.editor_credential_policy =
  | Credentials_optional
  | Credentials_forbidden
  | Credentials_file_required

type editor_protocol = Runtime_protocol.editor_protocol =
  { protocol : string
  ; transport : editor_transport
  ; semantics : editor_semantics
  ; credential_policy : editor_credential_policy
  ; requires_non_interactive : bool
  ; provider_fields : string list
  ; required_provider_fields : string list
  }

val editor_protocols : editor_protocol list

val api_format_of_protocol :
  string -> (Runtime_schema.api_format, string) result

val transport_of_provider :
  path:string ->
  Otoml.t -> string -> (Runtime_schema.transport, parse_error list) result

module Ns = Runtime_toml_namespace

val obsolete_top_level_namespaces : string list

val reserved_provider_ids : string list

val is_reserved : string -> bool

val validate_runtime_id_component :
  allow_dot:bool ->
  kind:string -> path:string -> string -> (unit, parse_error list) result

val validate_provider_id :
  path:string -> string -> (unit, parse_error list) result
