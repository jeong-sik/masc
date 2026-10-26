(** A downloaded immutable evidence item, bound to the exact Task, submission
    and item index before any local file is written. *)
type t
val decode : task_id:string -> verification_id:string -> index:int ->
  Yojson.Safe.t -> (t, string) result
val save : fs:Eio.Fs.dir_ty Eio.Path.t -> directory:string -> t -> (string, string) result
(** Create a private uniquely named file without replacing an existing file.
    Returns the absolute local path; this is a copy, never a producer path. *)
