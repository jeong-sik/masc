type t =
  | Under_1s
  | Bucket_1_to_15s
  | Bucket_15_to_60s
  | Bucket_60_to_300s
  | Over_300s

let of_seconds f =
  if f < 1.0
  then Under_1s
  else if f < 15.0
  then Bucket_1_to_15s
  else if f < 60.0
  then Bucket_15_to_60s
  else if f < 300.0
  then Bucket_60_to_300s
  else Over_300s
;;

let to_label = function
  | Under_1s -> "lt_1s"
  | Bucket_1_to_15s -> "1s_to_15s"
  | Bucket_15_to_60s -> "15s_to_60s"
  | Bucket_60_to_300s -> "60s_to_300s"
  | Over_300s -> "ge_300s"
;;
