module D = Digestif.MD5
module Slices = Agent_core_digest_slices

type ctx = D.ctx

let empty = D.empty

let feed_string ctx s =
  Slices.feed (fun ctx ~off ~len s -> D.feed_string ctx ~off ~len s) ctx s 0 (String.length s)

let to_hex ctx = D.to_hex (D.get ctx)
