module type Base = sig
  module X : sig end
end

module type Leak =
  Base with module X = Keeper_event_queue_persistence.Nested
