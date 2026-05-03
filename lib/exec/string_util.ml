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
