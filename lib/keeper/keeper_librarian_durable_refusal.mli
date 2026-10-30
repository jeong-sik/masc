(** Host-confirmed refusals of original completed-history requests. *)
val report : store:Lane_addon_store.t -> Keeper_librarian_durable_request.t ->
  Lane_addon_exact.final -> Keeper_librarian_runtime.not_committed

type t
val retained_stop : store:Lane_addon_store.t -> record:Lane_addon_tool_request_owner.retained ->
  request:Keeper_librarian_durable_request.t ->
  (t option, string) result
(** Call after strict whole-inventory original/host-final validation. A definite
    Execution [Input_refused] with actual capacity-only evidence, counterpart-
    only source and no Memory range receipts retains its original as a stop.
    The stop reports that original's coordinates and refusal before fresh
    selection: no new chat capture, request ID or provider dispatch occurs.
    Restoring and validating the retained complete input still costs I/O.

    This is an unresolved refusal of the original, not proof that today's
    source payload is unchanged. Confirmed original Memory range receipts or
    {!Keeper_librarian_refusal_frontier.past_original}'s Memory-backed reader
    frontier and external ACK release it for ordinary settlement. This does
    not promote accounted unread holes to read content. Changed positions alone
    do not release it.
    A different configured installation/package/tool/semantic configuration
    revision can authorize fresh selection under the existing authority and
    source-publication fences, while retaining the earlier refusal. Returning
    to a refused configuration therefore cannot remint the original after a
    crash or configuration A/B/A change. It never redispatches a rejected ID.
    Comments/source revision, On/Off, restart, appended input and elapsed time
    do not release it. Off/unready/unreadable configuration cannot release it.
    A provider-registry-only change has no retained comparable configuration
    identity here and does not automatically retry; an operator must also
    change the Addon's semantic configuration (for example its [run_id]).
    That explicit reconfiguration permits a fresh attempt, not a claim that
    provider capacity improved. Unknown, opaque and mixed failures retain
    their existing policy. No Memory/cursor/ACK effect is authorized. *)

val request_id : t -> string
val blocks_destination : t list -> Keeper_librarian_durable_request.destination ->
  Keeper_librarian_durable_consumer.error option
(** Pure check against every retained refusal. Recheck inside the existing
    destination serializer before retaining a fresh original. *)
val blocked : config:Workspace.config -> reserved:string list -> t list ->
  Keeper_librarian_durable_consumer.error option
(** Read the current semantic destination before selecting fresh source. If
    configuration is unavailable, report a retained refusal without selecting.
    This observation does not replace [blocks_destination] at retention. *)
