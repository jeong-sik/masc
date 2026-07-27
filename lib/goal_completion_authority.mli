(** Non-leaf Goal-completion command adapter.

    It performs one outer runtime execution, then delegates the locked
    current-evidence CAS and atomic terminal write to the private Goal-state
    authority.  No approval value or terminal write primitive is exported. *)

type success =
  { goal : Goal_store.goal
  ; evaluator_runtime : string
  ; reviewed_at : string
  }

type failure =
  | Rejected of
      { reason : string
      ; evaluator_runtime : string
      }
  | Unavailable of
      { reason : string
      ; evaluator_runtime : string
      }
  | Conflict of string
  | Persistence_failed of string

val request_completion :
  config:Workspace_utils.config ->
  requesting_agent:string ->
  expected:Goal_store.goal ->
  expected_state_version:int ->
  completion_claim:string ->
  (success, failure) result
