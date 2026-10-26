(** A downloaded immutable evidence item, bound to the exact Task, submission
    and item index before any local file is written. *)
type t
val decode : task_id:string -> verification_id:string -> index:int ->
  Yojson.Safe.t -> (t, string) result
type progress = Not_started | Writing of string | Saved of string
(** [Writing path] means the destination is known but a complete write has not
    been confirmed. [Saved path] survives later viewer failure or cancellation. *)
val export :
  fs:Eio.Fs.dir_ty Eio.Path.t -> directory:string ->
  progress:progress Atomic.t -> admitted:(unit -> (unit, string) result) ->
  open_file:(string -> (unit, string) result) option -> t -> (string, string) result
(** Check workspace admission before the exclusive private write and again
    before opening. Publish the destination before any write can happen, so
    incomplete effects and cancellation retain their location. Never retry a
    write or opener on failure. Preserve the original basename inside a unique
    private directory. The file is a copy, never a producer path. *)
