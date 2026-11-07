(** Releasing a held candidate window (RFC-0513).

    The operator decision is one row, [Candidate_window_released], naming the
    open hold's Goal, request and verifier run. The append is admitted under
    the same rules the ledger enforces for every row. The next payout pass
    re-decides the payout from a fresh observation; a window that stays
    ambiguous closes [Unattributed] with [Window_released] instead of holding
    again. *)

type outcome =
  | Released of { goal_id : string }
      (** The release row was appended. *)
  | Not_waiting of { goal_id : string }
      (** The Goal's payout is settled or failed; nothing is held. *)
  | Not_held of { goal_id : string }
      (** The payout is waiting but holds no candidate window. *)
  | Unknown_goal of { goal_id : string }
      (** No payout obligation names this Goal. *)
  | Superseded of { goal_id : string }
      (** The ledger changed while the release was appended; read again. *)

val release :
  now:(unit -> float)
  -> config:Workspace_utils_backend_setup.config
  -> goal_id:string
  -> (outcome, string) result
(** Appends the release row for [goal_id]'s open hold. [Error] when the ledger
    cannot be read or the row cannot be written. *)
