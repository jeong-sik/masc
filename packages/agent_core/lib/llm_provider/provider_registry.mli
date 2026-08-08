(** Extensible provider registry with capability-aware queries.

    Formalizes the historical hardcoded provider list into a mutable
    registry. Providers can be registered at startup and queried by
    name or capability predicate.

    @since 0.69.0

    @stability Internal
    @since 0.93.1 *)

(** Provider defaults: how to connect to a provider. *)
type provider_defaults =
  { kind : Provider_config.provider_kind
  ; base_url : string
  ; api_key_env : string
  ; request_path : string
  }

(** A registered provider entry.
    [max_context] is the explicitly declared context window size in tokens.
    [None] means the provider declaration does not state one.
    @since 0.78.0 max_context added *)
type entry =
  { name : string
  ; defaults : provider_defaults
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; is_available : unit -> bool
  }

(** Mutable provider registry. *)
type t

(** Create an empty registry using {!Eio.Mutex}. *)
val create : unit -> t

(** Create an empty registry using {!Stdlib.Mutex} for synchronous tests and
    serialization code that runs outside of an Eio scheduler. *)
val create_sync : unit -> t

(** Register a provider. Overwrites if name already exists. *)
val register : t -> entry -> unit

(** Remove a provider by name. No-op if not found. *)
val unregister : t -> string -> unit

(** Look up a provider by name. *)
val find : t -> string -> entry option

(** All registered providers. *)
val all : t -> entry list

(** Providers where [is_available()] returns [true]. *)
val available : t -> entry list

(** Providers whose capabilities satisfy the given predicate. *)
val find_capable : t -> (Capabilities.capabilities -> bool) -> entry list

(** Check whether a command is discoverable from PATH without shelling out. *)
val command_in_path : ?path:string -> string -> bool

(** Default registry populated from the embedded provider catalog.
    Availability is determined by credential values only.

    Entries explicitly installed with {!Provider_catalog.set_global} are
    overlaid last and may add or replace provider ids without changing SDK
    code. OAS does not discover a provider catalog from the environment.

    Endpoint, request-path, provider-id, and capability values come only from
    those declarations. Process environment reads are restricted to credential
    availability and never reinterpret provider identity. *)
val default : unit -> t

(** Wire-kind label for a concrete provider config. This exhaustive projection
    never guesses a vendor/provider id from URL, model id, request path, host
    locality, aliases, or process environment. Registry identity must be carried
    separately by the explicit registry/catalog binding. *)
val provider_name_of_config : Provider_config.t -> string

(** Pick the next llama endpoint via round-robin.
    After [refresh_llama_endpoints], rotates across healthy declared endpoints.
    Returns [None] until a typed refresh succeeds.
    @since 0.78.0 *)
val next_llama_endpoint : unit -> Discovery.endpoint option

(** Peek at the current llama endpoint without advancing the round-robin.
    Returns the endpoint that [next_llama_endpoint] will return on its
    next call, but without the [fetch_and_add] side effect.
    Returns [None] when no typed endpoint declaration has been activated.
    @since 0.100.8 *)
val current_llama_endpoint : unit -> Discovery.endpoint option

(** Failure to refresh the active endpoint snapshot. *)
type endpoint_refresh_error =
  | No_endpoints_declared
  | No_healthy_endpoints of Discovery.endpoint_status list

(** Probe explicit typed endpoint declarations and replace the active endpoint
    snapshot with the healthy declarations. The previous snapshot is retained
    when [endpoints] is empty or none is healthy; the returned error preserves
    endpoint-local probe failures. No port scan or fallback declaration occurs.
    @since 0.86.0 *)
val refresh_llama_endpoints
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> endpoints:Discovery.endpoint list
  -> (Discovery.endpoint_status list, endpoint_refresh_error) result

(** Current active endpoint list (snapshot after last refresh).
    @since 0.86.0 *)
val active_llama_endpoints : unit -> Discovery.endpoint list

(** Per-slot context tokens from the last discovery probe.
    Returns [None] if no probe has completed yet.
    Delegates to {!Discovery.discovered_per_slot_context}.
    @since 0.100.8 *)
val discovered_max_context : unit -> int option

(** Per-slot context for a specific endpoint URL.
    Delegates to {!Discovery.discovered_context_for_url}.
    Returns [None] when no valid context has been discovered for this URL
    (either not probed or probed without reporting valid context properties).
    @since 0.100.8 *)
val discovered_endpoint_max_context : string -> int option
