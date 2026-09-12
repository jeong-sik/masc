(** The terminal write at exit that has no result to read.

    [Unix.tcsetattr] raises on a descriptor that is no longer a terminal. At
    session start that is a hangup and the session ends either way (see
    [apply_raw_mode] in masc_tui.ml). At exit it is the ordinary case: the
    pane was closed or the line hung up, and the restore is the first
    [at_exit] callback to run. A raise there stops the chain -- the frame
    summary is never written, the tracking-off bytes never go out -- and a
    clean end becomes a trace. 22 TUI logs ended with exactly that between
    2026-08-25 and 2026-09-12.

    The kernel has two words for a descriptor that is no longer this
    process's terminal: [ENOTTY] (not a terminal) and [EIO] (the pty behind
    it hung up). Both mean there is nothing left to put the settings back on.
    Any other refusal still propagates: [EBADF] or [EINVAL] would be a caller
    bug, not a lost terminal, and hiding it would hide the bug.

    Apart from the session so the rule runs under a test with no terminal. *)

type outcome =
  | Restored
  | Terminal_gone of Unix.error
      (** [ENOTTY] or [EIO], kept so a log can say which one: the descriptor
          is no longer a terminal this process can set. *)

val put_back : set:(unit -> unit) -> outcome
(** Runs [set] -- the [Unix.tcsetattr] that puts the saved settings back.
    [Terminal_gone] when it raised [Unix.Unix_error] with [ENOTTY] or [EIO];
    every other exception propagates unchanged. *)
