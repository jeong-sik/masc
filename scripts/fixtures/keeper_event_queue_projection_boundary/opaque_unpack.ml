module type Empty = sig end
let packed = ()
module Leak = (val packed : Empty)
