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
val same_destination : Keeper_librarian_durable_request.destination ->
  Keeper_librarian_durable_request.destination -> bool
(** Compare installation/package/tool and semantic configuration revision.
    Source bytes, comments and activity do not identify worker inputs.
    Pure comparison only; grants no live authority or retry by itself. *)
val fresh_authority : config:Workspace.config -> reserved:string list ->
  owner:Keeper_librarian_durable_request.owner ->
  expected:Keeper_librarian_durable_request.destination -> unit -> (unit, string) result
(** The physical owner and Memory epoch are still [owner]'s, and the configured
    destination still has [expected]'s installation, package, tool and semantic
    configuration revision. Blocking read; offload it in an Eio caller. *)
val call : config:Workspace.config -> reserved:string list ->
  expected:Keeper_librarian_durable_request.destination ->
  original:Lane_addon_tool_request_owner.retained -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_submit_once.call_error) result
(** Submit the retained [original] to the worker of [expected]'s configuration.
    Only failures before the worker RPC are [Not_sent]. *)
val confirm_destination : config:Workspace.config -> reserved:string list ->
  Keeper_librarian_durable_request.destination -> (unit, Lane_addon_submit_once.error) result
(** The configuration still publishes [destination]'s installation, package,
    tool and semantic revision. A missing export is [Unavailable]: the Add-on is
    off or not ready. A conflicting export or a changed configuration is [Rejected]. *)
