(** A downloaded immutable evidence item, bound to the exact Task, submission
    and item index before any local file is written. *)
type t
val decode : task_id:string -> verification_id:string -> index:int ->
  Yojson.Safe.t -> (t, string) result
type progress = Not_started | Writing of string | Saved of string
(** [Writing path] means the destination is known but a complete write has not
    been confirmed. [Saved path] survives later viewer failure or cancellation. *)
val export :
  fs:Eio.Fs.dir_ty Eio.Path.t -> registry_root:string -> directory:string ->
  progress:progress Atomic.t -> admitted:(unit -> (unit, string) result) ->
  open_file:(string -> (unit, string) result) option -> t -> (string, string) result
(** Check workspace admission before the exclusive private write and again
    before opening. [registry_root] is the caller-owned stable local MASC root,
    separate from a shared export directory, so repeated exports retain recovery
    without sharing a fixed registry across OS users. Concurrent exports sharing
    that root serialize owner reconciliation and publication through a stable
    process/filesystem lock. Lock admission is cancellable; admitted publication
    and lock release settle before cancellation resumes. Publish the destination
    before any write can happen, so incomplete effects and cancellation retain
    their location. Never retry a write or opener on failure. Preserve the original
    basename inside a unique private directory. The file is a copy, never a
    producer path. *)
