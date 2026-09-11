(** Model availability is separate from owner/auth/store readiness. *)
type reason = Config_missing | Config_unreadable | Config_invalid | Exact_output_unavailable

type t = Not_initialized | Available | Setup_required of reason
val get : unit -> t
val set : t -> unit
val requires_setup : unit -> bool
val message : reason -> string
val to_json : unit -> Yojson.Safe.t

val note_runtime_loaded : unit -> unit
(** Loading config cannot activate services skipped by an owner boot. *)
val await_available : unit -> unit
(** Suspend a deferred startup fiber until explicit runtime activation. *)
