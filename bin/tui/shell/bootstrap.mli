(** Process startup: CLI parsing, interactive TTY checks, stderr redirection,
    and Eio/domain initialization for the TUI executable. *)

type cli_args = {
  base_path : string;
  workspace : string;
  port : int;
  reasoning_visibility : Masc_tui_types.reasoning_visibility;
  tool_visibility : Masc_tui_types.tool_visibility;
}

val parse_args : unit -> cli_args
(** Parse CLI flags and resolve the workspace root and HTTP port. Informational
    flags ([--version], [--build-commit], [--help]) exit directly. *)

val require_interactive_terminal : unit -> unit
(** Exit with status 2 when stdin/stdout are not interactive TTYs or
    [TERM=dumb]. *)

val redirect_stderr_off_terminal : base_path:string -> unit
(** Redirect fd 2 to a per-PID log file under [<base-path>/.masc/logs] so
    out-of-band logs cannot corrupt drawn terminal frames. *)

val run_with_eio_context : (unit -> unit) -> unit
(** Initialize the UI minor heap, Eio runtime, worker pool, HTTP I/O domain,
    and process runner, then execute the TUI body until {!Exit_journal.Break}. *)
