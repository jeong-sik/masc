(* See atomic_util.mli for the contract. *)

let rec update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then () else update atomic f
