(** Input transitions commit to the configured checkpoint sink before becoming
    visible in the Agent. With no sink these are in-memory transitions only.
    The Agent lock serializes the exact owner check, sink and mutation. A sink
    must not re-enter the same Agent's mutating or checkpoint APIs. *)

val install :
  Agent_types.t -> Agent_input_request.pending -> (unit, Error.t) result

val consume :
  Agent_types.t -> Agent_input_request.pending option -> (unit, Error.t) result
(** [None], or an owner replaced during a preceding hook, changes nothing. *)

val respond :
  Agent_types.t -> Agent_input_request.pending ->
  message:(Agent_input_request.pending -> Types.message) ->
  (unit, Agent_types.input_response_error) result
(** Build the response observation from the canonical owned question, then save
    the candidate messages and consumed wait together before updating the Agent. *)
