(** Keeper_post_turn — post-turn checkpoint preservation, handoff rollover,
    and explicit compaction recovery.

    Orchestrates end-of-turn checkpoint wire-ins. Compaction is never inferred
    here; manual and provider-overflow callers enter the explicit recovery
    function with a typed trigger.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Current-memory selection runs in
    [Keeper_agent_run_post_turn_memory]; task learning remains in
    [Workspace_task].

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

(** Combined post-turn outcome for checkpoint preservation, rollover, and
    per-turn context metrics. Explicit compaction has its own request path. *)
type post_turn_lifecycle =
  { updated_meta : Keeper_meta_contract.keeper_meta
  ; checkpoint : Agent_core.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; checkpoint_bytes : int
  ; message_count : int
  }

(** Recovered checkpoint after a durably applied explicit compaction request.
    Manual and provider-overflow callers consume the same result. *)
type compaction_recovery =
  { checkpoint : Agent_core.Checkpoint.t
  ; checkpoint_installation : Keeper_checkpoint_store.installed_checkpoint
  ; trigger : Compaction_trigger.t
  ; evidence : Keeper_compaction_evidence.t
  ; commit_count : int
  } [@@warning "-69"]

type no_compaction = Keeper_compaction_outcome.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : Keeper_compaction_outcome.no_compaction_reason
  }

type compaction_recovery_error =
  | Checkpoint_ref_load_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Checkpoint_candidate_failed of string
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | No_compaction of no_compaction

type prepared_commit_failure =
  { error : compaction_recovery_error
  ; committed : compaction_recovery option
  }

type prepared_commit_outcome =
  | Committed of compaction_recovery
  | Not_committed of no_compaction
  | Commit_failed of prepared_commit_failure

val compaction_recovery_error_to_tag : compaction_recovery_error -> string
val compaction_recovery_error_to_string : compaction_recovery_error -> string

(** End-of-turn pipeline. Preserves the checkpoint and persists the result to
    the keeper meta and dashboard surface. Explicit compaction is a separate
    request path; Keeper autonomy remains owned by its heartbeat/turn lane. *)
val apply_post_turn_lifecycle :
  meta:Keeper_meta_contract.keeper_meta ->
  checkpoint:Agent_core.Checkpoint.t option ->
  post_turn_lifecycle
(** Apply the keeper post-turn lifecycle.

    Ordering is strict: tool emission drain (K4b) then multimodal
    hydration (K1). K4b is the producer K1 consumes, and the multimodal
    pass persists a [workspace_meta] summary that depends on it. *)

type prepared_compaction
(** Fully-planned compaction: durable source loaded, policy and LLM plan
    computed, nothing committed yet.  Carrying this value lets a caller run
    the provider call outside any keeper admission and commit later — the
    source CAS, not the Keeper Owner child, is the interleaving guard. The token is
    opaque and owns the exact Keeper identity and commit policy captured at
    preparation; callers cannot construct it or combine a plan with another
    Keeper's metadata. The exact execution identity is retained as immutable
    structural evidence, with no second claim or lifecycle state. *)

(** Phase 1: load the durable source and run the policy + LLM planner.
    Admission-free by contract; the caller must not hold the keeper's turn
    slot while this runs. *)
val prepare_compaction :
  ?before_dispatch_authority:
    Keeper_compaction_llm_summarizer.before_dispatch_authority ->
  base_path:string ->
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  trigger:Compaction_trigger.t ->
  unit ->
  (prepared_compaction, compaction_recovery_error) result

(** Phase 2: source-CAS commit of a fully-planned compaction.  The caller
    decides which admission (if any) guards this phase. *)
val commit_prepared_compaction :
  prepared_compaction -> prepared_commit_outcome

module For_testing : sig
  val commit_prepared_compaction_with_history :
    ?after_checkpoint_installed:(unit -> unit) ->
    save_agent_core_history:
      (session_dir:string -> Agent_core.Checkpoint.t -> unit) ->
    prepared_compaction ->
    prepared_commit_outcome
end

(** Pure typed outcome for a prepared exact-output result that cannot enter
    its commit admission. The retained execution identity is projected without
    another claim, lock, persistence write, or provider dispatch. *)
val no_compaction_of_prepared :
  ?cause:Keeper_compaction_outcome.exact_execution_terminal_cause ->
  prepared_compaction -> no_compaction

(** Reload the canonical AGENT_CORE checkpoint and apply an explicit typed
    compaction request. Composition of {!prepare_compaction} and
    {!commit_prepared_compaction}; the source CAS is the commit authority. *)
val recover_latest_checkpoint_for_compaction :
  ?before_dispatch_authority:
    Keeper_compaction_llm_summarizer.before_dispatch_authority ->
  base_path:string ->
  base_dir:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  trigger:Compaction_trigger.t ->
  unit ->
  prepared_commit_outcome
