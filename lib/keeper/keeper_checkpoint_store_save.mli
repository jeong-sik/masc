(** Saving a checkpoint to the canonical file.

    [save_agent_core_for_keeper] saves a Keeper's own checkpoint and keeps
    its lineage; [save_agent_core_classified] saves without keeping one. Both
    return a [save_agent_core_outcome] and give the error as text.
    [save_agent_core_classified_typed] is the path they share. It takes the
    canonical writer ([write_canonical_durably] in both saves), the
    [save_lineage] and the payload writer as arguments and keeps the error
    typed. It checks the transcript, reads what the canonical already holds
    and writes nothing when the incoming turn count is below it
    ([Stale_noop]). Otherwise it plans the objects, writes them and then the
    head, and, when the payload cannot be encoded, retries once with the
    offending JSON dropped.
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_session

(* Who a save keeps a lineage for. Only a Keeper's own saves do; a save by a
   tool or a test writes the file and keeps nothing. *)
type save_lineage =
  | Save_for_keeper of string
  | Save_without_lineage

val write_canonical_durably :
  ownership_root:string ->
  string ->
  (unit -> string list) -> (Unix.stats, Keeper_fs.durable_write_error) result

val save_agent_core_classified_typed :
  write_canonical:(ownership_root:string ->
                   string ->
                   (unit -> string list) ->
                   (Unix.stats, Keeper_fs.durable_write_error) result) ->
  save_lineage:save_lineage ->
  payload_writer:Checkpoint_payload_writer.t ->
  session_dir:string ->
  history_retained:int ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t ->
  (save_agent_core_outcome,
   save_agent_core_error)
  result

val save_agent_core_classified :
  session_dir:string ->
  history_retained:int ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t ->
  (save_agent_core_outcome, string)
  result

val save_agent_core_for_keeper :
  keeper_name:string ->
  session_dir:string ->
  history_retained:int ->
  boundary:Agent_core.Checkpoint_objects.boundary ->
  Agent_core.Checkpoint.t ->
  (save_agent_core_outcome, string)
  result
