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

(* [failing] is what [Channel_gate_metrics.health_of_counts] emits when a
   channel had no successes at all, or an error rate at or above half. Before
   it was listed here it fell through to [Unknown], which ranks 2 — the same as
   [Degraded] — so the producer's worst rung and its middle rung arrived at
   operators as one severity. *)
let of_string_opt raw =
  match String.lowercase_ascii (String.trim raw) with
  | "ok" | "good" | "healthy" -> Some Ok
  (* [initializing] is what the dashboard core and the operator digest emit for
     a workspace that has not finished starting. It was absent here, so it fell
     to [Unknown], which ranks 2 — the same rung as [Degraded] and [Stale] — and
     [is_health_at_risk] (rank >= 2) reported a booting workspace as at risk in
     the briefing. It is the same state [Warming] already names (#27560). *)
  | "warming" | "initializing" -> Some Warming
  | "snapshot_not_ready" -> Some Snapshot_not_ready
  | "degraded" | "interrupted" -> Some Degraded
  | "stale" -> Some Stale
  | "warning" | "warn" | "watch" | "risk" -> Some Warning
  | "unavailable" -> Some Unavailable
  | "blocked" -> Some Blocked
  | "error" | "bad" | "critical" | "failing" -> Some Error
  | "timeout" -> Some Timeout
  | "unknown" -> Some Unknown
  | _ -> None

(* Kept total for callers that only need a status to render. It cannot tell an
   explicit "unknown" from a word this vocabulary never had — use
   {!of_string_opt} where that difference decides anything. *)
let of_string raw =
  match of_string_opt raw with
  | Some status -> status
  | None -> Unknown

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

