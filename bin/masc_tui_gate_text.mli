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

type folded_argument =
  { fa_text : string  (** The line as drawn, folded or not. *)
  ; fa_held_cells : int
        (** Cells behind the fold, zero when nothing was folded. The caller
            needs this to know whether the row has anything to open; deciding
            it by comparing [fa_text] against the input would read the newline
            flattening as a fold. *)
  }

val fold_argument : cap:int -> string -> folded_argument
(** One Gate line held to [cap] terminal cells, with what it is holding named
    in cells rather than rows.

    A Gate row ends in the argument the gated call asked for and nothing caps
    it; one base64 argument took eight rows of the pane. Compact folds it,
    Ctrl-D unfolds it -- so what is out of sight is still reachable, which a
    truncation would not be.

    Cells, not rows, because how many rows this becomes is decided later, by
    the layout, at a width this function is not given. A row count named here
    would be a guess printed as a fact. A line already inside [cap] comes back
    with its newlines flattened and nothing else changed. *)
