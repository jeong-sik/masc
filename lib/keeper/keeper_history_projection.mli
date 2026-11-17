(** A masc rewrite of the history a Keeper sends: windowing, a Gate replay
    reference, unread carriers. It works on history messages, with media by
    reference; the request is resolved from its output
    ({!Agent_core.Agent.model_input_projection} is that conversion). *)
type t = Agent_core.Types.message list -> (Agent_core.Types.message list, Agent_core.Error.t) result

type preparation = Agent_core.Types.message list -> (t, Agent_core.Error.t) result
(** Prepare one selected request's media on its owning fiber. Preparation may
    read retained evidence or admit a reader through its existing authority.
    The returned projection uses only those captured results: prefix checks
    may apply it repeatedly to the same selected occurrences with different
    argument demotions, without another reader call or live observation.
    Neither preparation nor projection changes canonical history. *)
