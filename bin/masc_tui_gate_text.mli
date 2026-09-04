(** The wording of a durable approval step, drawn from its typed phase. The
    store persists the phase; this is where the sentence lives. *)

val lifecycle_line :
  phase:string -> tool:string option -> summary:string option -> string
(** A phase this build does not know is named rather than dropped. [summary]
    names what the gated call asked for; without it the line names only the
    tool. *)

val fold_line :
  phases:string list -> tool:string option -> summary:string option ->
  string option
(** One line for a run of steps belonging to the same approval. The run
    collapses to the furthest stage it reached -- replay outcome, else Gate
    resolution, else still waiting -- and within a stage the latest step wins,
    so a replay correction supersedes the row it corrects.
    [continuation_recorded] rides as a suffix because it says something no
    outcome says. [None] for an empty run. *)
