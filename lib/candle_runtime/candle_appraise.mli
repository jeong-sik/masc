(** Drains prepared obligations. Candidates must already be durable before any
    model request. The injected edge supplies validated judgments, never money.
    Concurrent settlement is rechecked in the ledger's atomic update. *)
type outcome = Settled of string | Superseded of string | Retry_later of { goal_id : string; detail : string } | Rejected of { goal_id : string; detail : string }
val drain_once : now:(unit -> float) -> appraise:Candle_appraisal.runner
  -> base_path:string -> (outcome list, string) result

val pending : base_path:string -> (Candle_payout.waiting list, string) result
val settle_one : now:(unit -> float) -> appraise:Candle_appraisal.runner -> base_path:string -> Candle_payout.waiting -> outcome
