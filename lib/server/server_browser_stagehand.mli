(** One Stagehand session: a Chromium the server starts, one CDP connection
    to it, and the Stagehand runtime inside it (RFC-browser-lane-stagehand
    §3.4–§3.5). *)

type t

(** [open_ ~sw ~env ~masc_root ~config ~headless ~model ~log] starts
    Chromium with the configured extension, connects, attaches and calls
    [stagehand.init], whose result it returns with the session.

    The browser, its connection and the session's fibers live on [sw]:
    releasing [sw] stops the browser and removes its record. On [Error] the
    browser may already be running, so the caller releases [sw]. A profile the
    operator configured is kept; otherwise the server's own profile is emptied
    first. The profile directory is made owner-only. *)
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
