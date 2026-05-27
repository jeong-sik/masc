(** Growable request-body accumulator for httpun/h2 bigstring chunks.

    [Bigstringaf.substring] allocates one string per body chunk before callers
    copy that string into a [Buffer].  This helper keeps the same final
    string API while copying chunks directly into a growable bytes buffer. *)

type t = {
  mutable bytes: Bytes.t;
  mutable length: int;
}

let create initial_capacity =
  { bytes = Bytes.create (max 0 initial_capacity); length = 0 }

let length t = t.length

let next_capacity current needed =
  let rec loop capacity =
    if capacity >= needed then
      capacity
    else if capacity > max_int / 2 then
      needed
    else
      loop (capacity * 2)
  in
  loop (max 1 current)

let ensure_capacity t needed =
  let current = Bytes.length t.bytes in
  if needed > current then begin
    let bytes = Bytes.create (next_capacity current needed) in
    Bytes.blit t.bytes 0 bytes 0 t.length;
    t.bytes <- bytes
  end

let add_bigstring t bigstring ~off ~len =
  if len < 0 then
    invalid_arg "Http_body_buffer.add_bigstring: negative length";
  let needed = t.length + len in
  if needed < t.length then
    invalid_arg "Http_body_buffer.add_bigstring: length overflow";
  ensure_capacity t needed;
  Bigstringaf.blit_to_bytes bigstring ~src_off:off t.bytes ~dst_off:t.length ~len;
  t.length <- needed

let contents t =
  Bytes.sub_string t.bytes 0 t.length
