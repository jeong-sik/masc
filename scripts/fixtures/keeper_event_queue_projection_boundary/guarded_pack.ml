module type Empty = sig end
let packed = (module Keeper_event_queue_persistence : Empty)
