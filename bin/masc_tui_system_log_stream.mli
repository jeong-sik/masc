(** The frames of the server log stream ([GET /api/v1/dashboard/logs/stream])
    and how one lands on the page the System logs view draws. *)

type frame =
  { reset : bool
      (** The page is replaced: the first frame of a connection, entries the
          client never got were evicted, or more matched than a page holds. *)
  ; snapshot : Masc.Tui_decode.system_log_snapshot
      (** The entries, newest first, as [GET /api/v1/dashboard/logs] answers. *)
  }

type reader

val create : unit -> reader

val feed : reader -> string -> (frame, string) result list
(** The frames [chunk] completes, in order. An SSE comment (the keepalive) is
    no frame. A frame whose data does not decode is an [Error] naming why. *)

val apply :
  limit:int ->
  frame ->
  Masc.Tui_decode.system_log_snapshot option ->
  Masc.Tui_decode.system_log_snapshot
(** A [reset] frame, or one with no page under it, is the page. Otherwise its
    entries go on top of the page's, which keeps the newest [limit]. *)

val cursor : Masc.Tui_decode.system_log_snapshot option -> int option
(** The newest sequence the page holds, which a reconnect resumes after. *)
