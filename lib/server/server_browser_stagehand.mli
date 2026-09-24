(** One Stagehand session: a Chromium the server starts, one CDP connection
    to it, and the Stagehand runtime inside it (RFC-browser-lane-stagehand
    §3.4–§3.5). *)

type t

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
    profile directory is made owner-only. An unreadable or malformed prior
    owner record, or a browser group that cannot be confirmed stopped,
    returns [Error] before resetting the profile or spawning a replacement. *)
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

(** Startup cleanup for a Chromium left by a crashed server. Refuses to
    erase the owner record when it cannot identify or stop that browser;
    [open_] will then return [Error] before replacing its profile. *)
val stop_left_behind : masc_root:string -> unit

val attach_error_message : Browser_stagehand_session.attach_error -> string
