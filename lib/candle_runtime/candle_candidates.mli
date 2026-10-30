(** The first half of a payout (RFC-goal-candle-ledger 3.2, step 3; 3.4).

    For each Goal whose payout is waiting, read the Tasks its [Snapshot] linked,
    decide which of them are candidates and which Keepers they name, and write
    that to the ledger as [Candidates] before any model is asked. A Goal with no
    Keeper to pay is finished right there with [Unattributed], without a model
    call. Otherwise the payout stays waiting for the appraiser.

    Nothing is written unless every linked Task reads. A read that fails is
    reported and tried again on the next pass. *)

type outcome =
  | Wrote_candidates of { goal_id : string }
      (** [Candidates] written; a Keeper can be paid, so the appraiser is next. *)
  | Wrote_unattributed of { goal_id : string }
      (** No Keeper can be paid; [Unattributed] closed the payout. *)
  | Already_prepared of { goal_id : string }
      (** [Candidates] was already there and names a Keeper. Nothing written. *)
  | Superseded of { goal_id : string }
      (** The ledger changed while the Tasks were read, so nothing was written. *)
  | Retry_later of { goal_id : string; detail : string }
      (** The payout could not be prepared now. *)

type sources =
  { task_lookups :
      goal_id:string -> string list -> ((string * Candle_event.task_lookup) list, string) result
  ; is_keeper : unit -> (string -> bool, string) result
  }
(** Where the Tasks and the Keepers are read from. *)

val real_sources : Workspace_utils_backend_setup.config -> sources
(** {!Candle_tasks}. *)

val drain_with :
  sources:sources
  -> now:(unit -> float)
  -> base_path:string
  -> (outcome list, string) result
(** One pass over every waiting payout, in the order they were first owed. One
    payout failing does not stop the others. Off or disabled Candle answers
    [Ok []]. [Error] when the ledger cannot be read. *)

val drain_once :
  now:(unit -> float) -> Workspace_utils_backend_setup.config -> (outcome list, string) result
(** {!drain_with} on {!real_sources}. *)
