(** [GET /api/v1/dashboard/logs/stream]: the server log ring as it grows
    (RFC-0480 §3.1, typed stream).

    The query is the one [/api/v1/dashboard/logs] takes
    ({!Server_logs_query}). Each SSE frame is that route's answer with a
    [reset] field: [true] when the client should replace its list (no
    [since_seq], entries it never got were evicted, or more matched than
    [limit]), [false] when the entries, newest first, are the ones newer than
    the last frame. The first frame always goes out. Later frames go out when
    a matching entry was pushed; a quiet ring sends an SSE comment every
    keepalive interval. A client that takes no frame for three intervals is
    closed. *)

val stream_path : string

type frame =
  { reset : bool
  ; entries : Log.Ring.entry list
  ; ring_bounds : Log.Ring.bounds
  ; after : int  (** The cursor the next frame reads after. *)
  }

val next_frame : Server_logs_query.t -> after:int option -> frame
(** What the stream sends next for a client whose cursor is [after]. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
