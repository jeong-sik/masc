(** Backend_types — shared types for Backend modules.

    Single source of truth for error types, config, and shared utilities
    used by all [_eio] backend implementations. *)

(** {1 Error Types — no silent failures} *)

type error =
  | NotFound of string
  | AlreadyExists of string
  | IOError of string
  | InvalidKey of string
  | ConnectionFailed of string
  | BackendNotSupported of string
[@@deriving show]

(** Result alias pinned to [error]. *)
type 'a result = ('a, error) Stdlib.result

(** {1 Backend selection} *)

type backend_type =
  | Memory
  | FileSystem
[@@deriving show, eq]

(** {1 Health} *)

type health_result =
  { latency_ms : float
  ; is_healthy : bool
  }

(** {1 Config} *)

type config =
  { backend_type : backend_type
  ; base_path : string
  ; node_id : string
  ; cluster_name : string
  ; pubsub_max_messages : int
  }

(** Currently returns a fixed literal (1000). Kept as a function to
    allow future env-var override without API change. *)
val pubsub_max_messages_from_env : unit -> int

(** Generate a node identifier of the form
    ["<hostname>-<pid>-<rand4hex>"], suitable for
    single-instance disambiguation in logs. *)
val generate_node_id : unit -> string

(** Default config: [FileSystem] backend rooted at [".masc"], cluster
    ["default"], and [pubsub_max_messages = pubsub_max_messages_from_env ()]. *)
val default_config : config

(** {1 Status reporting} *)

(** Serialise [config] as a JSON object — [backend_type] is rendered
    as ["memory"] or ["filesystem"]; [pubsub_max_messages] is omitted. *)
val get_status : config -> Yojson.Safe.t

(** {1 Safety utilities} *)

(** Clamp [ttl_seconds] to [1 .. Masc_time_constants.day_int]. Non-positive
    inputs collapse to [1]; values above 24h collapse to [day_int]. *)
val validate_ttl : int -> int

(** [acquire_flock fd]: [Unix.F_TLOCK] — non-blocking exclusive lock.
    Returns [true] on success, [false] on [EAGAIN]/[EACCES] or any other error. *)
val acquire_flock : Unix.file_descr -> bool

(** Best-effort release — logs a warning on failure. *)
val release_flock : Unix.file_descr -> unit

(** {1 In-Memory Pub/Sub} shared by Memory + FileSystem backends. *)
module Pubsub_mem : sig
  type t

  val create : unit -> t

  (** [publish t ~channel ~message] invokes every subscriber callback on
      [channel] with [message]. Returns the number of subscribers notified
      ([Ok 0] when no subscribers). Subscriber exceptions are logged;
      [Eio.Cancel.Cancelled] is re-raised. *)
  val publish : t -> channel:string -> message:string -> int result

  (** Append [callback] to the subscriber list for [channel]. *)
  val subscribe : t -> channel:string -> callback:(string -> unit) -> unit result
end
