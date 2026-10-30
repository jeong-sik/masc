(** Keeper_post_turn — post-turn checkpoint preservation.

    Orchestrates end-of-turn checkpoint wire-ins.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Current-memory selection runs in
    [Keeper_agent_run_post_turn_memory]; task learning remains in
    [Workspace_task].

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** Combined post-turn outcome for checkpoint preservation and per-turn
    context metrics. *)
type post_turn_lifecycle =
  { updated_meta : Keeper_meta_contract.keeper_meta
  ; checkpoint : Agent_core.Checkpoint.t option
  ; checkpoint_bytes : int option
      (** Bytes of the canonical checkpoint on disk after the turn. [None]
          when no checkpoint was preserved or the store could not answer;
          the latter is logged and counted. *)
  ; message_count : int
  }

(** End-of-turn pipeline. Preserves the checkpoint and persists the result to
    the keeper meta and dashboard surface. Keeper autonomy remains owned by
    its heartbeat/turn lane. *)
val apply_post_turn_lifecycle :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  checkpoint:Agent_core.Checkpoint.t option ->
  post_turn_lifecycle

(** Size of the canonical checkpoint on disk for [meta]'s session, from the
    checkpoint store; nothing is serialised. [Ok None] when there is no
    checkpoint; [Error] carries the store's reason. *)
val durable_checkpoint_bytes :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (int option, string) result
(** Apply the keeper post-turn lifecycle.

    Ordering is strict: tool emission drain (K4b) then multimodal
    hydration (K1). K4b is the producer K1 consumes, and the multimodal
    pass persists a [workspace_meta] summary that depends on it. *)
