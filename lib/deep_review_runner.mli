(** Isolated review runner used by the adversarial review tool. *)

val run_adversarial_review :
  runtime_id:string ->
  prompt:string ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
