module D = Digestif.SHA256
module Slices = Agent_core_digest_slices

type t = D.t
type ctx = D.ctx

let digest_size = D.digest_size
let slice_bytes = Slices.slice_bytes
let empty = D.empty
let init = D.init
let get = D.get

type bigstring = Digestif.bigstring

let feed_bigstring = D.feed_bigstring

let feed_string ctx ?off ?len s =
  let off, len =
    Slices.range ~name:"Agent_core_sha256.feed_string" ~length:(String.length s) ?off ?len ()
  in
  Slices.feed (fun ctx ~off ~len s -> D.feed_string ctx ~off ~len s) ctx s off len

let feed_bytes ctx ?off ?len b =
  let off, len =
    Slices.range ~name:"Agent_core_sha256.feed_bytes" ~length:(Bytes.length b) ?off ?len ()
  in
  Slices.feed (fun ctx ~off ~len b -> D.feed_bytes ctx ~off ~len b) ctx b off len

let digest_string ?off ?len s = get (feed_string empty ?off ?len s)

let digesti_string iter =
  let ctx = ref empty in
  iter (fun s -> ctx := feed_string !ctx s);
  get !ctx

let equal = D.equal
let to_hex = D.to_hex
let consistent_of_hex_opt = D.consistent_of_hex_opt
let to_raw_string = D.to_raw_string
