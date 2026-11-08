(** One MCP [subscriptions/listen] response over HTTP/1.1 or HTTP/2 (MCP
    2026-07-28, RFC-0493 §3.2).

    The response body is the subscription's notification stream: the
    reconnect [retry:] frame, the acknowledgement, then each notification
    {!Mcp_subscriptions} delivers to it. A publisher only puts the frame in
    this stream's queue and returns, so a client that reads slowly holds up
    neither the publisher nor the other subscriptions. {!Server_sse_pump} on
    the caller's fiber writes the frames and a keepalive comment after each
    quiet interval. *)

val serve :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ping_interval_s:float ->
  stalled_after_s:float ->
  max_queued_events:int ->
  subscription_id:Yojson.Safe.t ->
  filter:Mcp_transport_protocol.subscription_filter ->
  headers:Httpun.Headers.t ->
  Http_reqd.t ->
  unit
(** [serve ... reqd] answers [reqd] with the stream and returns when it ends:
    the client is gone (an HTTP/2 peer that resets the stream ends it at
    once), accepted no frame within [stalled_after_s], or let
    [max_queued_events] notifications wait; or [reqd]'s fiber is cancelled.
    The subscription is registered only while the stream runs and is removed
    before [serve] returns; the response is closed by then. No notification
    reaches the stream before its acknowledgement. [filter] is the honoured
    one the acknowledgement reports. *)
