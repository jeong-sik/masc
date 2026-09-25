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
    let head_workspace = max 0 (t.head_cap - head_len) in
    let take_head = min head_workspace len in
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

(** Walk backwards from [pos] to find the start of the last complete
    UTF-8 character that begins at or before [pos].  Continuation
    bytes have the bit pattern 10xxxxxx (0x80..0xBF); a leading byte
    never matches, so the scan stops as soon as one is found. *)
(** Length of the UTF-8 character whose leading byte is at position [i].
    0xxxxxxx → 1 byte (ASCII)
    110xxxxx → 2 bytes
    1110xxxx → 3 bytes
    11110xxx → 4 bytes *)
let utf8_char_len s i =
  let b = Char.code s.[i] in
  if b land 0x80 = 0 then 1
  else if b land 0xE0 = 0xC0 then 2
  else if b land 0xF0 = 0xE0 then 3
  else 4

let utf8_find_char_start s pos =
  let rec loop i =
    if i <= 0 then 0
    else if Char.code s.[i] land 0xC0 <> 0x80 then i
    else loop (i - 1)
  in
  loop (min pos (String.length s - 1))

(** Truncate [s] to at most [max_bytes], breaking only at UTF-8
    character boundaries.  Returns [s] unchanged if it already fits. *)
let utf8_truncate s max_bytes =
  let len = String.length s in
  if len <= max_bytes then s
  else
    let boundary = utf8_find_char_start s (max_bytes - 1) in
    let char_end = boundary + utf8_char_len s boundary in
    if char_end <= max_bytes then String.sub s 0 char_end
    else String.sub s 0 boundary

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

(* The longest UTF-8 sequence. A cut splits at most this many bytes minus
   one off either side of the character it lands in. *)
let utf8_max_char_bytes = 4

let is_utf8_continuation c = Char.code c land 0xC0 = 0x80

(* Length of the sequence a lead byte opens; [None] for a byte that opens
   none (a continuation byte, or 0xF8..0xFF). *)
let utf8_lead_length c =
  let b = Char.code c in
  if b land 0x80 = 0 then Some 1
  else if b land 0xE0 = 0xC0 then Some 2
  else if b land 0xF0 = 0xE0 then Some 3
  else if b land 0xF8 = 0xF0 then Some 4
  else None

(* Bytes at the end of [s], a stream prefix, that begin a character the
   cut left incomplete. 0 when the last character is whole, or when the
   bytes are not a UTF-8 lead and its continuations. *)
let utf8_split_suffix_length s =
  let len = String.length s in
  let lowest_lead = max 0 (len - (utf8_max_char_bytes - 1)) in
  let rec scan i =
    if i < lowest_lead then 0
    else if is_utf8_continuation s.[i] then scan (i - 1)
    else
      match utf8_lead_length s.[i] with
      | Some n when i + n > len -> len - i
      | Some _ | None -> 0
  in
  scan (len - 1)

(* Bytes at the start of [s], a stream suffix, that continue a character
   whose lead byte was cut off. 0 when the run of continuation bytes is
   longer than a cut can leave, since such bytes are not UTF-8. *)
let utf8_split_prefix_length s =
  let len = String.length s in
  let rec count i =
    if i < len && is_utf8_continuation s.[i] then count (i + 1) else i
  in
  let run = count 0 in
  if run < utf8_max_char_bytes then run else 0

let truncation_marker dropped = Printf.sprintf "\n...(truncated %d bytes)...\n" dropped

let max_render_bytes ~head_cap ~tail_cap =
  let marker = String.length (truncation_marker max_int) in
  if head_cap < 0 || tail_cap < 0 || tail_cap > max_int - marker
     || head_cap > max_int - marker - tail_cap then
    invalid_arg "Exec_buffer.max_render_bytes: invalid capture bounds";
  head_cap + tail_cap + marker

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
    (* Both cuts sit mid-stream, so either can land inside a character.
       The split bytes go into the marker's count with the dropped ones. *)
    let head_raw = head t in
    let tail_raw = tail t in
    let head_split = utf8_split_suffix_length head_raw in
    let tail_split = utf8_split_prefix_length tail_raw in
    let head_s = String.sub head_raw 0 (String.length head_raw - head_split) in
    let tail_s =
      String.sub tail_raw tail_split (String.length tail_raw - tail_split)
    in
    head_s
    ^ truncation_marker (bytes_dropped t + head_split + tail_split)
    ^ tail_s
