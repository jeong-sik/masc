(* Byte-wise substring containment.

   Old form allocated [String.sub] per inner-loop step; this version
   uses [String.unsafe_get] with index-checked match.  Empty-needle
   short-circuits to [true] (matching [Re.str ""] / [Re.execp]
   semantics that callers relied on). *)
let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > hay_len then false
  else
    let rec match_at i j =
      if j = needle_len then true
      else if String.unsafe_get haystack (i + j)
            <> String.unsafe_get needle j
      then false
      else match_at i (j + 1)
    in
    let last = hay_len - needle_len in
    let rec loop i =
      if i > last then false
      else if match_at i 0 then true
      else loop (i + 1)
    in
    loop 0

(* Byte-wise substring search: returns the index of the first match at or
   after [pos] (default 0), or [None] if absent. Empty needle returns
   [Some pos], matching [Re.exec_opt (Re.str "" |> Re.compile)] semantics. *)
let find_substring ?(pos = 0) haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then Some pos
  else if pos + needle_len > hay_len then None
  else
    let rec match_at i j =
      if j = needle_len then true
      else if String.unsafe_get haystack (i + j)
            <> String.unsafe_get needle j
      then false
      else match_at i (j + 1)
    in
    let last = hay_len - needle_len in
    let rec loop i =
      if i > last then None
      else if match_at i 0 then Some i
      else loop (i + 1)
    in
    loop pos

(* ASCII case-insensitive substring containment without lowercasing
   either string.  Lowering happens byte-by-byte during compare. *)
let contains_substring_ci haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then false
  else if needle_len > hay_len then false
  else
    let rec match_at i j =
      if j = needle_len then true
      else
        let h = Char.lowercase_ascii (String.unsafe_get haystack (i + j)) in
        let n = Char.lowercase_ascii (String.unsafe_get needle j) in
        if h <> n then false else match_at i (j + 1)
    in
    let last = hay_len - needle_len in
    let rec loop i =
      if i > last then false
      else if match_at i 0 then true
      else loop (i + 1)
    in
    loop 0

(* Byte-wise non-overlapping replace: scans [haystack] for [needle] and
   substitutes [by] for each occurrence. Empty needle is a no-op (would
   loop forever otherwise). Skips ahead by [needle_len] after a match,
   matching [Re.replace_string] semantics for non-overlapping replacement. *)
let replace_substring ~needle ~by haystack =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 || needle_len > hay_len then haystack
  else
    let buf = Buffer.create hay_len in
    let rec match_at i j =
      if j = needle_len then true
      else if String.unsafe_get haystack (i + j)
            <> String.unsafe_get needle j
      then false
      else match_at i (j + 1)
    in
    let last = hay_len - needle_len in
    let rec loop i =
      if i > last then
        Buffer.add_substring buf haystack i (hay_len - i)
      else if match_at i 0 then begin
        Buffer.add_string buf by;
        loop (i + needle_len)
      end
      else begin
        Buffer.add_char buf (String.unsafe_get haystack i);
        loop (i + 1)
      end
    in
    loop 0;
    Buffer.contents buf

type truncation =
  | Untouched of string
  | Truncated of { prefix : string; suffix : string; dropped_bytes : int }

(* Find the largest k <= idx such that [String.sub s 0 k] ends at a valid
   UTF-8 character boundary. Handles invalid UTF-8 on a best-effort basis:
   walks back through continuation bytes and cuts before an incomplete lead. *)
let utf8_char_boundary s idx =
  let len = String.length s in
  if idx >= len then len
  else if idx <= 0 then 0
  else
    let is_continuation k = (Char.code s.[k] land 0xC0) = 0x80 in
    if not (is_continuation idx) then
      (* s.[idx] starts a new char — idx is already a boundary *)
      idx
    else
      (* s.[idx] is a continuation; walk back to find the lead byte of the
         incomplete character and cut before it. ASCII bytes encountered
         before any lead are complete on their own, so cut *after* them. *)
      let rec find k =
        if k < 0 then 0
        else
          let b = Char.code s.[k] in
          if (b land 0x80) = 0 then k + 1
          else if (b land 0xC0) = 0xC0 then k
          else find (k - 1)
      in
      find (idx - 1)

let utf8_safe ~max_bytes ~suffix s =
  let len = String.length s in
  if len <= max_bytes then Untouched s
  else
    let suffix_len = String.length suffix in
    let budget = max 0 (max_bytes - suffix_len) in
    let cut = utf8_char_boundary s budget in
    let prefix = String.sub s 0 cut in
    Truncated { prefix; suffix; dropped_bytes = len - cut }

let to_string = function
  | Untouched s -> s
  | Truncated { prefix; suffix; _ } -> prefix ^ suffix

let was_truncated = function
  | Untouched _ -> false
  | Truncated _ -> true
