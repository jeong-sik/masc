(** On-demand background server startup for the TUI.

    [start] launches the sibling [masc start] in a detached process group.
    The server keeps running after the TUI exits. The startup handle is used
    to observe and reap the child, not to tie its lifetime to the UI.
    [stop] is an explicit operation for the owner of that handle. *)

(** {1 When a server is due}

    A refresh completes with a reading of the port. Nothing answering is the
    case a first install produces, and it is the case the TUI reacts to. *)

type contact =
  | Nothing_answered  (** Every request this refresh made failed. *)
  | Server_reached  (** At least one answered. *)
  | Undecided
      (** Connecting, booting or reconnecting: no reading yet. *)

val start_due : contact:contact -> already_attempted:bool -> bool
(** Whether to start a server now. True only when nothing answered and this
    session has not already spawned one: a refresh fails for reasons a new
    server would not fix, and a second [masc] on the same port would only
    fail to bind. The caller derives [contact] from its connection status, so
    this rule tests without a TTY or a render state. *)

type discovery =
  | Sibling of string
      (** The [masc] file next to the running TUI binary (how install.sh
          lays the two out). *)
  | On_path of string  (** [masc] resolved from [$PATH]. *)
  | Not_found of { manual_command : string }
      (** The binary could not be located; carries the exact manual start
          command to show the operator instead of guessing a path. *)

val discover_server_binary :
  tui_exe:string ->
  file_exists:(string -> bool) ->
  path_lookup:(string -> string option) ->
  base_path:string ->
  host:string ->
  port:int ->
  discovery
(** Resolve the server binary: the [masc] file beside [tui_exe] first, then
    [path_lookup "masc"], else [Not_found] carrying the manual command built
    from [base_path]/[host]/[port]. Callers inject [file_exists] and
    [path_lookup] so the resolution order is testable without a filesystem. *)

val server_argv :
  masc_bin:string -> base_path:string -> host:string -> port:int -> string list
(** The exact argv for the child server. No shell interpolation. *)

type 'exit health_outcome =
  | Ready  (** [/health] answered ok within the budget. *)
  | Server_exited of 'exit
      (** the child died before answering; carries what [child_exit] said. *)
  | Timed_out of int  (** attempts exhausted; carries the attempts made. *)

val wait_healthy :
  health_ok:(unit -> bool) ->
  child_exit:(unit -> 'exit option) ->
  attempts:int ->
  sleep:(unit -> unit) ->
  'exit health_outcome
(** Poll [health_ok] up to [attempts] times, sleeping between tries via
    [sleep]. Returns [Ready] as soon as [health_ok] holds, [Server_exited]
    the moment [child_exit] answers, and [Timed_out] once the attempts
    run out. Pure over the injected effects, so tests drive it with fakes.
    [attempts <= 0] yields [Timed_out 0] without calling [sleep]. *)

type owned_server
(** A background server started by this process. *)

val owned_pgid : owned_server -> int

(** {1 What a server said}

    A server that refuses to start says why on stderr and exits, and part
    of that happens before its own log under [.masc/logs] exists. The child's
    stdout and stderr therefore go to a file the starter can read back. *)

type startup_output =
  | Written_to of string
      (** The child's stdout and stderr go to this file, emptied at start. *)
  | Not_kept of { path : string; reason : string }
      (** [path] could not be opened for [reason]; the child's output went
          to [/dev/null]. The start went ahead anyway. *)

val startup_output_file : port:int -> string
(** [.masc/logs/masc-server-<port>.log], relative to the base path: one file
    per port, so a start on another port does not empty it. *)

val startup_output_path : base_path:string -> port:int -> string
(** {!startup_output_file} under [base_path]. *)

val startup_output : owned_server -> startup_output

val describe_output : startup_output -> string
(** ["full output: <path>"], or why there is none -- the reason ahead of the
    path, so a line cut at its width keeps it. *)

type exit_observation =
  | Still_running
  | Exited_with of Unix.process_status
  | Reaped_elsewhere
      (** Something else in this process collected the status first. *)

val observe_exit : owned_server -> exit_observation
(** Non-blocking waitpid that reaps the child on exit. The first answer is
    kept: later calls return the same observation. *)

val is_running : owned_server -> bool
(** [observe_exit] is [Still_running]. *)

type last_line =
  | Said of string  (** The last non-blank line the child wrote. *)
  | Said_nothing
  | Unreadable of string  (** The output file could not be read. *)

val last_line_of_text : string -> last_line
(** The last non-blank line of [text], trimmed. Pure. *)

val describe_last_line : last_line -> string
(** The line itself, or what stood in for it. *)

type exit_report = {
  status : string;  (** ["exit 1"], a signal, or that the status is gone. *)
  last_line : last_line;
  output : startup_output;
}

val exit_report : owned_server -> exit_report option
(** How the child ended and the last thing it wrote, read from the tail of
    its output file. [None] while it is still running. *)

val start :
  masc_bin:string ->
  base_path:string ->
  host:string ->
  port:int ->
  env:string array ->
  (owned_server, string) result
(** Spawn [masc_bin] as a detached child in its own process group, stdout
    and stderr to {!startup_output_path} (emptied first). No pipe is kept,
    so the server is never blocked or broken by this process exiting.
    Returns the owned handle, or a message on spawn failure. *)

val stop : owned_server -> grace_sec:float -> unit
(** Tree-kill only this owned server: SIGTERM to the process group, then
    SIGKILL after [grace_sec] if anything survives. Idempotent. *)
