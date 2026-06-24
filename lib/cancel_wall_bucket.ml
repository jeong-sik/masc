(** Single source of truth for the wall-clock duration bucket label used
    in cancel/timeout metrics.

    [keeper_llm_bridge] and [masc_oas_bridge] both emit the same cancel
    metric and must agree on boundaries so dashboards can union the two
    sources into one bimodal view (#10942). The boundaries previously
    lived as a named function in one file and inline literals in the
    other; a silent edit to either copy would have broken that union. *)

let fast = "fast"
let short_tail = "short_tail"
let mid_tail = "mid_tail"
let long_mid = "long_mid"
let long_tail = "long_tail"

let of_wall (wall : float) : string =
  if wall < 60.0 then fast
  else if wall < 300.0 then short_tail
  else if wall < 600.0 then mid_tail
  else if wall < 1800.0 then long_mid
  else long_tail
