type t = int

let initial = 1

let next t =
  if t = Int.max_int then 1 else t + 1

let to_int t = t

let of_int n =
  if n >= 0 then Some n else None

let equal = Int.equal
let compare = Int.compare
let is_current ~current ~reply = Int.equal current reply
