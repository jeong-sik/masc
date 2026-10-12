(** Per-attempt feedback for provider-refused memory delivery. The runtime
    owns typed refusal and effect-safe retry admission. The producer owns
    whole-record projection, durable receipts and strict size reduction. *)
type reduction = Unchanged | Reprojected
type t = refusal:Agent_core.Error.t -> (reduction, string) result
