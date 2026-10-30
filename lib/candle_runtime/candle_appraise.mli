(** Settles prepared obligations one Goal at a time. Candidates must already
    be durable before any model request. The injected edge supplies validated
    judgments, never money.
    Concurrent settlement and current Candle availability are rechecked on
    every ledger update decision, including cursor retries. Availability is
    observed before append; external policy-file edits are not locked. *)
type outcome = Settled of string | Superseded of string | Retry_later of { goal_id : string; detail : string } | Rejected of { goal_id : string; detail : string }
val pending : base_path:string -> (Candle_payout.waiting list, string) result
val settle_one : now:(unit -> float) -> appraise:Candle_appraisal.runner -> base_path:string -> Candle_payout.waiting -> outcome
