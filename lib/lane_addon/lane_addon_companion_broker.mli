(** Independent, memory-only transport for trusted credential companions.
    A grant belongs to one admitted exported invocation. Its descriptor travels
    only in the private host context, never model arguments/results or storage. *)
type error = Unavailable | Not_started | Outcome_unknown
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
    It must never retire a replacement Browser. *)
type t
type grant
val create : sw:Eio.Switch.t -> directory:string -> max_message_bytes:int -> (t, error) result
(** The caller supplies an existing canonical, owned 0700 directory outside
    retained Lane data and agent work disks. The owner switch joins connections;
    [revoke] ends admission and signals cancellation. [await_stopped] observes
    the listener and its connection scopes after cancellation/cleanup have joined.
    There are no model-request ports, deadlines, payload logs or automatic retry. *)
val issue : t -> bind:(selection -> (binding, error) result) -> (grant, error) result
(** [bind] captures one exact owner after checking the original host principal
    and declarations. Binding itself must send no Browser input. The first
    authenticated connection consumes the grant before any yielding work. *)
val descriptor : grant -> Yojson.Safe.t
val end_invocation : grant -> unit
(** Revoke an unused grant after the exported call returns. A connection already
    claimed by that invocation remains bound for its background login job. *)
val cancel : grant -> unit
(** Cancel an unused or claimed original invocation, including after dispatch. *)
val revoke : t -> unit
val await_stopped : t -> unit
(** Joins this broker's listener/connections, not an external Browser's cleanup.
    The caller owns the supplied directory and removes it only after this join. *)
