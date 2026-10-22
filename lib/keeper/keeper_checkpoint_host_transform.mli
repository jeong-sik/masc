(** Exact host transformations of an operation-owned checkpoint. The proof
    binds complete source/candidate payloads; it grants no child, branch CAS,
    native settlement or replay authority. *)
type t
val preserve : source:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  candidate:Agent_core.Checkpoint.t -> (t, string) result
(** Ordinary host preparation preserves the entire message prefix, complete
    pending input and repetition evidence. Configuration/context setup may
    change other fields, but cannot roll the execution frontier backwards. *)
val replay : source:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  history_messages:Agent_core.Types.message list -> response_text:string ->
  suppress_visible_response:bool -> stop_reason:Runtime_agent.stop_reason ->
  (t * Agent_core.Checkpoint.t * Keeper_checkpoint_replay_projection.replay_suffix_prune_reason option, string) result
(** Apply the existing direct-turn replay projection to the exact source.
    Every original ordinary User message and ToolUse/ToolResult-bearing message
    must survive in order. Internal-thought pruning is not a direct-operation
    transformation. Pending ownership and repetition evidence remain exact. *)
val incomplete_response_cut : source:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  candidate:Agent_core.Checkpoint.t -> (t, string) result
(** The existing typed incomplete-Assistant cut, preserving every earlier
    message and all other payload fields except observation time. This is a
    transformation witness, not permission to replace a native call. *)
val validate : t -> source:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  candidate:Keeper_checkpoint_store.exact_checkpoint_snapshot -> (unit, string) result
(** Recheck both exact references after loading retained artifacts. A proof
    cannot be reused for another predecessor or an edited/mutated candidate. *)
