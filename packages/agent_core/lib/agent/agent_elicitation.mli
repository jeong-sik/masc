(** Agent elicitation bridge helpers.

    These helpers keep the hook-level {!Hooks.ElicitInput} API aligned with
    runtime input pause/resume payloads without making the base error library
    depend on runtime protocol modules. *)

val input_required_of_request
  :  agent_name:string
  -> ?created_at:float
  -> Hooks.elicitation_request
  -> Error.input_required

(** Every typed response produces a model-visible User message for its canonical
    question. Answer carries its JSON; Declined and Timeout carry distinct
    explicit observations without inventing an answer or enforcing a timer. *)
val message_of_response
  :  ?metadata:Types.metadata
  -> question:string
  -> Hooks.elicitation_response
  -> Types.message

(** Settle the exact current run/request and append its canonical response
    message under the Agent state lock, after its checkpoint sink confirms. *)
val apply_response
  :  ?metadata:Types.metadata
  -> Agent_types.t
  -> Agent_input_request.pending
  -> Hooks.elicitation_response
  -> (unit, Agent_types.input_response_error) result
