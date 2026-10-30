(* %+d prints the sign, so a negative tally reads "-3" where "+%d" wrote
   "+-3". *)
let text votes = Printf.sprintf "%+d" votes
