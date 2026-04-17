let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > hay_len then false
  else
    let rec loop idx =
      if idx + needle_len > hay_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let contains_substring_ci haystack needle =
  needle <> "" &&
  contains_substring
    (String.lowercase_ascii haystack)
    (String.lowercase_ascii needle)

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
