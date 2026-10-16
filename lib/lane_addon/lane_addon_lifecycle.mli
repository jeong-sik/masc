(** Typed facts about the container engine that holds an Add-on's worker.
    Pure: no I/O. *)

(** The engine a container was created on. Docker reports an engine ID; the
    Apple [container] runtime reports the application data root its API server
    stores containers under. Two engines are the same engine only when these
    are equal. *)
type engine = Docker_engine of string | Apple_app_root of string

(** Why the engine cannot say who it is. [Unreachable] is decided by the exit
    status of the identity command alone; [Identity_unreadable] means the
    command succeeded and printed something that is not an identity. Neither
    carries a meaning parsed out of an error message. *)
type engine_fault =
  | Unreachable of string
  | Identity_unreadable of string

val engine_equal : engine -> engine -> bool
val engine_to_string : engine -> string
val engine_to_json : engine -> Yojson.Safe.t
val engine_of_json : Yojson.Safe.t -> (engine, string) result
