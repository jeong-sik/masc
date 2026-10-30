(** Shared protocol declarations for parsing and the structured runtime editor. *)

type editor_transport =
  | Endpoint
  | Command

type editor_semantics =
  | Http_provider
  | Official_client

type editor_credential_policy =
  | Credentials_optional
  | Credentials_forbidden
  | Credentials_file_required

type editor_protocol =
  { protocol : string
  ; transport : editor_transport
  ; semantics : editor_semantics
  ; credential_policy : editor_credential_policy
  ; requires_non_interactive : bool
  ; provider_fields : string list
  ; required_provider_fields : string list
  }

val editor_protocols : editor_protocol list
(** Backend-owned protocols that the structured runtime editor may create.
    Protocols that parse but cannot materialize as a production runtime are
    deliberately absent. *)

val resolve : string -> (string * Runtime_schema.api_format, string) result
(** Resolve one declared protocol. Unknown labels return [Error], without defaults. *)

val api_format_of_protocol : string -> (Runtime_schema.api_format, string) result
