(* Exec-local string utilities.
   Kept minimal to avoid pulling in masc_core. *)

let contains_substring haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec loop i =
      if i > h - n then false
      else String.sub haystack i n = needle || loop (i + 1)
    in
    loop 0

let contains_substring_ci haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  if n = 0 then false
  else if n > h then false
  else
    let rec match_at i j =
      if j = n then true
      else
        let h_ch = Char.lowercase_ascii (String.unsafe_get haystack (i + j)) in
        let n_ch = Char.lowercase_ascii (String.unsafe_get needle j) in
        h_ch = n_ch && match_at i (j + 1)
    in
    let rec loop i =
      if i > h - n then false else match_at i 0 || loop (i + 1)
    in
    loop 0
