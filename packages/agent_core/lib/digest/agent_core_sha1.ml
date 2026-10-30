module D = Digestif.SHA1
module Slices = Agent_core_digest_slices

let raw_digest_string s =
  let ctx =
    Slices.feed (fun ctx ~off ~len s -> D.feed_string ctx ~off ~len s) D.empty s 0 (String.length s)
  in
  D.to_raw_string (D.get ctx)
