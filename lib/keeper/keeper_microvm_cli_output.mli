(** Complete stdout from actual microVM CLI execution. Bounded process previews
    never establish facts or absence. Raw stdout is secret-bearing: do not log it. *)

type unavailable_output =
  | Capture_directory_unavailable
  | Capture_incomplete
  | Capture_failed
  | Capture_unreadable
  | Capture_permissions_invalid
  | Capture_length_mismatch
  | Capture_cleanup_failed

type error =
  { reason : unavailable_output
  ; status : Unix.process_status option
      (** [Some] after the runner returned a status, including its synthesized
          setup-failure status. It proves neither child creation nor complete
          stdout; it is diagnostic state only. *)
  }

val read : timeout_sec:float -> argv:string list -> (Unix.process_status * string, error) result
(** Run the canonical streaming process runner and retain stdout only after
    authoritative pipe EOF, owned 0600 file validation and exact byte length.
    A nonzero child can still have complete stdout. Unix fallback cannot.
    Private 0700 capture directories are removed on every exit, with cleanup
    protected from cancellation. Cancellation and fatal exceptions propagate. *)

val unavailable_message : unavailable_output -> string
val error_message : error -> string
(** Neither formatter includes stdout, stderr, argv, capture paths or raw errors. *)
