(** On-demand background server startup shared by CLI setup, TUI clients and
    a [masc start] run from a terminal.

    [start] launches the sibling [masc start] in a detached session.
    The server keeps running after the caller exits. The startup handle is used
    to observe and reap the child, not to tie its lifetime to the caller.
    [stop] is an explicit operation for the owner of that handle. *)

(** {1 When a server is due}

    A refresh completes with a reading of the port. Nothing answering is the
    case a first install produces, and it is the case an interactive client
    reacts to. *)

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
      (** The [masc] file next to the running client binary (how install.sh
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
  masc_bin:string ->
  flags:string list ->
  base_path:string ->
  host:string ->
  port:int ->
  string list
(** The exact argv for the child server: [masc_bin start], then [flags] as
    given, then the base path, host and port. No shell interpolation. *)

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
  flags:string list ->
  base_path:string ->
  host:string ->
  port:int ->
  env:string array ->
  (owned_server, string) result
(** Spawn {!server_argv} as a detached child in a session of its own, so it
    has no controlling terminal, with stdout and stderr to
    {!startup_output_path} (emptied first) and the base path as its working
    directory. No pipe is kept, so the server is never blocked or broken by
    this process exiting. Returns the owned handle, or a message on spawn
    failure. *)

val stop : owned_server -> grace_sec:float -> unit
(** Tree-kill only this owned server: SIGTERM to the process group, then
    SIGKILL after [grace_sec] if anything survives. Idempotent. *)

(** {1 A server started from a terminal}

    A server that holds a controlling terminal stops whole once any process
    in its group reads that terminal from the background: the kernel stops
    the group with SIGTTIN or SIGTTOU (#38700). A [masc start] that has a
    terminal therefore starts the server with {!start}, which leaves it no
    terminal, and stays on the terminal as its supervisor (RFC-0470 §4.2). *)

type terminal =
  | Controlling_terminal  (** [/dev/tty] opened. *)
  | No_controlling_terminal  (** [/dev/tty] did not open. *)

val controlling_terminal : unit -> terminal
(** Opens [/dev/tty] close-on-exec and closes it again. Nothing is read or
    written, so asking does not stop a background job. Any failure to open
    it reads as [No_controlling_terminal], as RFC-0470 §4.2 says. *)

type ended =
  | Ended of Unix.process_status
  | Ended_unobserved
      (** Something else in this process collected the status first. *)

val supervise :
  masc_bin:string ->
  flags:string list ->
  base_path:string ->
  host:string ->
  port:int ->
  env:string array ->
  into:Unix.file_descr ->
  notices:Unix.file_descr ->
  (ended, string) result
(** Starts the server with {!start} and stays until it ends.

    - SIGINT, SIGTERM, SIGHUP and SIGQUIT sent to this process become one
      SIGTERM to the server's process group each. A signal this process
      inherited as ignored stays ignored, so [nohup] keeps its meaning. One
      that arrives before the server's group exists is sent once it does.
      SIGTSTP, SIGTTIN and SIGTTOU keep their default: they stop this
      process only, and the server goes on writing to its file.
    - The startup output file is read from its start and copied to [into].
      If [into] refuses a write, copying stops and the wait goes on. If the
      file was not kept or does not open, a line on [notices] says so.
    - When the server ends, what it wrote last is copied, and a line on
      [notices] names a signal that ended it.

    [Error] is {!start}'s spawn failure. The signal handlers are installed
    for the whole process and are not removed: call it from a process that
    exits once it returns. *)

val exit_code : ended -> int
(** The server's exit status. A server ended by signal [n] gives [128 + n],
    as a shell reports it. A status collected elsewhere gives 1. *)

(** {1 How a start ended, for an event loop}

    A background start waiter records its outcome in {!settled_starts} and
    invokes the caller's [on_settled] wake callback once the outcome is stored. *)

type settled_start = {
  server : owned_server;
  host : string;
  port : int;  (** Where this start was for. *)
  outcome : exit_report health_outcome;
}

type settled_starts

val create_settled_starts : unit -> settled_starts

val await_start :
  settled_starts ->
  owned_server ->
  host:string ->
  port:int ->
  health_ok:(unit -> bool) ->
  attempts:int ->
  sleep:(unit -> unit) ->
  on_settled:(unit -> unit) ->
  unit
(** Poll {!wait_healthy} against this server's own exit, store the outcome in
    [settled_starts], and call [on_settled ()]. *)

val take_settled : settled_starts -> settled_start list
(** The starts settled since the last call, oldest first, and forget them. *)
