let of_seconds seconds =
  let seconds = Int.max 0 (int_of_float seconds) in
  if seconds < 60
  then Printf.sprintf "%ds" seconds
  else if seconds < 3600
  then Printf.sprintf "%dm" (seconds / 60)
  else Printf.sprintf "%dh%02dm" (seconds / 3600) (seconds mod 3600 / 60)
;;
