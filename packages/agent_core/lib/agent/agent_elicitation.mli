(** Agent elicitation bridge helpers.

    These helpers keep the hook-level {!Hooks.ElicitInput} API aligned with
    runtime input pause/resume payloads without making the base error library
    depend on runtime protocol modules. *)

val input_required_of_request
  :  agent_name:string
  -> turn:int
  -> ?created_at:float
  -> Hooks.elicitation_request
  -> Error.input_required

val message_of_response
  :  ?metadata:Types.metadata
  -> question:string
  -> Hooks.elicitation_response
  -> Types.message option

(** [true] only when an external User message was appended. *)
val apply_response
  :  ?metadata:Types.metadata
  -> Agent_types.t
  -> Error.input_required
  -> Hooks.elicitation_response
  -> bool
