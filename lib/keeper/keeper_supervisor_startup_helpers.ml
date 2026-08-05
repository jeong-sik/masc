let keep_last_n n item lst =
  let full = item :: lst in
  if List.length full <= n then full else List.filteri (fun i _ -> i < n) full
;;
