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

(** This workspace's launcher, attaching to [config]'s port and keeping a
    session only with a Firefox on [config]'s profile. *)
val host_argv : launcher:string -> Browser_configuration.live_bidi -> string list

(** Where each one writes its output, under the workspace's
    [.masc/browser-lane]. *)
val firefox_log_path : base_path:string -> string
val host_log_path : base_path:string -> string

(** How long a started Firefox has to open its port. *)
(** Where a log is moved when the process that writes it is started again,
    replacing the run before. *)
val previous_log_path : string -> string

val firefox_ready_timeout_s : float

type firefox_failure =
  | Spawn_failed of string
  | Exited_before_listening of Unix.process_status option
      (** Firefox and every process it left in its group ended before the
          port answered. Firefox 157.0.1 exits with status 0 this way when
          another Firefox has the profile open, and says so only in the
          system's language (measured 2026-10-09); the message names that
          case for status 0 alone. [None]: the status was not known here. *)
  | Not_listening of float
      (** The port did not answer within these seconds; at the last check a
          connect to it was refused. *)
  | Port_unknown of { seconds : float; detail : string }
      (** The port did not answer within these seconds, and the last check
          could not tell whether anything listens: [detail] says why. *)

val firefox_failure_message : Browser_configuration.live_bidi -> firefox_failure -> string

(** Why the launcher is not run: the browser lane is installed (again)
    first, as {!Browser_bidi_host_status.launcher_standing} says. *)
type launcher_missing = Not_installed | Needs_reinstall

(** Whether a host is started for the Firefox on [port], from what the
    workspace's host report says. A workspace has one host at a time. *)
type host_step =
  | Host_running
      (** A host holds the lock and was given [port]: a second one would
          only be refused. It attaches to Firefox once, when it starts, so
          it does not attach to a Firefox started after it. *)
  | Host_on_another_port of string
      (** A host holds the lock and was given this address, whose port is
          not [port]. It stays on that Firefox until it is stopped. *)
  | Host_address_unknown
      (** A host holds the lock, and its record is missing (it has just
          taken the lock), cannot be read, or names no address with a port,
          so which Firefox it serves is not known. *)
  | Start_host of string  (** The installed launcher to run. *)
  | Launcher_not_ready of launcher_missing

val host_step : port:int -> Browser_bidi_host_status.report -> host_step

val host_on_another_port_message : port:int -> string -> string
val host_address_unknown_message : port:int -> string

val launcher_missing_message : launcher_missing -> string
