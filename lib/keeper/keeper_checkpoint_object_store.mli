(** The message objects and turn bundles a checkpoint head names
    (RFC-0476 §3.2), one file each under [<session_dir>/objects/]. *)

val dirname : string

val path : session_dir:string -> Agent_core.Checkpoint_objects.digest -> string

type write_error =
  { digest : Agent_core.Checkpoint_objects.digest
  ; error : Keeper_fs.durable_write_error
  }

val write_error_to_string : write_error -> string

(** Writes each object durably, in order, unless a file whose bytes have its
    digest is already there. Answers the bytes written. A head may name the
    objects only after this returns [Ok]. *)
val write
  :  session_dir:string
  -> (Agent_core.Checkpoint_objects.digest * string) list
  -> (int, write_error) result

(** The object's bytes, [None] when there is no such file, or why it could
    not be read. The digest is not checked here; [Checkpoint_objects.load]
    checks it. *)
val read
  :  session_dir:string
  -> Agent_core.Checkpoint_objects.digest
  -> (string option, string) result
