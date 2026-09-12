(** Runtime lane — ordered list of candidate runtime ids for keeper turn routing.

    A lane is an opaque routing label (the lane id) plus an ordered candidate
    list of runtime ids.  When a keeper assignment resolves to a lane, the
    keeper turn driver resolves each id to a materialized {!Runtime.t} and
    attempts them sequentially until one succeeds or the lane is exhausted.
    Keeping ids here breaks the [Runtime <-> Runtime_lane] module cycle. *)

type t =
  { id : string
  ; candidates : string list
  ; declared_candidates : string list
  }

let make ~id candidates = { id; candidates; declared_candidates = candidates }
let id t = t.id
let ordered_candidates t = t.candidates
let declared_candidates t = t.declared_candidates
(* Ordinary routing appends the workspace default without replacing declared
   order. Exact authority must retain the separate, unwidened candidate view. *)
let with_terminal_default ~runtime_id t =
  if List.mem runtime_id t.candidates then t
  else { t with candidates = t.candidates @ [runtime_id] }
let filter_candidates keep t =
  { t with candidates = List.filter keep t.candidates
  ; declared_candidates = List.filter keep t.declared_candidates }
