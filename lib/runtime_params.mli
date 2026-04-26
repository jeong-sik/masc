(** Runtime_params — Typed parameter store with governance override.

    Provides a layer above env_config defaults that can be changed at runtime
    via governance decisions or MCP tools. All access is Eio.Mutex-protected.

    Override values persist to [.masc/runtime_params.json] via atomic rename.
    Changes are logged to [.masc/param_audit.jsonl].

    @since 2.96.0 *)

(** {1 Metadata} *)

(** Optional metadata for UI display and validation hints. *)
type param_meta =
  { description : string
  ; value_type : string
  ; min_value : Yojson.Safe.t option
  ; max_value : Yojson.Safe.t option
  }

(** {1 Parameter Handle} *)

(** Opaque typed parameter handle.  Obtained from {!register}. *)
type 'a param

(** {1 Registration} *)

(** Register a named parameter with default thunk, validation, and serialization.
    Optional [meta] provides UI hints (description, type, bounds).
    [?meta] is placed before [~deserialize] so existing callers need no change.
    Raises [Invalid_argument] if [key] is already registered. *)
val register
  :  key:string
  -> default:(unit -> 'a)
  -> validate:('a -> (unit, string) result)
  -> serialize:('a -> Yojson.Safe.t)
  -> deserialize:(Yojson.Safe.t -> ('a, string) result)
  -> ?meta:param_meta
  -> unit
  -> 'a param

(** {1 Read / Write} *)

(** Get current value.  Returns the override if set, otherwise the default. *)
val get : 'a param -> 'a

(** Set override.  Runs validation; persists on success. *)
val set : 'a param -> 'a -> (unit, string) result

(** Set override by string key and JSON value (for MCP / governance). *)
val set_by_key : string -> Yojson.Safe.t -> (unit, string) result

(** Clear override; reverts to env default. *)
val clear : 'a param -> unit

(** Clear override by string key. Returns [Error] if key is unknown. *)
val clear_by_key : string -> (unit, string) result

(** {1 Introspection} *)

(** [(key, current_json, default_json, has_override, meta)] for every registered param. *)
val registry
  :  unit
  -> (string * Yojson.Safe.t * Yojson.Safe.t * bool * param_meta option) list

(** {1 Persistence} *)

(** Persist current overrides to [.masc/runtime_params.json].
    Called after each successful [set] or [set_by_key]. *)
val persist : base_path:string -> unit

(** Restore overrides from [.masc/runtime_params.json].
    Call once during server startup. *)
val restore : base_path:string -> unit

(** {1 Audit} *)

(** Record a change to the audit log with optional governance case_id. *)
val record_audit
  :  base_path:string
  -> key:string
  -> old_value:Yojson.Safe.t
  -> new_value:Yojson.Safe.t
  -> ?case_id:string
  -> actor:string
  -> unit
  -> unit

(** Read the most recent [n] audit entries. *)
val recent_audit : base_path:string -> int -> Yojson.Safe.t list
