(* Gzip codec — the fallback half of HTTP content negotiation.

   See [compression_gzip.mli] for why this exists alongside the zstd codec. *)

type compress_result =
  | Unchanged of string
  | Compressed of string

(* Deterministic header: no mtime, no filename, no comment. A response body is
   not a file, and stamping wall-clock into it would make identical payloads
   produce different bytes — which would defeat any future ETag derived from
   the encoded form. *)
let no_mtime () = 0l

let compress ?(level = 4) data =
  let length = String.length data in
  if length < Compression_codec.min_size then Unchanged data
  else begin
    let input = De.bigstring_create De.io_buffer_size in
    let output = De.bigstring_create De.io_buffer_size in
    let window = De.Lz77.make_window ~bits:15 in
    let queue = De.Queue.create 0x1000 in
    let encoded = Buffer.create (length / 4) in
    let consumed = ref 0 in
    let refill buffer =
      let take = min (Bigstringaf.length buffer) (length - !consumed) in
      Bigstringaf.blit_from_string data ~src_off:!consumed buffer ~dst_off:0
        ~len:take;
      consumed := !consumed + take;
      take
    in
    let flush buffer written =
      Buffer.add_string encoded (Bigstringaf.substring buffer ~off:0 ~len:written)
    in
    match
      Gz.Higher.compress ~level ~w:window ~q:queue ~refill ~flush ()
        (Gz.Higher.configuration Gz.Unix no_mtime)
        input output
    with
    | () ->
      let payload = Buffer.contents encoded in
      (* Same rule as the zstd codec: never hand back a larger body just
         because an encoding was available. *)
      if String.length payload >= length then Unchanged data
      else Compressed payload
    | exception exn ->
      Log.Misc.warn "gzip compression failed, sending identity: %s"
        (Printexc.to_string exn);
      Unchanged data
  end
