module Cancel = struct
  type t = unit

  exception Cancelled of exn

  let sub f = f ()
  let cancel () exn = raise (Cancelled exn)
end

module Fiber = struct
  let both left right =
    left ();
    right ()
end

module Time = struct
  let sleep (_clock : 'a) (_seconds : float) = ()
end
