(** Installing a checkpoint only if the canonical file still holds the source
    the candidate advances.

    [save_agent_core_if_source] installs a candidate over an expected source
    reference, and [save_agent_core_if_absent] installs one only when no
    canonical exists; both return a [checkpoint_installation].
    [save_agent_core_if_source_with] is the first with the lock and the head
    writer passed in. [plan_for_session] plans a save that follows the
    canonical on disk and writes again the objects the session does not hold.
    [with_checkpoint_cas_lock] runs a function under the durable lock beside
    the session directory; a location failure comes back as an installation
    that was not installed, and [installation_of_lock_observation] does the
    same for a lock that was not acquired and adds a failed release to the
    function's result as an auxiliary failure. [write_checkpoint_bytes]
    writes a head durably and atomically.
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_installation

val installation_of_lock_observation :
  checkpoint_installation
  File_lock_eio.durable_lock_observation ->
  checkpoint_installation

val with_checkpoint_cas_lock :
  session_dir:string ->
  (string ->
   checkpoint_installation) ->
  checkpoint_installation

val plan_for_session :
  session_dir:string ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t -> (Agent_core.Checkpoint_objects.plan, Agent_core_base.Error.t) result

val save_agent_core_if_source_with :
  ?require_absent:bool ->
  with_checkpoint_cas_lock:(session_dir:string ->
                            (string ->
                             checkpoint_installation) ->
                            checkpoint_installation) ->
  write_checkpoint_bytes:(on_durable_commit:(unit -> unit) ->
                          ownership_root:string ->
                          path:string ->
                          bytes:string ->
                          (Keeper_fs.durable_commit_outcome,
                           Keeper_fs.durable_write_error)
                          result) ->
  on_checkpoint_commit_observer:(Keeper_checkpoint_ref.t -> unit) ->
  session_dir:string ->
  expected_source_ref:Keeper_checkpoint_ref.t ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t ->
  checkpoint_installation

val write_checkpoint_bytes :
  on_durable_commit:(unit -> unit) ->
  ownership_root:string ->
  path:string ->
  bytes:string ->
  (Keeper_fs.durable_commit_outcome, Keeper_fs.durable_write_error) result

val save_agent_core_if_source :
  session_dir:string ->
  expected_source_ref:Keeper_checkpoint_ref.t ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t ->
  checkpoint_installation

val save_agent_core_if_absent :
  session_dir:string ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t ->
  checkpoint_installation
