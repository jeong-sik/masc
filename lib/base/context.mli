(** Cross-turn shared state container.
    Values are [Yojson.Safe.t] for flexibility while maintaining
    serializability.

    @stability Stable
    @since 0.93.1 *)

type t

type scope =
  | App
  | User
  | Session
  | Temp
  | Custom of string

type diff =
  { added : (string * Yojson.Safe.t) list
  ; removed : string list
  ; changed : (string * Yojson.Safe.t) list
  }

type concurrency_backend =
  | Stdlib_mutex
  | Eio_mutex

(** Create a new context using {!Eio.Mutex}.

    This is the default for agent execution paths where the context may be
    shared across parallel fibers under an Eio scheduler. *)
val create : unit -> t

(** Create a new context using {!Stdlib.Mutex}.

    Use this for synchronous tests, serialization, or any code that runs
    outside of an Eio fiber. *)
val create_sync : unit -> t

val get : t -> string -> Yojson.Safe.t option
val set : t -> string -> Yojson.Safe.t -> unit
val delete : t -> string -> unit
val keys : t -> string list
val snapshot : t -> (string * Yojson.Safe.t) list
val scoped_key : scope -> string -> string
val get_scoped : t -> scope -> string -> Yojson.Safe.t option
val set_scoped : t -> scope -> string -> Yojson.Safe.t -> unit
val delete_scoped : t -> scope -> string -> unit
val keys_in_scope : t -> scope -> string list
val merge : t -> (string * Yojson.Safe.t) list -> unit
val diff : t -> t -> diff
val to_json : t -> Yojson.Safe.t
val concurrency_backend : t -> concurrency_backend

(** Deserialize from a JSON object.

    [~eio:true] rehydrates the context with an {!Eio.Mutex}; the default
    [~eio:false] is for synchronous decoding/storage code. Raises
    [Invalid_argument] if [json] is not a JSON object. *)
val of_json : ?eio:bool -> Yojson.Safe.t -> t

(** Shallow-copy all entries into a fresh context.
    Values are [Yojson.Safe.t] (structurally immutable), so shallow copy
    is sufficient for full independence. By default the copy preserves the
    source context's concurrency backend; [~eio] overrides it explicitly. *)
val copy : ?eio:bool -> t -> t

(** Isolated scope for sub-agent delegation.
    Only specified keys propagate between parent and child contexts. *)
type isolated_scope =
  { parent : t
  ; local : t
  ; propagate_up : string list
  ; propagate_down : string list
  }

val create_scope
  :  parent:t
  -> propagate_down:string list
  -> propagate_up:string list
  -> isolated_scope

val merge_back : isolated_scope -> unit

(** {2 User data convenience API} *)

val set_user_data : t -> string -> Yojson.Safe.t -> unit
val get_user_data : t -> string -> Yojson.Safe.t option
val delete_user_data : t -> string -> unit

(** All key-value pairs in the [User] scope (keys without prefix). *)
val all_user_data : t -> (string * Yojson.Safe.t) list
