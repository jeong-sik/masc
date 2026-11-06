(** The install of the durable approval queue in [Keeper_approval_queue].

    [install_persistence] loads the snapshot, the log and the replay results
    of a workspace under the store lock and publishes them in memory. A load
    that fails, an id that two workspaces share, and an id that is both
    pending and delivered mark the store unavailable and return
    [Install_storage_failed]. Entries that cannot be decoded stay out of the
    maps and mark the store unavailable. [install_persistence_internal] takes
    a hook that runs after the load and one that runs after the pending map is
    published.
    The install then retires the deliveries that no reader needs any more and
    sends the wake again, as [Boot_replay], for every delivery whose wake was
    not observed and whose grant is not consumed. It counts both and lists the
    deliveries that failed.
    [keeper_delivery_readers] says who can still read a delivery: nobody,
    because the meta of the keeper is gone ([Keeper_gone]); the wakes still
    queued for the keeper and the approvals that its unsettled operations name
    ([Keeper_readers]); or unknown, when the meta, the event queue or the
    operation store cannot be read ([Keeper_readers_unknown]).
    [queued_hitl_wake_ids] reads the queued wakes and
    [gate_references_of_operations] the approvals that the operations name.
    [delivery_is_spent] says whether a delivery may leave the store.
    [spent_delivery_ids] collects those deliveries, reading the readers of a
    keeper once, and [retire_spent_deliveries] removes them, writing the
    replay results file before the snapshot.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result

val install_persistence_internal :
  after_load:(unit -> 'a) ->
  after_pending_publish:(unit -> 'b) ->
  base_path:string ->
  (install_report,
   install_error)
  result

val install_persistence :
  base_path:string -> (install_report, install_error) result
