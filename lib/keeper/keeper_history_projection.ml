type t = Agent_core.Types.message list -> (Agent_core.Types.message list, Agent_core.Error.t) result
type preparation = Agent_core.Types.message list -> (t, Agent_core.Error.t) result
