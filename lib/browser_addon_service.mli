(** The private concurrent transport of one browser worker. This is not an HTTP
    route or a Keeper tool. Each connection carries one JSON line and one reply;
    callers must never retry issued work after losing the connection. *)
val serve :
  net:_ Eio.Net.t -> owner:Browser_addon_owner.t ->
  socket_path:string -> max_message_bytes:int -> unit
(** [socket_path] is host-selected, absolute, canonical, absent, and inside a
    directory owned by the worker's UID with mode 0700. Existing paths are never
    unlinked or reused. [max_message_bytes] is the installation's existing native
    reply bound, applied also to this private channel. No global execution lock
    is held during request handling. The service owns a nested switch for its listener and every accepted flow;
    cancellation joins their cleanup. *)
val mcp : Browser_addon_owner.t -> Mcp_protocol_eio.Server.t
(** Snapshot observation, the browser command tool and, when selected, the
    two private model request/result ports. Execution requires the
    host-owned caller-context control port; model arguments supply no identity.
    Poll/results remain on the independent concurrent private transport. *)
