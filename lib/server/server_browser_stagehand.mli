(** One Stagehand session: a Chromium the server starts, one CDP connection
    to it, and the Stagehand runtime inside it (RFC-browser-lane-stagehand
    §3.4–§3.5). *)

type t

(** Frontend HTTP wait for a Stagehand open, derived from the port, CDP, and
    attach waits plus one command window for process/transport overhead. *)
val open_http_timeout_s : float

(** [open_ ~sw ~env ~masc_root ~config ~headless ~model ~log] starts
    Chromium with the configured extension, connects, attaches and calls
    [stagehand.init], whose result it returns with the session.

    The browser, its connection and the session's fibers live on [sw]:
    releasing [sw] stops the browser and removes its record. On [Error] after
    launch, this function stops the Chromium process group and removes its
    record before returning, so the same switch may retry. A profile the
    operator configured is kept; otherwise the server's own profile is emptied
    first. A recorded Chromium from a previous server is stopped before that
    profile is prepared and before its owner record can be replaced. The
    profile directory is made owner-only. *)
val open_ :
  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> masc_root:string
  -> config:Browser_configuration.stagehand
  -> headless:bool
  -> model:Browser_stagehand_session.model
  -> log:(Browser_stagehand_session.event -> unit)
  -> (t * Yojson.Safe.t, string) result

val session : t -> Browser_stagehand_session.t
val pid : t -> int

(** Stops the Chromium a server that died before releasing left recorded for
    this workspace, if that pid still runs the recorded executable on the
    recorded profile, and removes the record. *)
val stop_left_behind : masc_root:string -> unit

val attach_error_message : Browser_stagehand_session.attach_error -> string

(** One server log line for each session event. *)
val log_event : Browser_stagehand_session.event -> unit

(** Stops a Chromium a previous server left, then, when [runtime.toml] has
    [\[browser.stagehand\]], installs the Stagehand lane's backend on [sw]
    (RFC-browser-lane-stagehand §3.4). No browser starts until a
    [Session_open]. *)
val start : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit
