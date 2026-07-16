type success =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; manifest : (unit, string) result
  }

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
  -> (success, failure) result

val run_admitted
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> [ `Applied of success
     | `Compaction_failed of failure
     | `Busy of Keeper_turn_admission.autonomous_block
     ]
(** [run] inside the keeper's turn slot via
    [Keeper_turn_admission.run_compaction_if_free], releasing the slot the
    moment the compaction commits (manifest observation included).

    This is the single sanctioned caller of that admission variant, and the
    critical section is exactly the checkpoint recovery — a deterministic
    file/FSM operation, never a provider turn — so bypassing the
    chat-backlog yield cannot park queued chat behind long work. Any
    follow-up turn must re-enter through the standard [run_if_free] lane,
    where a chat backlog wins (#24865 review). *)

val failure_to_string : failure -> string
val observe_manifest : keeper_name:string -> (unit, string) result -> unit
