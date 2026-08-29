(** Opt-in, on-demand start of a masc server from inside the TUI
    (RFC tui-server-lifecycle).

    The discovery, argv and health-wait logic is pure over its injected
    effects, so it unit-tests without a TTY, a real server, or an Eio
    context. [start]/[stop] are the thin effectful shell over
    {!Process_eio_detached}: they spawn the sibling [masc] binary as a
    detached child in its own process group and tree-kill only that child.

    The TUI must never stop a server it merely connected to. Only an
    {!owned_server} — a handle for a server this TUI started — is stoppable,
    so "kill what I did not start" is unrepresentable rather than guarded. *)

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

type health_outcome =
  | Ready  (** [/health] answered ok within the budget. *)
  | Server_exited  (** the child died before answering. *)
  | Timed_out of int  (** attempts exhausted; carries the attempts made. *)

val wait_healthy :
  health_ok:(unit -> bool) ->
  child_alive:(unit -> bool) ->
  attempts:int ->
  sleep:(unit -> unit) ->
  health_outcome
(** Poll [health_ok] up to [attempts] times, sleeping between tries via
    [sleep]. Returns [Ready] as soon as [health_ok] holds, [Server_exited]
    the moment [child_alive] turns false, and [Timed_out] once the attempts
    run out. Pure over the injected effects, so tests drive it with fakes.
    [attempts <= 0] yields [Timed_out 0] without calling [sleep]. *)

type owned_server
(** A server this TUI started and therefore owns. *)

val owned_pgid : owned_server -> int

val is_running : owned_server -> bool
(** True while at least one member of the owned server's process group is
    still alive. Suitable as the [child_alive] argument to {!wait_healthy}. *)

val start :
  masc_bin:string ->
  base_path:string ->
  host:string ->
  port:int ->
  env:string array ->
  (owned_server, string) result
(** Spawn [masc_bin] as a detached child in its own process group via
    {!Process_eio_detached.spawn_detached_devnull}; the server writes its
    own logs under [base_path]/.masc/logs so no stdout pipe is retained.
    Returns the owned handle, or a message on spawn failure. *)

val stop : owned_server -> grace_sec:float -> unit
(** Tree-kill only this owned server: SIGTERM to the process group, then
    SIGKILL after [grace_sec] if anything survives. Idempotent. *)
