(** Pure replay projection shared by host persistence and original-operation
    transformation proofs. No Owner, registry, vision or filesystem effects. *)
type replay_suffix_prune_reason
val replay_suffix_prune_reason_to_string : replay_suffix_prune_reason -> string
val patch_checkpoint_last_assistant : Agent_core.Checkpoint.t ->
  session_id:string -> response_text:string -> Agent_core.Checkpoint.t
val checkpoint_for_replay_persistence :
  history_messages:Agent_core.Types.message list -> session_id:string ->
  response_text:string -> ?suppress_visible_response:bool ->
  ?stop_reason:Runtime_agent.stop_reason -> exclude_thought_from_replay:bool ->
  Agent_core.Checkpoint.t ->
  (Agent_core.Checkpoint.t * replay_suffix_prune_reason option, string) result
