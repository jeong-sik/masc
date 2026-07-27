module type Empty = sig end
module Leak =
  (val Keeper_event_queue_persistence.packed : Empty)
