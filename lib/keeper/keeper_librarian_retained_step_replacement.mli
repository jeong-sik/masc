(** A retained original floor's logical questions. Physical parents stay retained
    until real program settlement; replacement never consumes or archives source.
    Publication callers own the existing serialized Memory lane, purge fence
    and workspace lease. Read observations grant no effect authority and are
    repeated by the actual guarded host and program entry points. *)
type t
val read : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  range:Keeper_librarian_floor_step_request.link ->
  source:Keeper_librarian_runtime.retained_step_source -> (t, string) result
(** Blocking strict inventory. One logical leaf per position, linked only by
    full immutable replacement intents and exact publication ACKs. Every parent
    requires its strict known non-executed declaration ending and no actual Gate.
    Missing pending children are recoverable; missing confirmed children,
    forks, cycles, changed questions and progressed unacknowledged children fail. *)
val steps : t ->
  (Lane_addon_tool_request_owner.retained * Keeper_librarian_floor_step_request.t) list
(** Logical leaves in position order. An incomplete publication selects its
    ended parent so the same saved child can be recovered. No dispatch grant. *)
val confirm_selected : store:Lane_addon_store.t ->
  Keeper_librarian_floor_step_request.t -> (unit, string) result
(** Fresh actual inventory and body check. Only the confirmed logical leaf can
    dispatch. Pending publication data cannot authorize its child. Blocking. *)
val resume : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:Lane_addon_tool_request_owner.retained ->
  step:Keeper_librarian_floor_step_request.t -> (string, string) result
(** Eio entry point. Under the actual ready same-owner Runtime serializer,
    retain the complete new question in the parent's replacement CAS before its
    body; strictly reread the child before the exact ACK. Resume a saved intent's
    same ID/body, even after rollback or another semantic change. Only a real
    Before_dispatch ending or typed host Replaced_declaration qualifies.
    Unknown, permission refusals, answers, Gate work and Cut releases do not.
    No provider, Memory publication, source ACK, archive or scheduler call. *)
val validate_payload :
  read_scope:(scope:string -> (Lane_addon_tool_request_owner.retained list, string) result) ->
  owner:Keeper_librarian_durable_request.owner ->
  range:Keeper_librarian_floor_step_request.link ->
  source:Keeper_librarian_runtime.retained_step_source -> (unit, string) result
(** Pure bound graph checks for deployment. No selection or effect authority is
    returned. Each parent's actual Exact ending is checked separately by the
    deploy consumer's existing Exact read ports. *)
type payload_status = Original_question | Child_awaiting_publication
val payload_status :
  read_scope:(scope:string -> (Lane_addon_tool_request_owner.retained list, string) result) ->
  owner:Keeper_librarian_durable_request.owner ->
  range:Keeper_librarian_floor_step_request.link ->
  source:Keeper_librarian_runtime.retained_step_source -> request_id:string ->
  (payload_status, string) result
(** Bound graph observation only. Deployment must positively confirm that a
    child awaiting its parent's ACK has no host record or execution proof;
    its Captured metadata alone cannot prove that it has never dispatched. *)
