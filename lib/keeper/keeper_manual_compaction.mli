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
val run
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> (operation_outcome, failure) result

val run_admitted
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> [ `Applied of success
     | `No_compaction of Keeper_post_turn.no_compaction
     | `Compaction_failed of failure
     | `Busy of Keeper_turn_admission.autonomous_block
     ]
(** The provider call runs OUTSIDE the keeper admission: [run_admitted]
    splits into [prepare_compaction] (durable load + policy + LLM plan, no
    slot held) and two short admitted sections (lifecycle start, then the
    source-CAS commit + manifest + completion).  Between them the lane
    stays runnable — a chat backlog or another turn of the same Keeper can
    proceed while the LLM works — and correctness against interleaved
    state change is enforced by the checkpoint source CAS, not by the slot.
    This is the single sanctioned caller of that admission variant. *)

val failure_to_string : failure -> string
val observe_manifest : keeper_name:string -> (unit, string) result -> unit
