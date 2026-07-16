type success =
  { recovery : Keeper_context_runtime.overflow_retry_recovery
  ; manifest : (unit, string) result
  }
type failure =
  | Lifecycle of string * bool * Keeper_context_runtime.lifecycle_dispatch_error
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
val run
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> (success, failure) result
val failure_to_string : failure -> string
val observe_manifest : keeper_name:string -> (unit, string) result -> unit
