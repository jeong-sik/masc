(** Keeper_checkpoint_delta — Delta-based checkpoint storage and retrieval.

    Enables incremental checkpoint storage by tracking only message deltas
    since the last checkpoint, reducing I/O and storage costs for long-running
    keeper sessions.

    @since delta-context-optimization *)

type delta_checkpoint = {
  checkpoint_id : string;
  base_checkpoint_id : string option;
  timestamp : float;
  generation : int;
  message_offset : int;
  new_messages : Agent_sdk.Types.message list;
  incremental_token_count : int;
  total_message_count : int;
  total_token_count : int;
}

type delta_chain = {
  base : Keeper_working_context.checkpoint;
  deltas : delta_checkpoint list;
}

(** Check if delta checkpoint should be used instead of full checkpoint. *)
val should_use_delta :
  prev_ckpt:Keeper_working_context.checkpoint option ->
  current_messages:Agent_sdk.Types.message list ->
  delta_chain_length:int ->
  bool

(** Create a delta checkpoint from a base checkpoint and current context. *)
val create_delta_checkpoint :
  checkpoint_id:string ->
  base_ckpt:Keeper_working_context.checkpoint ->
  ctx:Keeper_working_context.working_context ->
  generation:int ->
  delta_checkpoint

(** Save a delta checkpoint to disk. *)
val save_delta :
  session_dir:string ->
  delta_checkpoint ->
  unit

(** Load a delta checkpoint from disk. *)
val load_delta :
  session_dir:string ->
  checkpoint_id:string ->
  delta_checkpoint option

(** Reconstruct full context by applying delta chain to base. *)
val reconstruct_from_deltas :
  base:Keeper_working_context.checkpoint ->
  deltas:delta_checkpoint list ->
  max_tokens:int ->
  Keeper_working_context.working_context option

(** Discover and load complete delta chain from session directory. *)
val discover_delta_chain :
  session_dir:string ->
  latest_checkpoint_id:string ->
  delta_chain option

(** Compute efficiency ratio of a delta checkpoint. *)
val compute_delta_efficiency : delta_checkpoint -> float

(** Generate statistics for a delta chain. *)
val compute_chain_stats : delta_chain -> string
