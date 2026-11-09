(** Queue rows that reached a Keeper's queue while one of its turns was running.

    The queue is read when a turn starts. A row that arrives afterwards waits
    for the turn to end, and a turn that runs for hours keeps it waiting for
    hours (docs/rfc/RFC-arrived-stimuli-reach-the-running-turn.md). This module
    picks the rows a later provider round can show and renders them. It opens
    no file and writes nothing: the caller passes the reader, the queue stays
    the only authority, the row stays queued, and it starts its own turn after
    this one ends as before. *)

type row =
  { arrival : int64
    (** The entry number the queue gave the row when it admitted it
        ([Keeper_event_queue_state.pending_selection.arrival]). It names the row
        for as long as the row is queued. *)
  ; urgency : Keeper_event_queue.urgency
  ; arrived_at : float
  ; preview : string
    (** The one-line description the reaction ledger writes for the row. *)
  }

val max_rows_per_round : int
(** How many rows one round lists. A round that finds more lists this many and
    leaves the rest for the next round; no row is dropped. *)

type round =
  { listed : row list  (** Oldest arrival first. *)
  ; later : int  (** Unseen rows this round did not list. *)
  }

val next_round :
  run_started_at:float ->
  shown:int64 list ->
  Keeper_event_queue_state.pending_selection list ->
  round
(** The rows of the queue that arrived after [run_started_at] and whose
    [arrival] is not in [shown]. Rows that arrived before the run began are not
    listed: the turn's first request already carried what the queue held. *)

val render : now:float -> round -> string option
(** The block text, or [None] when nothing is listed. It states how many rows
    arrived and that they stay queued; it gives each row's urgency, age and
    description. *)

(** What one run has already listed. A row counts as listed only once the model
    has answered the request that carried it, so a request that failed before
    the model saw the block lists its rows again on the next round. *)
type tracker

val create_tracker : run_started_at:float -> tracker

val next : tracker -> Keeper_event_queue_state.pending_selection list -> round
(** The round to show now. The rows it lists wait for {!confirm}; asking again
    before then lists them again. *)

val confirm : tracker -> unit
(** The model answered the request that carried the last [next]. Its rows are
    listed for the rest of the run. *)

val block :
  tracker ->
  now:float ->
  read:(unit -> (Keeper_event_queue_state.pending_selection list, string) result) ->
  on_unavailable:(string -> unit) ->
  string option
(** The text a round carries: [read] gives the queue's pending rows, [next]
    picks from them and [render] writes the block. A queue that cannot be read
    gives [None] and calls [on_unavailable] with the reason; the tracker is
    not touched, so the next round lists what this one could not. *)

(** One block for a reader whose blocks can overlap, such as the tool results
    of an official client that runs two tools side by side. {!block} counts the
    rows of its latest round when {!confirm} runs, so a second block asked for
    before that would take over the first one's rows. A claim keeps its own
    rows instead. *)
type claim =
  { round : round  (** The rows [text] lists and the count it leaves for later. *)
  ; text : string
  ; confirm : unit -> unit
    (** The block reached the model. Counts exactly the rows of [round], once
        the caller knows the text was written to the client. A claim that
        never confirms leaves its rows to the next one. *)
  }

val claim :
  tracker ->
  now:float ->
  read:(unit -> (Keeper_event_queue_state.pending_selection list, string) result) ->
  on_unavailable:(string -> unit) ->
  claim option
(** Like {!block}, with the confirmation held by the claim. [None] when nothing
    new is listed or the queue cannot be read ([on_unavailable] is called for
    the second). The tracker's own {!confirm} does not count a claim's rows. *)
