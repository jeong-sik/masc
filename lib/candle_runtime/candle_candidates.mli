(** The first half of a payout (RFC-goal-candle-ledger 3.2, step 3; 3.4).

    For each Goal whose payout is waiting, read the Tasks its [Snapshot] linked,
    decide which of them are candidates and which Keepers they name, and write
    that to the ledger as [Candidates] before any model is asked. A Goal with no
    Keeper to pay is finished right there with [Unattributed], without a model
    call. Otherwise the payout stays waiting for the appraiser.

    Candidate decisions require every linked Task to read. When a partial read
    observes a boundary ambiguity, the known facts and unknown entries are
    retained as a hold; a missing Task alone is retried on the next pass. *)

type outcome =
  | Wrote_candidates of { goal_id : string }
      (** [Candidates] written; a Keeper can be paid, so the appraiser is next. *)
  | Wrote_unattributed of { goal_id : string }
      (** No Keeper can be paid; [Unattributed] closed the payout. *)
  | Already_prepared of { goal_id : string }
      (** [Candidates] was already there and names a Keeper. Nothing written. *)
  | Superseded of { goal_id : string }
      (** The ledger changed while the Tasks were read, so nothing was written. *)
  | Held_window of { goal_id : string; issues : Candle_payout.window_issue list; recorded : bool }
      (** The payout cannot decide a complete candidate set from the retained
          observation. [recorded] is true only when this pass wrote the hold.
          No appraisal or terminal payout should be started. *)
  | Waiting_task of { goal_id : string; issues : Candle_payout.window_issue list }
      (** Task sources did not yield a complete observation. A later read can
          recover; no candidate set or terminal payout is written. *)
  | Retry_later of { goal_id : string; detail : string }
      (** The payout could not be prepared now. *)

type sources =
  { task_lookups :
      goal_id:string -> string list -> ((string * Candle_event.task_lookup) list, string) result
  ; is_keeper : unit -> (string -> bool, string) result
  }
(** Where the Tasks and the Keepers are read from. *)

val drain_with :
  sources:sources
  -> now:(unit -> float)
  -> config:Workspace_utils_backend_setup.config
  -> (outcome list, string) result
(** One pass over every waiting payout, in the order they were first owed. One
    payout failing does not stop the others. Off, invalid configuration or
    unavailable initial ledger recovery answers [Ok []]. An unavailable
    appraiser does not prevent retaining Task observations. A new observation
    and its single ledger append attempt run under the backlog lease fence.
    [Error] when the recovered ledger cannot be read. *)

val drain_once :
  now:(unit -> float) -> Workspace_utils_backend_setup.config -> (outcome list, string) result
(** {!drain_with} with the Tasks and the Keepers read through
    {!Candle_tasks}. *)
