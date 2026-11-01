(** One admitted immutable provider/model selection and its publication owner.
    Decoded input catalogs have no independent publication authority. *)

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
  ; max_context : int option
  ; capabilities : Capability_profile.capabilities
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
(** Admit the complete pair without reading or changing global state. An
    explicit provider overlay replaces the whole same canonical seed id,
    including its old aliases. Reject all remaining identity collisions and
    unknown capability bases. [models=None] explicitly captures absent model
    facts; [providers=None] means no JSON overlay. Neither selects a fallback. *)

val models : t -> Model_catalog.t option
val model_catalog_for_provider :
  t -> Model_catalog.provider_reference -> Model_catalog.t option
(** Exact model lookup view using only this admitted provider's aliases and
    bare-row permissions. Raw id-based observations do not acquire the JSON
    provider's capability profile or credentials. Anonymous wires retain their
    protocol scope. Removed aliases retain only exact custom scoped rows. *)
val sources : t -> Model_catalog.t option * Provider_catalog.t option
(** The immutable explicit input pair owned by this selection, for callers
    preparing another complete configuration. This does not read global state,
    interpret policy again or permit either input to be changed in place. *)
val entries : t -> entry list
(** Preserve admitted declaration order and spelling. *)
val find : t -> string -> entry option
(** Exact id/alias lookup under ASCII case folding and trimmed query whitespace. *)
val policy_provider : t -> string -> (entry * Model_catalog.provider_entry) option
(** The admitted entry and its selected model-policy authority. *)
val requires_api_key : authentication -> bool
val supports_parallel_tool_suppression : t -> provider_id:string -> bool

type default_error =
  | Invalid_model_catalog of string
  | Invalid_provider_declarations of error
exception Invalid_default_catalog of default_error
(** The immutable generated default is a build invariant. Invalid generated
    data is reported rather than becoming an empty or partial selection. *)

val publish : t -> unit
(** Replace one atomic reference with this already admitted whole value. *)
val current : unit -> t
(** Read one complete publication. Without an explicit publication, select the
    pure thread-safe lazy admission of the build-time embedded default. The
    immutable cached constant is not an independently mutable catalog source.
    Raises [Invalid_default_catalog] only when that generated default is invalid. *)
val reset : unit -> unit
(** Remove the explicit publication and select the immutable embedded default.
    Previously captured values remain unchanged. *)
