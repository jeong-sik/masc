(** A read-only view of the facts recorded for one Goal. Current configuration,
    ledger observations and model execution are independent: this view cannot
    infer a model result, or historical payment, from an absent ledger row. *)

type configuration = Enabled | Off | Disabled
type unavailable = Locked | Unreadable | Invalid_row
type snapshot = Snapshot_matching | Snapshot_missing | Snapshot_conflicting
type stage = Candidates_unrecorded | Candidates_consistent | Candidates_inconsistent | Candidates_unchecked
type hold_origin = Stored | Derived_candidates
type issue_observation = Complete_issues of Candle_payout.window_issue list
  | Snapshot_independent_issues of Candle_payout.window_issue list | Issues_unavailable
(** [Complete_issues] covers the recorded Task observations against the
    applicable time window. It does not by itself establish that historical
    Candidates cover every linked Task or that their candidate sets agree. *)
type unattributed_reason = No_candidates | All_unrelated | No_related_keepers | Window_released

type identity = { request_id : string; verification_run_id : string }
type allocation = { keeper : string; weight : int; amount_milli : int }

type payout =
  | No_recorded_obligation
  | Owed of { identity : identity; snapshot : snapshot; stage : stage }
  | Held of
      { identity : identity
      ; snapshot : snapshot
      ; origin : hold_origin
      ; issues : issue_observation
      }
  | Paid of { identity : identity; recorded_at : Candle_time.t; allocations : allocation list }
  | Unattributed of { identity : identity; recorded_at : Candle_time.t; reason : unattributed_reason }
  | Payout_failed of { identity : identity }
  | Inconsistent

type ledger = Missing | Unavailable of unavailable | Observed of payout
type t = { configuration : configuration; ledger : ledger }

val project : goal_id:string -> Candle_event.t list -> payout
(** Interpret a validated ledger view without reading or writing external state. *)

val to_yojson : goal_id:string -> t -> Yojson.Safe.t
(** An execution result is [not_observed]: the ledger does not index every
    original model request and cannot prove whether one was dispatched. *)

val of_yojson : goal_id:string -> Yojson.Safe.t -> (t, string) result
(** Requires the exact schema, Goal identity and complete closed observation. *)
