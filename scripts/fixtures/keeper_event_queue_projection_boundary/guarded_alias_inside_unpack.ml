module type Empty = sig end
module Leak =
  (val
    (let module Alias = Keeper_event_queue_persistence in
     (module Alias : Empty))
    : Empty)
