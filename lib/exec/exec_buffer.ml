(* Head+tail truncating byte accumulator.

   Design choices:
   - Head is a plain [Buffer.t] capped at [head_cap]; cheap append
     until the cap is reached, then no-op.
   - Tail is a fixed-size [Bytes.t] ring buffer of size [tail_cap].
     Writes wrap around; reads rotate the ring into linear order when
     [tail] / [render] is called.
   - When head + tail together would cover the entire stream (i.e.
     [total_bytes <= head_cap + tail_cap]), the tail ring still holds
     the last [tail_cap] bytes, but the head already holds the first
     [head_cap].  The [bytes_dropped] counter ensures that overlap
     between head and tail does NOT inflate the perceived loss — see
     the check in [render].  Net: tiny streams render identically to
     the raw stream. *)

type t = {
  head_cap : int;
  tail_cap : int;
  head_buf : Buffer.t;
  tail_ring : Bytes.t;
  mutable tail_size : int;       (* bytes currently stored, <= tail_cap *)
  mutable tail_write : int;      (* next slot to write, < tail_cap *)
  mutable total : int;
}

let create ~head_cap ~tail_cap =
  if head_cap < 0 || tail_cap < 0 then
    invalid_arg "Exec_buffer.create: caps must be >= 0";
  {
    head_cap;
    tail_cap;
    head_buf = Buffer.create (min head_cap 4096);
    tail_ring = Bytes.make tail_cap '\x00';
    tail_size = 0;
    tail_write = 0;
    total = 0;
  }

let total_bytes t = t.total

(* A byte is "retained" if it ended up in the head (because it landed
   before head_cap was full) OR it is still in the tail ring at
   observation time.  Overlap between head and tail counts once. *)
let retained t =
  let head_len = Buffer.length t.head_buf in
  if t.total <= t.head_cap then head_len
  else
    let union = head_len + t.tail_size in
    min t.total union

let bytes_dropped t = t.total - retained t

let add_bytes_inner t buf off len =
  if len <= 0 then ()
  else begin
    (* Append to head until head_cap reached. *)
    let head_len = Buffer.length t.head_buf in
    let head_room = max 0 (t.head_cap - head_len) in
    let take_head = min head_room len in
    if take_head > 0 then
      Buffer.add_subbytes t.head_buf buf off take_head;
    (* All input also flows through the tail ring. When len > tail_cap
       only the last tail_cap bytes land; older bytes are skipped. *)
    if t.tail_cap > 0 then begin
      let skip =
        if len > t.tail_cap then len - t.tail_cap else 0
      in
      let src_off = off + skip in
      let src_len = len - skip in
      (* Two-phase write to handle ring wrap. *)
      let first = min src_len (t.tail_cap - t.tail_write) in
      Bytes.blit buf src_off t.tail_ring t.tail_write first;
      let second = src_len - first in
      if second > 0 then
        Bytes.blit buf (src_off + first) t.tail_ring 0 second;
      t.tail_write <- (t.tail_write + src_len) mod t.tail_cap;
      t.tail_size <- min t.tail_cap (t.tail_size + src_len)
    end;
    t.total <- t.total + len
  end

let add_bytes t buf off len =
  if off < 0 || len < 0 || off + len > Bytes.length buf then
    invalid_arg "Exec_buffer.add_bytes: out-of-range slice";
  add_bytes_inner t buf off len

let add_string t s =
  add_bytes_inner t (Bytes.unsafe_of_string s) 0 (String.length s)

let head t = Buffer.contents t.head_buf

let tail t =
  if t.tail_size = 0 then ""
  else
    let out = Bytes.create t.tail_size in
    let start = (t.tail_write - t.tail_size + t.tail_cap) mod t.tail_cap in
    let first = min t.tail_size (t.tail_cap - start) in
    Bytes.blit t.tail_ring start out 0 first;
    let second = t.tail_size - first in
    if second > 0 then
      Bytes.blit t.tail_ring 0 out first second;
    Bytes.unsafe_to_string out

let render t =
  (* If we retained everything, stitching head+tail back would
     duplicate the overlap.  Prefer the direct pieces to avoid that. *)
  if t.total <= t.head_cap then head t
  else if t.total <= t.tail_cap && t.head_cap = 0 then tail t
  else if bytes_dropped t = 0 then
    (* Full coverage but via two non-empty buffers that share bytes.
       Emit the head verbatim, then only the tail bytes that sit past
       head_cap. *)
    let head_s = head t in
    let tail_s = tail t in
    let extra =
      if t.total <= String.length head_s then ""
      else
        let overlap = t.head_cap - (t.total - String.length tail_s) in
        if overlap <= 0 then tail_s
        else if overlap >= String.length tail_s then ""
        else String.sub tail_s overlap (String.length tail_s - overlap)
    in
    head_s ^ extra
  else
    let dropped = bytes_dropped t in
    Printf.sprintf "%s\n...(truncated %d bytes)...\n%s"
      (head t) dropped (tail t)
