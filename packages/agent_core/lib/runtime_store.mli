(** File-based session store for the AGENT_CORE runtime.

    Provides path construction, text I/O, and serialization for
    sessions, artifacts, reports, and proofs.

    @stability Internal
    @since 0.93.1 *)

(** Store handle wrapping a root directory. *)
type t = { root : string }

(** {1 Store creation} *)

val create : ?root:string -> unit -> (t, Error.t) result
val ensure_dir : string -> (unit, Error.t) result
val ensure_tree : t -> string -> (unit, Error.t) result

(** {1 Path constructors} *)

val session_dir : t -> string -> string
val session_path : t -> string -> string
val artifacts_dir : t -> string -> string
val raw_traces_dir : t -> string -> string

(** {1 Text I/O} *)

val save_text : string -> string -> (unit, Error.t) result
val load_text : string -> (string, Error.t) result

(** {1 Session I/O} *)

val save_session : t -> Runtime.session -> (unit, Error.t) result
val load_session : t -> string -> (Runtime.session, Error.t) result
