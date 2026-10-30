(** A masc rewrite of the history a Keeper sends: windowing, a Gate replay
    reference, unread carriers. It works on history messages, with media by
    reference; the request is resolved from its output
    ({!Agent_core.Agent.model_input_projection} is that conversion). *)
type t = Agent_core.Types.message list -> (Agent_core.Types.message list, Agent_core.Error.t) result
