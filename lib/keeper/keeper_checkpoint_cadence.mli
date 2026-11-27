(** Mid-turn checkpoint persistence cadence for {!Keeper_agent_run}.

    Decides whether a mid-turn [Agent_core.Agent.checkpoint_stage] callback
    should perform a durable store write or skip a redundant write while
    preserving crash-recovery, retry, and outbox-settlement invariants.

    Turn-closing [finalize] writes live outside this sink and always persist. *)

type skip_reason =
  | Context_only_after_persisted_messages
  | Context_only_after_skipped_tool_results
  | Deferred_until_tool_results
  | Within_min_interval of
      { elapsed_sec : float
      ; min_interval_sec : float
      }

type decision =
  | Persist
  | Skip of skip_reason

type state

val create : unit -> state

(** Whether the latest message in [checkpoint] is an assistant turn carrying at
    least one [ToolUse] block. *)
val checkpoint_has_pending_tool_use : Agent_core.Checkpoint.t -> bool

(** Record the [stop_reason] observed in [Hooks.AfterTurn] immediately before
    [After_assistant_collected]. Only [StopToolUse] authorizes deferring
    [After_assistant_collected]; every other stop reason (including [MaxTokens]
    carrying a truncated [ToolUse] block) forces persistence and resets the
    mid-turn pacing budget so a subsequent [Retry_without_thinking] attempt
    persists its first tool-result round immediately. *)
val observe_assistant_stop_reason :
  state -> stop_reason:Llm_provider.Types.stop_reason -> unit

(** Decide whether [stage] should persist [checkpoint] at monotonic timestamp
    [now_s] under [min_interval_sec].

    Invariants:
    - [After_input_wait_changed] and [After_rejected_response_dropped] always
      return [Persist].
    - [After_assistant_collected] returns [Skip Deferred_until_tool_results]
      only when [min_interval_sec > 0.0], [observe_assistant_stop_reason]
      reported [StopToolUse] for this turn, and [checkpoint_has_pending_tool_use]
      is [true]. Otherwise (including unobserved stop reasons or non-tool
      terminal reasons carrying stray [ToolUse] blocks) it returns [Persist] so
      outbox settlement witnesses remain intact.
    - [After_context_injection] returns
      [Skip Context_only_after_persisted_messages] whenever the previous
      persisted checkpoint in this run already persisted the physically
      identical [messages] list (for example [Masc_context_injector], which
      updates only in-memory telemetry keys with [extra_messages = []]), even
      when [min_interval_sec = 0.0].
    - When [After_tool_results_appended] was just skipped under
      [Within_min_interval], a context-only [After_context_injection] with the
      same [messages] list returns [Skip Context_only_after_skipped_tool_results]
      rather than crossing the interval threshold under
      [After_context_injection] (which would reset the pacing timer without
      advancing [tool_result_save_count]), while refreshing the deferred
      checkpoint payload with the latest context.
    - [After_context_injection] that appended new [extra_messages] follows the
      same [min_interval_sec] pacing rule as [After_tool_results_appended]
      (persisting immediately when [min_interval_sec = 0.0] or once
      [min_interval_sec] has elapsed, and queuing as deferred when skipped).
    - The first [After_tool_results_appended] of a turn (or after a pacing
      reset) always returns [Persist]; subsequent ones require at least
      [min_interval_sec] seconds since the previous mid-turn tool/context save,
      and skipped saves are retained for {!take_deferred} so an error return can
      flush them before resume. *)
val decide :
  state ->
  stage:Agent_core.Agent.checkpoint_stage ->
  checkpoint:Agent_core.Checkpoint.t ->
  now_s:float ->
  min_interval_sec:float ->
  decision

(** Record that [stage] durably persisted [checkpoint] at monotonic timestamp
    [now_s], clearing any pending deferred checkpoint. Only called after
    [Keeper_checkpoint_store.Saved _]. *)
val record_persisted :
  state ->
  stage:Agent_core.Agent.checkpoint_stage ->
  checkpoint:Agent_core.Checkpoint.t ->
  now_s:float ->
  unit

(** Take and clear the newest checkpoint skipped by interval pacing, if any, so
    an error path can flush committed tool rounds before returning. *)
val take_deferred :
  state -> (Agent_core.Agent.checkpoint_stage * Agent_core.Checkpoint.t) option

val skip_reason_to_string : skip_reason -> string
