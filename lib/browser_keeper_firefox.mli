(** The Keeper Firefox and its BiDi host, as the MASC server starts them for
    a workspace whose [runtime.toml] has [\[browser.live.bidi\]]
    (RFC-browser-keeper-firefox §3.2). What to run and what to start; the
    server runs it. *)

(** [ws://127.0.0.1:PORT/session]: the address Firefox opens for
    [--remote-debugging-port PORT] and the one the host is given. *)
val bidi_url : port:int -> string

(** Firefox on the configured profile, apart from any Firefox already
    running ([--no-remote]), with its BiDi address open. *)
val firefox_argv : Browser_configuration.live_bidi -> string list

(** This workspace's launcher, attaching to the configured port. *)
val host_argv : launcher:string -> port:int -> string list

(** Where each one writes its output, under the workspace's
    [.masc/browser-lane]. *)
val firefox_log_path : base_path:string -> string
val host_log_path : base_path:string -> string

(** How long a started Firefox has to open its port. *)
val firefox_ready_timeout_s : float

type firefox_failure =
  | Spawn_failed of string
  | Exited_before_listening of Unix.process_status option
      (** Firefox and every process it left in its group ended before the
          port answered. Firefox 157.0.1 exits with status 0 this way when
          another Firefox has the profile open, and says so only in the
          system's language (measured 2026-10-09); the message names that
          case for status 0 alone. [None]: the status was not known here. *)
  | Not_listening of float  (** The port did not answer within these seconds. *)

val firefox_failure_message : Browser_configuration.live_bidi -> firefox_failure -> string

(** Why the launcher is not run: the browser lane is installed (again)
    first, as {!Browser_bidi_host_status.launcher_standing} says. *)
type launcher_missing = Not_installed | Needs_reinstall

(** Whether a host is started, from what the workspace's host report says. *)
type host_step =
  | Host_running
      (** A host holds the lock: a second one would only be refused. *)
  | Start_host of string  (** The installed launcher to run. *)
  | Launcher_not_ready of launcher_missing

val host_step : Browser_bidi_host_status.report -> host_step

val launcher_missing_message : launcher_missing -> string
