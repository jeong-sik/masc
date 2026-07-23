type success =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; manifest : (unit, string) result
  }

type operation_outcome =
  | Compacted of success
  | No_compaction of Keeper_post_turn.no_compaction

type lifecycle_stage =
  | Operator_request
  | Compaction_started
  | Compaction_completed

type failure =
  | Lifecycle of
      { stage : lifecycle_stage
      ; checkpoint_applied : bool
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      }
  | Lifecycle_with_failure_dispatch of
      { stage : lifecycle_stage
      ; checkpoint_applied : bool
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result

val run_admitted
  :  ?exact_execution_guard:Keeper_compaction_llm_summarizer.exact_execution_guard
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> unit
  -> [ `Applied of success
     | `No_compaction of Keeper_post_turn.no_compaction
     | `Compaction_failed of failure
     | `Busy of Keeper_turn_admission.autonomous_block
     ]
(** The provider call runs OUTSIDE the keeper admission: [run_admitted]
    first performs a state-free availability preflight, then splits into
    [prepare_compaction] (durable load + policy + LLM plan, no slot held and no
    active lifecycle) and one admitted lifecycle section owning request +
    start + source-CAS commit + completion/failure. The lane stays runnable
    while the LLM works; a failed final admission cannot strand
    [compaction_active], and interleaved checkpoint changes fail the exact
    source CAS. A rejected completion after the checkpoint commit dispatches
    an explicit lifecycle failure cleanup before reporting the checkpoint as
    applied; if that cleanup is also rejected, the typed failure reports
    [checkpoint_applied = true]. This is the single sanctioned caller of that
    admission variant. *)

val failure_to_string : failure -> string
val observe_manifest : keeper_name:string -> (unit, string) result -> unit

module For_testing : sig
  val preserve_no_compaction_after_final_admission_busy
    :  Keeper_event_queue_state.no_compaction_reason
    -> bool
end
