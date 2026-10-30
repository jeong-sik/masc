(** The fleet events of RFC-0477 as Server-Sent Events.

    - [GET] {!Fleet_stream.stream_path} — the first frame is the [Snapshot] the server
      holds, and every later frame is the next change or outage. A frame's [id]
      is the event's revision. A comment line is written every
      {!Server_mcp_transport_http_headers.sse_ping_interval_s} seconds without
      an event, so a reader can tell a quiet fleet from a dead connection.

    The route takes the same read authorization as the other operator reads
    ([with_public_read]), so a client that sends [expected_base_path] and
    [expected_masc_root] is refused before the first frame when the server
    holds another workspace.

    {!Server_fleet_stream_pump} decides what each connection is sent and when it
    is closed; this module only connects it to the socket. *)

val serve :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  subscribe:(on_event:(Fleet_stream.event -> unit) -> unit -> unit) ->
  ping_interval_s:float ->
  stalled_after_s:float ->
  max_queued_events:int ->
  Httpun.Reqd.t ->
  unit
(** Answers one request with the stream: the response head, then what
    {!Server_fleet_stream_pump.run} sends until the client is gone, falls
    behind or stops accepting frames, and the end of the response. Returns once the stream runs in [sw].
    Authorization is the caller's: {!add_routes} puts this behind it, with the
    server's hub and limits. Exposed so tests and the bench drive the code the
    server runs, over a real socket. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t ->
  Http_server_eio.Router.t
