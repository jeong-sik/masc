(** One credential reference/value observation and its non-secret authority. *)

type requirement =
  | Not_required
  | Unknown_provider
  | Required_undeclared
  | Required_env of string
  | Required_inline
  | Required_file

type admission
(** Immutable, non-secret provider ownership, requirement and quota scope.
    Inline values and file contents are never retained here. *)

type materialized = private
  { api_key : Llm_provider.Secret.t
  ; admission : admission
  }
(** The transient secret and admission originate from the same observation. *)

val materialize :
  provider_id:string -> requires_api_key:bool option ->
  credential:Runtime_schema.credential option -> (materialized, string) result
(** [None] for [requires_api_key] means the selected provider has no catalog
    declaration. Missing Env/Inline values remain representable for runtime
    missing-auth projection; invalid File credentials fail materialization.
    Env aliases are selected together with their value, once. *)

val provider_id : admission -> string
val requirement : admission -> requirement
val quota_scope : admission -> Runtime_quota_window.scope

val require_key : materialized -> (Llm_provider.Secret.t, string) result
(** Fresh discovery requires an explicit or declared credential contract.
    Unknown providers, missing required declarations and empty required values
    are refused, without another reference or value lookup. *)

val resolve_explicit : Runtime_schema.credential -> (Llm_provider.Secret.t, string) result
(** Fresh anonymous-endpoint discovery with an explicit credential. Shares the
    reference/value selector; it does not invent a named provider. *)
