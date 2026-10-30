type t =
  | Under_1s
  | Bucket_1_to_15s
  | Bucket_15_to_60s
  | Bucket_60_to_300s
  | Over_300s

let of_seconds f =
  (* NaN / infinity / negative inputs can leak through env-parsed timeouts.
     Route every non-finite or sub-zero value to [Under_1s] so the
     emitted label set never includes a degenerate "ge_300s for NaN"
     spike that hides the actual budget tail.  Finite ≥ 0 values pick
     a bucket by the half-open thresholds below. *)
  if (not (Float.is_finite f)) || f < 0.0
  then Under_1s
  else if f < 1.0
  then Under_1s
  else if f < 15.0
  then Bucket_1_to_15s
  else if f < 60.0
  then Bucket_15_to_60s
  else if f < 300.0
  then Bucket_60_to_300s
  else Over_300s
;;

(* Labels mirror the half-open semantics of [of_seconds] — the upper
   bound is exclusive (e.g. 15.0 lands in [ge_15s_lt_60s], not in
   [ge_1s_lt_15s]).  Boundary semantics are exercised by
   [test_process_timeout_counter]. *)
let to_label = function
  | Under_1s -> "lt_1s"
  | Bucket_1_to_15s -> "ge_1s_lt_15s"
  | Bucket_15_to_60s -> "ge_15s_lt_60s"
  | Bucket_60_to_300s -> "ge_60s_lt_300s"
  | Over_300s -> "ge_300s"
;;
