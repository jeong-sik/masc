(** Open-file-description [flock(2)] liveness probes for staging files. *)

val try_lock_exclusive_fd : Unix.file_descr -> bool
(** Acquire a non-blocking exclusive [flock] on [fd]. *)

type probe =
  | Held
      (** Another open-file description holds the lock, so the writer that made
          the stage file is alive. *)
  | Not_held
      (** The probe took the lock and released it, so no writer holds it. This
          is the only answer that says the stage file is dead. *)
  | Undeterminable of undeterminable_reason
      (** The probe learned nothing about the holder. A reclaimer that deletes
          on {!Not_held} must not delete on this: on a filesystem without
          [flock(2)], an unreadable path or a non-regular file it would delete
          a live writer's stage file. *)

and undeterminable_reason =
  | Open_failed
  | Not_regular_file
  | Flock_refused

val probe_path : string -> probe
(** Classify [path]. [Not_held] and [Held] are conclusions; every other outcome
    is [Undeterminable], so a caller cannot mistake "could not probe" for
    "dead". Probing never releases an existing holder's lock. *)

val undeterminable_reason_label : undeterminable_reason -> string
