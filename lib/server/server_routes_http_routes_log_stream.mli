(** [GET /api/v1/dashboard/logs/stream]: the server log ring as it grows
    (RFC-0480 §3.1, typed stream).

    The query is the one [/api/v1/dashboard/logs] takes
    ({!Server_logs_query}). Each SSE frame is that route's answer with a
    [reset] field: [true] when the client should replace its list (no
    [since_seq], entries it never got were evicted, the cursor belongs to a
    newer ring instance, or more matched than [limit]), [false] when the
    entries, newest first, are the ones newer than the last frame. A client
    without [since_seq] gets its first frame at once. One with a cursor gets
    it at once when a matching entry is newer than the cursor, the ring
    evicted entries it never got, or the cursor belongs to a newer ring
    instance, and otherwise when a matching entry is pushed. Later frames go
    out when a matching entry was pushed. A stream that sent nothing for a
    keepalive interval sends an SSE comment, whether the ring was quiet or got
    only entries the query leaves out. A frame the client does not take within
    {!Server_mcp_transport_http_headers.sse_stalled_after_s} ends the stream
    ({!Server_sse_response.send}): HTTP/1.1 closes the response, HTTP/2
    resets the stream. The response advertises the shared observer idle
    deadline so a client also retires a body whose keepalive bytes silently
    stop arriving. Requests must name their original
    [Sse_wire.instance_header]; the response attests that instance and
    replacement of its workspace closes the stream. *)

val stream_path : string

type frame =
  { reset : bool
  ; entries : Log.Ring.entry list
  ; ring_bounds : Log.Ring.bounds
  ; after : int  (** The cursor the next frame reads after. *)
  }

val next_frame : Server_logs_query.t -> after:int option -> frame
(** What the stream sends next for a client whose cursor is [after].
    [Some (-1)] is the current cursor of an empty ring. A cursor at or
    beyond the next sequence resets, including after a server restart.
    [frame.ring_bounds.total = frame.after + 1] binds the response to its read frontier. *)

val serve :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  instance:string ->
  current:(unit -> bool) ->
  replaced:(unit -> unit) ->
  encode:(frame -> string) ->
  query:Server_logs_query.t ->
  Http_reqd.t ->
  unit
(** [serve ~sw ~clock ~instance ~current ~replaced ~encode ~query reqd]
    starts the response, which attests [instance] in
    [Sse_wire.instance_header], and, in [sw], the fiber that sends [query]'s
    frames, each as the SSE bytes [encode] gives for it. It returns once that
    fiber waits. The fiber ends with the response
    ({!Server_sse_response.serve}): when a frame or a keepalive is not taken,
    and on HTTP/2 as soon as the stream ends under it. It also ends when
    [replaced ()] returns, and it sends nothing once [current ()] is [false].
    {!add_routes} takes the three from the stream's
    {!Server_observer_scope.stream_owner} and encodes a frame as the [/logs]
    answer with [reset]. Exposed so tests drive the loop the server runs. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
