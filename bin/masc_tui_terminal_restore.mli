(** Restore terminal settings while preserving unexpected failures.
    [ENOTTY] and [EIO] mean the terminal cannot receive its saved settings.
    Other exceptions, including [EBADF] and [EINVAL], propagate unchanged.
    The TUI quietly skips final output after a known terminal loss; this
    module does not log the error. *)

type outcome =
  | Restored
  | Terminal_gone of Unix.error
      (** The [ENOTTY] or [EIO] observed during restoration. *)

val put_back : set:(unit -> unit) -> outcome
(** Runs [set] -- the [Unix.tcsetattr] that puts the saved settings back.
    [Terminal_gone] when it raised [Unix.Unix_error] with [ENOTTY] or [EIO];
    every other exception propagates unchanged. *)

val finish_after_restore : restore:(unit -> outcome) -> finish:(unit -> unit) -> unit
(** Run final terminal output only when restoration succeeded. Exceptions from
    [finish] propagate: restoring stdin does not prove stdout is writable. *)
