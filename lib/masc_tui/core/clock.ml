module Mono = struct
  type t = int64

  let nanoseconds_per_second = 1e9
  let nanoseconds_per_ms = 1_000_000L
  let nanoseconds_per_us = 1_000L

  let zero = 0L
  let of_ns ns = ns
  let to_ns t = t
  let now = Mtime_clock.elapsed_ns

  let add_ns at offset =
    let sum = Int64.add at offset in
    if Int64.compare offset 0L > 0 && Int64.compare sum at < 0 then
      Int64.max_int
    else sum

  let offset_ns seconds =
    let ns = seconds *. nanoseconds_per_second in
    if not (Float.is_finite ns) || ns <= 0. then 0L
    else if ns >= Int64.to_float Int64.max_int then Int64.max_int
    else Int64.of_float ns

  let after_s at seconds =
    if seconds > 0. then add_ns at (offset_ns seconds) else at

  let after_ms at ms =
    if ms <= 0 then at
    else
      let max_ms = Int64.div Int64.max_int nanoseconds_per_ms in
      let ms64 = Int64.of_int ms in
      if Int64.compare ms64 max_ms >= 0 then Int64.max_int
      else add_ns at (Int64.mul ms64 nanoseconds_per_ms)

  let sub_ns at ~since = Int64.sub at since

  let seconds_since at ~since =
    Int64.to_float (Int64.sub at since) /. nanoseconds_per_second

  let ms_since at ~since =
    Int64.to_float (Int64.sub at since) /. 1e6

  let us_since at ~since =
    let diff = Int64.sub at since in
    Int64.to_int (Int64.div diff nanoseconds_per_us)

  let of_wall ~now ~wall_now target_wall =
    if Float.is_finite wall_now && Float.is_finite target_wall then
      after_s now (target_wall -. wall_now)
    else now

  let compare = Int64.compare
  let equal = Int64.equal
  let min a b = if Int64.compare a b <= 0 then a else b
  let max a b = if Int64.compare a b >= 0 then a else b
end
