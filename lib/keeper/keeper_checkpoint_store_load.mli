(** Loading the canonical AGENT_CORE checkpoint of a session.

    [load_agent_core] reads the checkpoint, answering from the lineage's
    written value while the file still has the identity it was kept under.
    [load_agent_core_for_save] also keeps what it read as the lineage of the
    Keeper that saves next. [turn_history_of_load] reads a load result as a
    [turn_history]: a missing checkpoint is [No_saved_history], a superseded
    version is [Saved_history_superseded], and every other failure stays an
    error. [canonical_message_count] answers from the cached summary or the
    head on disk, and [canonical_byte_count] from the cached summary or the
    size of the file; neither loads the history, and [Ok None] means there is
    no checkpoint. [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_decode

type turn_history =
  | Saved_history of Agent_core.Checkpoint.t
  | No_saved_history
  | Saved_history_superseded of { expected : int; got : int }

val turn_history_of_load :
  (Agent_core.Checkpoint.t,
   checkpoint_load_error)
  result ->
  (turn_history, checkpoint_load_error)
  result

val load_agent_core :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t,
   checkpoint_load_error)
  result

val load_agent_core_for_save :
  keeper_name:string ->
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t,
   checkpoint_load_error)
  result

val canonical_message_count :
  session_dir:string ->
  session_id:string ->
  (int option, checkpoint_load_error)
  result

val canonical_byte_count :
  session_dir:string ->
  session_id:string ->
  (int option, checkpoint_load_error)
  result
