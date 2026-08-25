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
