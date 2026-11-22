type t = int

let none = 0
let bold = 1 lsl 0
let italic = 1 lsl 1
let underline = 1 lsl 2
let reverse = 1 lsl 3
let strike = 1 lsl 4

let ( lor ) a b = Stdlib.( lor ) a b
let union a b = Stdlib.( lor ) a b
let remove base flag = base land lnot flag
let has base flag = base land flag = flag
let equal = Int.equal
let to_bits t = t
