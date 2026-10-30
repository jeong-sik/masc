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
  ; request_path : string
  ; requires_api_key : bool
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

(** Provider registry backed by atomic immutable snapshots. *)
type t

(** Create an empty registry. Reads observe one immutable snapshot and writes
    atomically swap a pure state transition. *)
val create : unit -> t

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

val of_declarations : Provider_declarations.t -> t
(** Project an already admitted immutable provider snapshot. Registry entries
    retain canonical ids; alias selection belongs to the declaration snapshot. *)

val authentication_available : Provider_declarations.authentication -> bool
(** Credential-availability edge: caller-supplied credentials are checked by
    the caller, environment-bound credentials are available only when nonblank. *)

(** Default registry projected from one immutable admitted declaration snapshot.
    The embedded catalog and explicit overlay are captured once. No second
    provider source or endpoint inference is consulted. Invalid declarations
    raise {!Provider_declarations.Invalid_declarations}; no fallback is loaded. *)
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
    snapshot with the healthy declarations. [clock] is forwarded to the probe and
    active endpoints retain their declared [discovery_timeout_s]. The previous
    snapshot is retained when [endpoints] is empty or none is healthy; the returned
    error preserves endpoint-local probe failures. No port scan or fallback
    declaration occurs.
    @since 0.86.0 *)
val refresh_llama_endpoints
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> endpoints:Discovery.endpoint list
  -> unit
  -> (Discovery.endpoint_status list, endpoint_refresh_error) result

(** Current active endpoint list (snapshot after last refresh).
    @since 0.86.0 *)
val active_llama_endpoints : unit -> Discovery.endpoint list
