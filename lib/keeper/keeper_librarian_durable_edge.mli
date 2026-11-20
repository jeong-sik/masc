(** The Runtime edge that every original request of the completed-history
    Librarian goes through: the configured destination, the check that it is
    still the one an original was captured for, and the call that submits a
    retained original to its Add-on worker. A history request and a message-floor
    step both reach the same package and tool, so both use this edge. *)
val reserved : unit -> string list
val resolve : config:Workspace.config -> reserved:string list ->
  (Lane_addon_runtime.tool_export option, string) result
(** [None] means the Add-on is not attached. A conflicting, unready, manual or
    foreign export is an error. *)
val with_destination : config:Workspace.config -> reserved:string list ->
  (Keeper_librarian_durable_request.destination -> ('a, string) result) -> ('a, string) result
(** Run [publish] with the destination the configuration names now, under the
    configuration and action serializers. The destination must be this
    feature's package and tool. *)
val fresh_gate_authority : config:Workspace.config -> reserved:string list ->
  owner:Keeper_librarian_durable_request.owner ->
  expected:Keeper_librarian_durable_request.destination -> unit -> (unit, string) result
(** For the Gate of an already proved original answer: the physical owner and
    Memory epoch are still [owner]'s, and the complete ready configured
    destination still has [expected]'s installation, package and tool.
    A new semantic revision may continue that Gate without changing or
    resubmitting its parent answer. This grants no original Add-on dispatch
    authority. The Gate separately requires its own captured authority before
    a new evaluation; completed and uncertain evaluations retain their evidence.
    An Eio entry point; its blocking owner reads offload themselves. *)
val call : config:Workspace.config -> reserved:string list ->
  expected:Keeper_librarian_durable_request.destination ->
  original:Lane_addon_tool_request_owner.Record.t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_submit_once.call_error) result
(** Submit the retained [original] to the worker of [expected]'s configuration.
    The record is enough: the call reads its record again, not its body. Only
    failures before the worker RPC are [Not_sent]. *)
val confirm_destination : config:Workspace.config -> reserved:string list ->
  Keeper_librarian_durable_request.destination -> (unit, Lane_addon_submit_once.error) result
(** The configuration still publishes [destination]'s installation, package,
    tool and semantic revision. A missing export is [Unavailable]: the Add-on is
    off or not ready. A conflicting export or a changed configuration is [Rejected]. *)

val reconcile_replacement : config:Workspace.config -> reserved:string list ->
  original:Lane_addon_tool_request_owner.Record.t -> request:Lane_addon_exact.request ->
  (Lane_addon_exact.replacement_reconciliation, Lane_addon_submit_once.error) result
(** Reconcile this complete retained original through the trusted runner-free
    Runtime ending port. The caller keeps its physical owner, own-fence and
    confirmed-predecessor authority. This never reads/submits worker state or
    grants Memory/ACK authority; pending and unknown originals remain owned. *)

val observe_destination : config:Workspace.config -> reserved:string list ->
  Keeper_librarian_durable_request.destination ->
  (Keeper_librarian_durable_request.destination, Lane_addon_submit_once.error) result
(** Compare the original with a fresh complete configured destination and its
    ready worker, retaining the actual ready destination for a bound
    before-admission replacement refusal. A changed file without that worker
    remains unavailable, never [Replaced]. This observation alone neither
    dispatches nor settles. *)
