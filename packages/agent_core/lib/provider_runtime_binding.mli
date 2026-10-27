(** Read-only runtime provider bindings.

    This module exposes the provider catalog / registry facts that embedding
    applications need without exposing registry mutation. It is intentionally
    coordinator-neutral: downstream applications may project local policy over
    these bindings, but AGENT_CORE owns provider/model identity and capability truth.

    @since 0.194.0 *)

type provider_kind = Llm_provider.Provider_config.provider_kind
type capabilities = Llm_provider.Capabilities.capabilities

type auth =
  | No_auth
  | Api_key
  | Setup_token

type t = private
  { id : string
  ; aliases : string list
  ; kind : provider_kind
  ; base_url : string
  ; request_path : string
  ; requires_api_key : bool
  ; auth : auth
  ; default_model : string option
  ; discovery_timeout_s : float option
    (** Explicit total deadline for one discovery HTTP request. *)
  ; max_context : int option
  ; capabilities : capabilities
  ; available : bool
  ; credential_scope : string option
  ; declarations : Llm_provider.Provider_declarations.t
    (** Immutable catalog selection owning this binding; construction and record
        updates are restricted to this module. *)
  }

val all_from_declarations : Llm_provider.Provider_declarations.t -> t list
(** Project exactly one admitted provider snapshot. Credentials are observed
    at this edge; model request policy is not resolved by metadata projection. *)

val find_in_declarations : Llm_provider.Provider_declarations.t -> string -> t option
(** Select id or alias from the same immutable snapshot used for listing. *)

(** Return runtime bindings from one captured declaration snapshot. Invalid
    declarations raise the typed admission error rather than fallback. *)
val all : unit -> t list

(** Find a runtime binding by provider id or alias. Lookup is
    case-insensitive and whitespace-trimmed. *)
val find : string -> t option

(** Find a runtime binding only from the explicitly installed provider-catalog
    overlay. Embedded and registry providers are intentionally excluded. *)
val find_catalog : string -> t option

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

(** Project the config-owned capabilities used by completion admission.
    {!to_provider_config} carries the selected binding's provider facts into
    the config; directly calling [Provider_config.make] with a provider id
    alone does not acquire them. This read never re-resolves provider aliases
    or consults the current registry as a fallback. Frozen absence follows
    request admission: anonymous OpenAI-compatible configs retain chat
    protocol defaults, while explicitly identified OpenAI-compatible providers
    without policy remain conservative. Native wires retain their protocol
    defaults and the request admission policy for forced tool choice. *)
val capabilities_for_provider_config
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Capabilities.capabilities

(** Resolve an exact caller model or the binding's catalog-declared default.
    Missing model identity is an explicit configuration error; AGENT_CORE never
    invents a provider-specific model or expands aliases. *)
val resolve_model : t -> requested_model:string option -> (string, Error.t) result

(** Convert a binding into a config with its selection-owned model policy
    already frozen, before any later global catalog replacement. *)
val to_provider_config
  :  ?model:string
  -> t
  -> (Llm_provider.Provider_config.t, Error.t) result
