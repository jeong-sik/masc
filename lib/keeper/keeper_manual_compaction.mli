type post_install_lifecycle =
  | Completion_applied
  | Completion_rejected_failure_dispatched of
      { completion_error : Keeper_context_runtime.lifecycle_dispatch_error }
  | Completion_rejected_failure_dispatch_failed of
      { completion_error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch_error : Keeper_context_runtime.lifecycle_dispatch_error
      }

type applied_receipt =
  { installation : Keeper_checkpoint_store.installed_checkpoint
  ; lifecycle : post_install_lifecycle
  ; manifest : (unit, string) result
  ; commit_count : int
  }

type success =
  { recovery : Keeper_post_turn.compaction_recovery
  ; receipt : applied_receipt
  }

type committed =
  { recovery : Keeper_post_turn.compaction_recovery
  ; installation : Keeper_checkpoint_store.installed_checkpoint
  ; lifecycle : post_install_lifecycle
  }

type operation_outcome =
  | Compacted of committed
  | No_compaction of Keeper_post_turn.no_compaction

type pre_install_lifecycle_stage =
  | Operator_request
  | Compaction_started

type failure =
  | Lifecycle_before_install of
      { stage : pre_install_lifecycle_stage
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      }
  | Lifecycle_before_install_with_failure_dispatch of
      { stage : pre_install_lifecycle_stage
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result

type admitted_operation =
  [ `Applied of success
  | `No_compaction of Keeper_post_turn.no_compaction
  | `Compaction_failed of failure
  ]

val run_under_admission
  :  ?before_dispatch_authority:
       Keeper_compaction_llm_summarizer.before_dispatch_authority
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> unit
  -> admitted_operation
(** Manual compaction while the caller already owns the Keeper turn token.
    No nested admission or release occurs. *)

val failure_to_string : failure -> string
module For_testing : sig
  val checkpoint_installation_auxiliary_to_json :
    Keeper_checkpoint_store.checkpoint_installation_auxiliary ->
    Yojson.Safe.t
end
