(** Live [subscriptions/listen] streams (MCP 2026-07-28).

    One entry per open stream, keyed by the JSON-RPC id of the request that
    opened it. That revision removed sessions, so the request is the only
    identity a subscription has.

    Every delivery is filtered before it is sent: the specification says a
    server {b MUST NOT} send a notification type the client did not request,
    so the filter is consulted here rather than at each emitter. *)

type token
(** Handle for one open stream. The transport keeps it and returns it on
    close. *)

val register :
  subscription_id:Yojson.Safe.t ->
  filter:Mcp_transport_protocol.subscription_filter ->
  send:(Yojson.Safe.t -> bool) ->
  token
(** [send] returns whether the message reached the peer. A [false] retires the
    entry, so a closed stream is not retried on every later notification.

    The closure is supplied by the transport instead of this module reaching
    for a writer: masc_server depends on masc, and the reverse edge would
    point the notification vocabulary at the transport. *)

val unregister : token -> unit
(** Idempotent: the transport unregisters on close and a failed send retires
    the same entry, and neither needs to know about the other. *)

val count : unit -> int
(** Open streams. For operator surfaces and tests. *)

val notify_tools_list_changed : Yojson.Safe.t -> unit
val notify_prompts_list_changed : Yojson.Safe.t -> unit
val notify_resources_list_changed : Yojson.Safe.t -> unit

val subscribed_resource_uris : unit -> string list
(** Every URI any open stream named, deduplicated. The caller decides which of
    them a change touched: this module does not know which resources are
    dynamic or how a URI maps to a resource id. *)

val notify_resource_updated : uri:string -> Yojson.Safe.t -> unit
(** Reaches only streams that named [uri] in [resourceSubscriptions]. *)

val honoured_filter :
  Mcp_transport_protocol.subscription_filter ->
  Mcp_transport_protocol.subscription_filter
(** The subset this server can serve. [promptsListChanged] and
    [resourcesListChanged] come back off because masc emits neither. *)

val acknowledgement :
  subscription_id:Yojson.Safe.t ->
  Mcp_transport_protocol.subscription_filter ->
  Yojson.Safe.t
(** The first message on a subscription, which no notification may precede —
    so send it before {!register}. *)

val graceful_closure : subscription_id:Yojson.Safe.t -> Yojson.Safe.t
(** The JSON-RPC response to the long-lived request, marking a clean end. A
    transport that drops without it is an unexpected disconnect.

    Built here rather than at each transport: HTTP/1 and h2c wrote their own
    header-mismatch body and drifted until that moved to one place. *)

val reset_for_test : unit -> unit
