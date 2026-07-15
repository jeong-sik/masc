type success =
  { recovery : Keeper_context_runtime.overflow_retry_recovery
  ; meta : Keeper_meta_contract.keeper_meta
  }
type failure =
  | Unsupported_trigger of Compaction_trigger.t
  | Lifecycle of string * bool * Keeper_context_runtime.lifecycle_dispatch_error
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
  | Manifest_projection of
      { operation_id : string
      ; detail : string
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Metadata_projection of
      { operation_id : string
      ; detail : string
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
val run
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> trigger:Compaction_trigger.t
  -> (success, failure) result
val failure_to_string : failure -> string

module For_testing : sig
  val project_compaction_runtime
    :  operation_id:string
    -> applied_at:float
    -> trigger:Compaction_trigger.t
    -> evidence:Keeper_compact_policy.compaction_evidence
    -> Keeper_meta_contract.compaction_runtime
    -> Keeper_meta_contract.compaction_runtime
end
