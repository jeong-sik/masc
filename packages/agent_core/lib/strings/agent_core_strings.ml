let contains_at ~equal ~haystack ~needle ~pos =
  let needle_length = String.length needle in
  let rec matches index =
    index = needle_length
    || (equal
          (String.unsafe_get haystack (pos + index))
          (String.unsafe_get needle index)
       && matches (index + 1))
  in
  matches 0
;;

let contains ~equal ~haystack ~needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  if needle_length = 0
  then true
  else if needle_length > haystack_length
  then false
  else (
    let last = haystack_length - needle_length in
    let rec scan pos =
      pos <= last && (contains_at ~equal ~haystack ~needle ~pos || scan (pos + 1))
    in
    scan 0)
;;

let contains_substring ~haystack ~needle = contains ~equal:Char.equal ~haystack ~needle

let equal_ci left right =
  Char.equal (Char.lowercase_ascii left) (Char.lowercase_ascii right)
;;

let contains_substring_ci ~haystack ~needle = contains ~equal:equal_ci ~haystack ~needle

(* Same cut as the coordinator's [String_util.utf8_prefix]. agent_core must not
   import the coordinator, so the rule is written here once for every layer
   below it. test/test_utf8_prefix_parity.ml compares the two. *)
let utf8_prefix ~max_bytes s =
  if max_bytes <= 0
  then ""
  else (
    let length = String.length s in
    if length <= max_bytes
    then s
    else (
      let is_continuation index = Char.code (String.unsafe_get s index) land 0xC0 = 0x80 in
      if not (is_continuation max_bytes)
      then String.sub s 0 max_bytes
      else (
        (* [s.[max_bytes]] continues a character: back up to its lead byte and
           cut before it. An ASCII byte met first ends the walk after itself. *)
        let rec lead index =
          if index < 0
          then 0
          else (
            let byte = Char.code (String.unsafe_get s index) in
            if byte land 0x80 = 0
            then index + 1
            else if byte land 0xC0 = 0xC0
            then index
            else lead (index - 1))
        in
        String.sub s 0 (lead (max_bytes - 1)))))
;;
