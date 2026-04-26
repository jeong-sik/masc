let rec update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then () else update atomic f
;;

let rec update_with_result atomic f =
  let old_val = Atomic.get atomic in
  let new_val, result = f old_val in
  if Atomic.compare_and_set atomic old_val new_val
  then result
  else update_with_result atomic f
;;

type ('state, 'result) commit =
  { next_state : 'state
  ; result : 'result
  }

let rec update_with_commit atomic f =
  let old_val = Atomic.get atomic in
  let { next_state; result } = f old_val in
  if Atomic.compare_and_set atomic old_val next_state
  then result
  else update_with_commit atomic f
;;
