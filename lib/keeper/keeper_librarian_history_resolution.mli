(** Explicit fencing of history originals with distinct absence and Cut APIs.
    Lock order: original source sessions, aggregate Memory, snapshot, owner scope.
    No model/worker RPC, source ACK, cursor movement or cleanup.
    Offload the complete blocking scope, including its lock release, in Eio.
    The command ports [preview_cut_command] and [with_cut_fence_serialized]
    instead enter on an Eio fiber: they consult the actual Runtime owner and
    offload their complete filesystem scopes themselves. *)
type error =
  | Original_absent
  | Ineligible of string
  | Observation_changed
  | Range_already_recorded
  | Already_fenced of Keeper_librarian_history_resolution_state.t
  | Host_claim_busy
  | Unavailable of string
  | Publication_uncertain of string

type preview = private {
  expected : Keeper_librarian_history_resolution_state.guard;
  scope : string;
  request_id : string;
  request_digest : string;
}

val error_to_string : error -> string
val preview : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (preview, error) result
(** Read-only preparation. Pending Memory publication or unreadable receipts
    refuse; this does not run publication recovery or initialize an epoch. *)
val preview_cut : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (preview, error) result
(** A separate observation of a terminal execution-stage Cut. Acquires and
    releases the real Exact claim during observation, but retains no grant.
    No completed latest execution, gate or replacement preparation, settlement,
    prior range receipt or changed source position is allowed. This is a
    fence observation only; automatic ingress uses the separately bound
    command preview below. *)
val preview_cut_command : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (preview * Keeper_librarian_history_resolution_state.cut_basis, error) result
(** The same strict observation, binding a command to the actual latest Cut.
    A busy claim is retryable; no command or grant is retained by this read.
    Call from an Eio fiber, not from an offloaded raw system thread. *)
type cut_grant
val with_cut_fence_serialized : config:Workspace.config -> keeper_name:string ->
  request_id:string -> expected:Keeper_librarian_history_resolution_state.guard ->
  basis:Keeper_librarian_history_resolution_state.cut_basis -> actor:string ->
  reason:string -> now:float -> use:(cut_grant -> 'a) -> ('a, error) result
(** Reacquire the actual Cut claim, source and Memory locks, revalidate its
    unchanged owner/source/cursors and absent receipts, then publish/read back
    the matching fence. Current Memory may rebase. An existing fence is adopted
    only for this exact command. [use] must retain/read back its Fenced intent
    here; all work is joined before return. Enter from an Eio fiber. [use]
    runs outside Eio in the complete offloaded filesystem critical section,
    under the Runtime destination serializer. No original RPC or ACK is sent. *)
val confirm_cut_grant : store:Lane_addon_store.t -> cut_grant ->
  (Keeper_librarian_history_resolution_state.t, string) result
(** Recheck the bound fence and actual live claim. Expired/foreign/changed
    evidence refuses; the value is not usable outside [use]. *)
module For_testing : sig
  val with_cut_fence_serialized : after_publish:(unit -> unit) ->
    config:Workspace.config -> keeper_name:string -> request_id:string ->
    expected:Keeper_librarian_history_resolution_state.guard ->
    basis:Keeper_librarian_history_resolution_state.cut_basis -> actor:string ->
    reason:string -> now:float -> use:(cut_grant -> 'a) -> ('a, error) result
  (** The production critical section with one call-local observation hook.
      [after_publish] runs after an actual successful fence publication and
      before its strict readback, under the source/Memory locks and Exact
      claim. Adopting an already observed fence does not invoke the hook.
      The hook runs outside Eio, grants no authority and cannot replace
      publication/readback. *)
end
val read : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (Keeper_librarian_history_resolution_state.t option, error) result
val fence_serialized : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard ->
  actor:string -> reason:string -> now:float ->
  (Keeper_librarian_history_resolution_state.t, error) result
(** Must run inside this Keeper's existing serialized Memory lane, like
    completed-history publication. HTTP callers must enqueue durable intent,
    not invoke this concurrently with that lane. The old captured Memory
    revision may differ; [expected] is the preview's current basis. A successful
    result proves only the durable fence. There is no followup execution here.
    [Publication_uncertain] may follow a visible write: reobserve this exact ID. *)
val fence_cut_serialized : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard ->
  actor:string -> reason:string -> now:float ->
  (Keeper_librarian_history_resolution_state.t, error) result
(** The Cut counterpart of [fence_serialized]. Holds the real original
    claim through publication and strict readback within the same source and
    Memory critical section. Preserves the original Unknown and its source;
    grants no successor, Memory write or ACK. Only an explicitly bound command
    confirmed through [with_cut_fence_serialized] may prepare a child. *)
