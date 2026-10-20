(** Agent elicitation bridge helpers.

    These helpers keep the hook-level {!Hooks.ElicitInput} API aligned with
    runtime input pause/resume payloads without making the base error library
    depend on runtime protocol modules. *)

val input_required_of_request
  :  agent_name:string
  -> ?created_at:float
  -> Hooks.elicitation_request
  -> Error.input_required

val message_of_response
  :  ?metadata:Types.metadata
  -> question:string
  -> Hooks.elicitation_response
  -> Types.message option

(** Settle the exact current run/request and optionally append its canonical
    response message under the Agent state lock. *)
val apply_response
  :  ?metadata:Types.metadata
  -> Agent_types.t
  -> Agent_input_request.pending
  -> Hooks.elicitation_response
  -> (unit, Agent_types.input_response_error) result
