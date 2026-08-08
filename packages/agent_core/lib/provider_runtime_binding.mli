(** Read-only runtime provider bindings.

    This module exposes the provider catalog / registry facts that embedding
    applications need without exposing registry mutation. It is intentionally
    coordinator-neutral: downstream applications may project local policy over
    these bindings, but OAS owns provider/model identity and capability truth.

    @since 0.194.0 *)

type provider_kind = Llm_provider.Provider_config.provider_kind
type capabilities = Llm_provider.Capabilities.capabilities

type auth =
  | No_auth
  | Api_key_env of string
  | Setup_token_env of string

type t =
  { id : string
  ; aliases : string list
  ; kind : provider_kind
  ; base_url : string
  ; request_path : string
  ; api_key_env : string
  ; auth : auth
  ; default_model : string option
  ; max_context : int option
  ; capabilities : capabilities
  ; available : bool
  ; credential_scope : string option
  }

(** Return all known runtime bindings from the explicit provider-catalog
    overlay, embedded OAS catalog, and default provider registry. *)
val all : unit -> t list

(** Find a runtime binding by provider id or alias. Lookup is
    case-insensitive and whitespace-trimmed. *)
val find : string -> t option

(** Find a runtime binding only from the explicitly installed provider-catalog
    overlay. Embedded and registry providers are intentionally excluded. *)
val find_catalog : string -> t option

(** Return all known binding ids and selector aliases. This is a display /
    diagnostics surface; callers should use {!find} for resolution. *)
val known_labels : unit -> string list

(** Resolve the runtime binding explicitly carried by a concrete provider
    config. Provider aliases are canonicalized through {!find}. A config with
    no [provider_id], or an unknown explicit id, has no binding; endpoint URLs,
    request paths, and model ids are never reverse-matched. *)
val binding_for_provider_config : Llm_provider.Provider_config.t -> t option

(** Runtime provider id for a concrete provider config. A known explicit id or
    alias resolves to the canonical binding id; an unknown explicit id remains
    an opaque normalized id. Configs without an id use only their typed wire
    kind. Endpoint URLs, request paths, and model ids are never interpreted. *)
val provider_id_of_provider_config : Llm_provider.Provider_config.t -> string

(** Resolve OAS-owned provider capabilities for a concrete provider config.
    Explicit provider identity selects provider facts; otherwise only the typed
    wire kind is used. Exact provider/model or provider-independent model rows
    then override provider-level facts. No endpoint inference occurs. *)
val capabilities_for_provider_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Capabilities.capabilities

(** Resolve an exact caller model or the binding's catalog-declared default.
    Missing model identity is an explicit configuration error; OAS never
    invents a provider-specific model or expands aliases. *)
val resolve_model : t -> requested_model:string option -> (string, Error.sdk_error) result

(** Convert a binding into the low-level provider config used by OAS
    transports. *)
val to_provider_config
  :  ?model:string
  -> t
  -> (Llm_provider.Provider_config.t, Error.sdk_error) result
