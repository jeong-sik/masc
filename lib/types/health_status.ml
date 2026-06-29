type t =
  | Ok
  | Warming
  | Snapshot_not_ready
  | Degraded
  | Stale
  | Warning
  | Unavailable
  | Unknown
  | Blocked
  | Error
  | Timeout

let of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "ok" | "good" | "healthy" -> Ok
  | "warming" -> Warming
  | "snapshot_not_ready" -> Snapshot_not_ready
  | "degraded" | "interrupted" -> Degraded
  | "stale" -> Stale
  | "warning" | "warn" | "watch" | "risk" -> Warning
  | "unavailable" -> Unavailable
  | "blocked" -> Blocked
  | "error" | "bad" | "critical" -> Error
  | "timeout" -> Timeout
  | "unknown" | _ -> Unknown

let to_string = function
  | Ok -> "ok"
  | Warming -> "warming"
  | Snapshot_not_ready -> "snapshot_not_ready"
  | Degraded -> "degraded"
  | Stale -> "stale"
  | Warning -> "warning"
  | Unavailable -> "unavailable"
  | Unknown -> "unknown"
  | Blocked -> "blocked"
  | Error -> "error"
  | Timeout -> "timeout"

let equal left right = left = right

let pp fmt status = Format.pp_print_string fmt (to_string status)

let rank = function
  | Blocked | Error | Timeout -> 3
  | Degraded | Stale | Warning | Unavailable | Unknown -> 2
  | Warming | Snapshot_not_ready -> 1
  | Ok -> 0

let rank_string raw = raw |> of_string |> rank

let max left right = if rank left >= rank right then left else right

let max_string left right = max (of_string left) (of_string right) |> to_string

let requires_operator_action status = rank status >= 3

let requires_operator_action_string raw = raw |> of_string |> requires_operator_action
