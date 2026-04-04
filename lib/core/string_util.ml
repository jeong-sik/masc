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
  contains_substring
    (String.lowercase_ascii haystack)
    (String.lowercase_ascii needle)
