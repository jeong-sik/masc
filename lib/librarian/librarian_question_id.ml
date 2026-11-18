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

let equal left right =
  String.equal left.front right.front && String.equal left.back right.back
;;
