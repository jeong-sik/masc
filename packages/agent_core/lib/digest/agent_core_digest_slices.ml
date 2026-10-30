(* Bytes hashed per digestif call. 64 KiB of SHA-256 took about 0.24 ms on
   2026-10-27 (M3 Max, digestif 1.3.0, about 280 MB/s); 1 MiB took 3.7 ms
   (RFC-0474 L2). OCaml code runs between slices, so a stop-the-world request
   waits for one slice at most. *)
let slice_bytes = 65_536

(* Resolves [?off ?len] the way digestif does and refuses a range outside the
   buffer before any slice is fed. *)
let range ~name ~length ?(off = 0) ?len () =
  let len = match len with Some len -> len | None -> length - off in
  if off < 0 || len < 0 || off > length - len
  then invalid_arg (name ^ ": offset out of bounds")
  else off, len

let rec feed feed_one ctx buf off remaining =
  if remaining = 0
  then ctx
  else (
    let len = Int.min slice_bytes remaining in
    feed feed_one (feed_one ctx ~off ~len buf) buf (off + len) (remaining - len))
