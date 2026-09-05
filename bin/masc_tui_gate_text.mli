(** The wording of a durable approval step, drawn from its typed phase. The
    store persists the phase as its own closed sum; this is where the
    sentence lives, and every match on the sum is total. *)

val lifecycle_line :
  phase:Masc.Keeper_chat_store.approval_lifecycle_phase ->
  tool:string option ->
  summary:string option ->
  string
(** [summary] names what the gated call asked for; without it the line names
    only the tool. *)

val fold_line :
  phases:Masc.Keeper_chat_store.approval_lifecycle_phase list ->
  tool:string option ->
  summary:string option ->
  string option
(** One line for a run of steps belonging to the same approval. The run
    collapses to the furthest stage it reached -- replay outcome, else Gate
    resolution, else still waiting -- and within a stage the latest step wins,
    so a replay correction supersedes the row it corrects.
    [Approval_continuation_recorded] rides as a suffix because it says
    something no outcome says. [None] for an empty run. *)
