(** Server_scheduler_eintr — fatal report for a scheduler EINTR escape.

    [Eio_posix.Sched.clear_event_fd] in the locked eio 1.3 reads the wake-up
    pipe with a bare [Unix.read]: when a signal arrives first, the read fails
    with [EINTR] and the exception escapes [Eio_main.run], killing the server
    (masc#43225). The scheduler loop state is unrecoverable from the outside,
    so the only honest handling is to record why the process is exiting and
    what was known at that moment, then exit.

    Upstream fixed the read with a retry
    (ocaml-multicore/eio@9480f2a9a4e6, "eio_posix: retry the wake-up pipe on
    EINTR"), but no released eio contains it yet, so there is no version to
    bump to. This module renders the report; [bin/main_eio.ml] installs the
    narrow catch around the server scheduler and exits. *)

(** Shutdown signal masc handles itself. Mirrors the bin-local signal type;
    the report maps each case to its [SIGTERM]/[SIGINT] wire name. *)
type shutdown_signal =
  | Sigterm
  | Sigint

type context = {
  pending_shutdown : shutdown_signal option;
      (** First shutdown signal still awaiting consumption by the shutdown
          watcher. [None] means no [SIGTERM]/[SIGINT] was observed; a
          runtime-internal delivery (OCaml [SIGURG] domain signalling,
          [SIGCHLD] Eio reaps itself) leaves no record here. *)
  uptime_s : float;
      (** Seconds since process start ([Server_startup_state]
          [started_at]). *)
  mcp_sessions : int;
      (** Live MCP/SSE sessions ([Server_mcp_transport_http_conn]). *)
  ws_sessions : int option;
      (** Live websocket sessions ([Server_mcp_transport_ws.try_session_count]);
          [None] renders [busy]: another domain held the sessions mutex and
          the fatal path refused to wait. *)
  ocaml_version : string;
      (** [Sys.ocaml_version]. *)
  masc_version : string;
      (** [Runtime_build_version.current]. *)
  git_commit : string option;
      (** Binary commit stamp ([Build_identity.embedded_commit], a pure
          constant — the probing [Build_identity.current] is unsafe on a
          fatal path); [None] renders [unknown]. *)
  pid : int;
      (** [Unix.getpid ()]. *)
}
(** Process state sampled at the escape. Every field must be readable without
    the Eio scheduler: plain atomics, [Stdlib.Mutex] counters, and module-init
    constants only. *)

val shutdown_signal_name : shutdown_signal -> string
(** Wire name: [SIGTERM] or [SIGINT]. *)

val describe : context -> syscall:string -> backtrace:string -> string
(** [describe ctx ~syscall ~backtrace] renders the multi-line fatal report.
    [syscall] is the [Unix] function name from the escaped error ([read] for
    the wake-up pipe); [backtrace] is [Printexc.get_backtrace] at the catch.
    The report names the eio hazard, cites masc#43225 and the unreleased
    upstream fix, then prints the sampled signal and process state. *)
