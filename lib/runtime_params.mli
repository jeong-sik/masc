(** Runtime_params — Typed runtime parameter store.

    Provides a layer above env_config defaults that can be changed at runtime
    through the authenticated runtime-settings API. All access is
    Eio.Mutex-protected.

    Override values persist to [.masc/runtime_params.json] via atomic rename.
    Changes are logged to [.masc/param_audit.jsonl].

    @since 2.96.0 *)

(** {1 Metadata} *)

(** Optional metadata for UI display and validation hints. *)
type param_meta = {
  description : string;
  value_type : string;
  min_value : Yojson.Safe.t option;
  max_value : Yojson.Safe.t option;
}

(** {1 Parameter Handle} *)

(** Opaque typed parameter handle.  Obtained from {!register}. *)
type 'a param

(** {1 Initialization} *)

(** Set the workspace base path used for automatic persistence and audit.
    Call once during server bootstrap before the first [set]/[clear].
    Per-call [?base_path] overrides this value. *)
val initialize : base_path:string -> unit

(** {1 Registration} *)

(** Register a named parameter with default thunk, validation, and serialization.
    Optional [meta] provides UI hints (description, type, bounds).
    [?meta] is placed before [~deserialize] so existing callers need no change.
    Raises [Invalid_argument] if [key] is already registered. *)
val register :
  key:string ->
  default:(unit -> 'a) ->
  validate:('a -> (unit, string) result) ->
  serialize:('a -> Yojson.Safe.t) ->
  deserialize:(Yojson.Safe.t -> ('a, string) result) ->
  ?meta:param_meta ->
  unit ->
  'a param

(** {1 Read / Write} *)

(** Get current value.  Returns the override if set, otherwise the default. *)
val get : 'a param -> 'a

(** Set override.  Runs validation; persists and audits on success when a
    base path is available via [initialize] or [?base_path]. *)
val set : ?base_path:string -> ?actor:string -> 'a param -> 'a -> (unit, string) result

(** Set override by string key and JSON value.
    Persists and audits on success when a base path is available. *)
val set_by_key :
  ?base_path:string -> ?actor:string -> string -> Yojson.Safe.t -> (unit, string) result

(** Clear override; reverts to env default.  Persists and audits the
    reversion when a base path is available. *)
val clear : ?base_path:string -> ?actor:string -> 'a param -> unit

(** Clear override by string key. Returns [Error] if key is unknown.
    Persists and audits the reversion when a base path is available. *)
val clear_by_key : ?base_path:string -> ?actor:string -> string -> (unit, string) result

(** {1 Introspection} *)

(** [(key, current_json, default_json, has_override, meta)] for every registered param. *)
val registry : unit -> (string * Yojson.Safe.t * Yojson.Safe.t * bool * param_meta option) list

(** {1 Persistence} *)

(** Persist current overrides to [.masc/runtime_params.json].
    Called after each successful [set] or [set_by_key]. *)
val persist : base_path:string -> unit

(** Restore overrides from [.masc/runtime_params.json].
    Call once during server startup. *)
val restore : base_path:string -> unit

(** {1 Audit} *)

(** Record a change to the audit log with an optional correlation id. *)
val record_audit :
  base_path:string ->
  key:string ->
  old_value:Yojson.Safe.t ->
  new_value:Yojson.Safe.t ->
  ?correlation_id:string ->
  actor:string ->
  unit ->
  unit

(** Read the most recent [n] audit entries. *)
val recent_audit : base_path:string -> int -> Yojson.Safe.t list
