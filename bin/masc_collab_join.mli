(** Terminal guest for collab rooms: `masc collab join`.

    A line-oriented guest: the snapshot and live entries render as text
    lines, control guests type prompts (plus [/abort], [/fetch],
    [/quit]), view guests read. Pure rendering ([render_snapshot_row],
    [render_live_event]) stays testable without a socket. *)

val render_snapshot_row : Yojson.Safe.t -> string list
(** One journal row as guest lines. Undecodable rows render as a
    placeholder line, never a crash: the snapshot must survive a
    newer host's event. *)

val render_live_event : Yojson.Safe.t -> string list
(** One live entry's event JSON as guest lines. Same placeholder rule. *)

val run
  :  env:Eio_unix.Stdenv.base
  -> link:string
  -> relay:string option
  -> label:string option
  -> int
(** [run ~env ~link ~relay ~label] joins the room and drives the guest
    until quit or close. Returns the process exit code: 0 on a local
    quit or a host goodbye, 1 on any failure or error close. *)
