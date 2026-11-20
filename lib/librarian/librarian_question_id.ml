type t =
  { front : string
  ; back : string
  }

let half_length = 32

let is_half value =
  String.length value = half_length
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let of_halves ~front ~back =
  if is_half front && is_half back then Some { front; back } else None
;;

let half digest = String.sub (Agent_core_sha256.to_hex digest) 0 half_length
let of_digests ~front ~back = { front = half front; back = half back }

let equal left right =
  String.equal left.front right.front && String.equal left.back right.back
;;
