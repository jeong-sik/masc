(** Immutable admitted provider declarations shared by registry and runtime
    projections. TOML seeds and an explicit JSON overlay are decoded elsewhere;
    this boundary replaces an exact seed id and rejects every remaining identity
    collision. No credential, environment, endpoint discovery or model inference
    is performed here. *)

type authentication =
  | No_auth
  | Caller_api_key
  | Api_key_env of string
  | Setup_token_env of string

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; base_url : string
  ; request_path : string
  ; authentication : authentication
  ; default_model : string option
  ; discovery_timeout_s : float option
    (** Explicit total deadline for one discovery HTTP request. *)
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; credential_scope : string option
  }

type error =
  | Unknown_capability_base of { provider_id : string; label : string }
  | Conflicting_identity of { identity : string; provider_ids : string list }

val error_to_string : error -> string

type t
val of_catalogs :
  models:Model_catalog.t option -> providers:Provider_catalog.t option ->
  (t, error) result
(** The explicit overlay replaces only the same canonical provider id,
    including its old aliases. An alias cannot replace a different provider id
    or alias. All remaining ids/aliases are unique under ASCII case equality. *)

val capture : unit -> (t, error) result
(** Read each explicit current source once. The result is immutable; separate
    source updates are not an atomic multi-catalog transaction. *)

exception Invalid_declarations of error
val current : unit -> t
(** Capture admitted global declarations or raise the typed admission error.
    Convenience for existing invariant-based registry/metadata APIs: invalid
    declarations never become an empty or partially loaded registry. *)

val entries : t -> entry list
(** Preserve the admitted declaration spellings; only identity lookup keys fold case. *)
val find : t -> string -> entry option
(** Lookup id or alias with ASCII case folding and trimmed query whitespace. *)
val request_policy : t -> provider_id:string -> model_id:string -> Capabilities.request_policy option
(** Resolve from this immutable selection's model catalog and admitted provider.
    [None] means the provider id/alias is absent from this selection. *)

val requires_api_key : authentication -> bool
