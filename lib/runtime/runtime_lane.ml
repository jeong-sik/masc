(** Runtime lane — ordered list of candidate runtime ids for keeper turn routing.

    A lane is an opaque routing label (the lane id) plus an ordered candidate
    list of runtime ids.  When a keeper assignment resolves to a lane, the
    keeper turn driver resolves each id to a materialized {!Runtime.t} and
    attempts them sequentially until one succeeds or the lane is exhausted.
    Keeping ids here breaks the [Runtime <-> Runtime_lane] module cycle.

    Only the [Ordered] strategy is implemented today; the type is extensible
    for future health/capacity strategies. *)

type strategy = Ordered

type t =
  { id : string
  ; strategy : strategy
  ; candidates : string list
  }

let make ~id ~strategy candidates = { id; strategy; candidates }
let id t = t.id
let strategy t = t.strategy
let ordered_candidates t = t.candidates
