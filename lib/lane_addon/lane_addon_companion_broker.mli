(** Independent, memory-only transport for trusted credential companions.
    A grant belongs to one admitted exported invocation. Its descriptor travels
    only in the private host context, never model arguments/results or storage. *)
type error = Unavailable | Not_started | Outcome_unknown
type shutdown_error = Listener_close_unconfirmed
type selection = { browser_instance_id : string; tab_id : int }
type completion = Released | Abandoned
type binding = {
  execute : Browser_extension_protocol.command ->
    (Yojson.Safe.t, Browser_extension_protocol.error) result;
  finish : completion -> unit;
}
(** [execute] must freshly check the original provider/caller/Browser authority
    on every command. It may use only the originally bound Browser connection.
    Its cancellation must fence/retire the original uncertain Browser call
    before returning; this socket broker does not own that browser's serializer.
    [finish] is an owner-domain nonblocking notification: no I/O, raise or yield.
    Abandonment must fence an in-flight uncertain effect before admitting reads.
    It must never retire a replacement Browser. A late successful [bind] is
    retained before its cancelled result can be discarded; [finish] runs once
    after that original factory and its cleanup have joined. *)
type t
type grant
val create : sw:Eio.Switch.t -> directory:string -> max_message_bytes:int -> (t, error) result
(** The caller supplies an existing canonical, owned 0700 directory outside
    retained Lane data and agent work disks. The owner switch joins connections;
    [revoke] ends admission and signals cancellation. [await_stopped] observes
    the listener and its connection scopes after cancellation/cleanup have joined.
    There are no model-request ports, deadlines, payload logs or automatic retry.
    A credentialless first frame may withdraw its exact invocation nonce.
    Its acknowledgement proves admission removed, not Browser settlement.
    Repeating withdrawal of an absent nonce cannot bind or dispatch input. *)
val issue : t -> publish:(Yojson.Safe.t -> (unit, error) result) option ->
  bind:(selection -> (binding, error) result) -> (grant, error) result
(** [bind] captures one exact owner after checking the original host principal
    and declarations. Binding itself must send no Browser input. The first
    authenticated connection consumes the grant before any yielding work. *)
val descriptor : grant -> Yojson.Safe.t
val accept : grant -> (unit,error) result
(** Mark a successfully validated exported invocation as accepted. An original
    unclaimed grant can bind after its public reply, until this provider ends.
    This never restores a cancelled, consumed or revoked grant. A rejected
    invocation returns [Not_started]; an ended provider returns [Unavailable],
    including after a prior acceptance. Callers must refuse a late successful
    worker reply when this original admission cannot be confirmed. *)
val end_invocation : grant -> unit
(** Reject an invocation that has not been accepted, including a Browser it
    already claimed. An accepted invocation keeps its original Browser and
    publisher authorities independently until their corresponding owner ends. *)
val cancel_invocation : grant -> unit
(** Reject the original invocation and both of its private authorities.
    Browser Release, peer loss and credentialless withdrawal end only Browser
    admission. A separately authenticated publisher can deliver its final public
    notice after that settlement, until this original provider is revoked.
    Publication waits for [accept], validates through the captured callback and
    acknowledges only confirmed durable host admission. Its callback must never
    dispatch Browser input or discover a replacement owner. *)
val revoke : t -> unit
val await_stopped : t -> (unit, shutdown_error) result
(** Joins this broker's listener/connections, not an external Browser's cleanup.
    [Ok ()] confirms the original listener descriptor was closed (or was never
    created). Descriptor-close failure remains [Listener_close_unconfirmed].
    Shutdown never unlinks the socket pathname or removes its directory: both
    remain untouched because a later pathname may belong to a successor. *)
