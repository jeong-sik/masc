type t =
  { span : int
  ; period : int
  }

(* Reversal preserves periods: [s] has period [p] exactly when [rev s] does,
   so the suffixes of [s] are the prefixes of [rev s], and the prefix function
   of [rev s] gives every prefix's smallest period as [length - border] in one
   linear pass. The reversal is index arithmetic; nothing is copied. *)
let reversed_prefix_function s =
  let n = String.length s in
  let at i = String.unsafe_get s (n - 1 - i) in
  let pi = Array.make n 0 in
  let k = ref 0 in
  for i = 1 to n - 1 do
    while !k > 0 && not (Char.equal (at i) (at !k)) do
      k := pi.(!k - 1)
    done;
    if Char.equal (at i) (at !k) then incr k;
    pi.(i) <- !k
  done;
  pi
;;

let find s ~max_period ~min_copies =
  let n = String.length s in
  if max_period < 1 || min_copies < 2 || n < min_copies
  then None
  else (
    let pi = reversed_prefix_function s in
    (* Longest qualifying suffix first: scan lengths from [n] down. *)
    let rec scan span =
      if span < min_copies
      then None
      else (
        let period = span - pi.(span - 1) in
        if period <= max_period && span >= min_copies * period
        then Some { span; period }
        else scan (span - 1))
    in
    scan n)
;;

let cycle s { span; period } = String.sub s (String.length s - span) period
