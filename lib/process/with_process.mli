(** Exception-safe subprocess stdout capture — SSOT for #8538. *)

(** [with_process_in cmd f] opens [cmd] via [Unix.open_process_in], passes
    the stdout channel to [f], and guarantees [Unix.close_process_in] runs
    on every exit path.  Returns [f]'s result paired with the subprocess
    exit status.

    - If [f] raises, the channel is closed (best-effort) and the
      exception is re-raised.
    - [Eio.Cancel.Cancelled] is re-raised after close so Eio's structured
      cancellation is preserved.
    - Close errors ([Unix.Unix_error], [Sys_error],
      [Failure "equal: abstract value"] per ocaml/ocaml#2447) are
      swallowed on the error path; the primary contract is fd reclaim. *)
val with_process_in : string -> (in_channel -> 'a) -> 'a * Unix.process_status

(** As [with_process_in] but uses [Unix.open_process_args_in] for exact
    argv control. *)
val with_process_args_in
  :  string
  -> string array
  -> (in_channel -> 'a)
  -> 'a * Unix.process_status

(** Read [ic] to EOF into a fresh buffer using [Buffer.add_channel].
    Default chunk size 4096.  Raises anything other than [End_of_file]
    (e.g. [Sys_error], [Unix.Unix_error]) to the caller — combine with
    [with_process_in] to close on such faults. *)
val drain_to_buffer : ?chunk:int -> in_channel -> Buffer.t

(** Read [ic] to EOF with [input_line], returning lines in source order. *)
val drain_lines : in_channel -> string list
