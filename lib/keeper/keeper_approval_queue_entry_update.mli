(** The steps that the summary and exact-attempt transitions of
    [Keeper_approval_queue] share.

    [find_pending_entry_unchecked] reads a pending entry by id and returns
    [None] once it is resolved. [summary_transition_rejection] says why a
    summary change is refused: the entry has a bound exact attempt.
    [persist_pending_entry_unlocked] writes the snapshot with one updated
    entry and replaces the pending map when the write lands.
    [notify_waiting_approval] broadcasts a change of the waiting inventory for
    the keeper of an entry; a failing broadcast is logged, and a cancellation
    of the calling fiber still wins.
    [publish_summary_update] broadcasts that change and records the summary
    update of an entry. [publish_summary_transition] and
    [publish_exact_attempt_transition] run it after a transition that changed
    the entry and pass the result of the transition on.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result

val find_pending_entry_unchecked :
  id:string -> Keeper_approval_queue_rules_types.pending_approval option

val summary_transition_rejection :
  Keeper_approval_queue_rules_types.pending_approval ->
  summary_transition_rejection option

val persist_pending_entry_unlocked :
  map:Keeper_approval_queue_rules_types.pending_approval Set_util.StringMap.t ->
  entry:Keeper_approval_queue_rules_types.pending_approval ->
  Keeper_approval_queue_rules_types.pending_approval ->
  (bool, storage_error) result

val notify_waiting_approval :
  source:Keeper_waiting_inventory_broadcast.source ->
  Keeper_approval_queue_rules_types.pending_approval -> unit

val publish_summary_update : id:string -> unit

val publish_summary_transition :
  id:string -> (bool, 'a) result -> (bool, 'a) result

val publish_exact_attempt_transition :
  id:string ->
  (exact_attempt_transition, 'a) result ->
  (exact_attempt_transition, 'a) result
