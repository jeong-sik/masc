(** One immutable authoritative view for a whole response. Reading replays recorded
    half-life boundaries without publishing policy, repairing or truncating rows. *)
type t
val read : now:(unit -> float) -> base_path:string -> t
val summary : t -> Candle_observation.t
val balance : t -> keeper:string -> string option
val equipment : t -> keeper:string -> (Keeper_portrait_look.equipment, string) result
(** Stable digest of the Keeper's durable paid/purchased/equipped facts,
    historical half-life boundaries, configured half-life, ownership and current
    catalog prices, or of a Disabled reason. Pure wall-clock decay preserves
    this revision; real relevant facts or policy changes invalidate it. Off has
    no account revision. *)
val account_revision : t -> keeper:string -> string option
val ready_account_revision : events:Candle_event.t list -> policy:Candle_config.policy -> balance:Candle_balance.t -> keeper:string -> string
(** The same durable account identity, for a response derived from one current
    view's events, policy and balance without rereading its policy or ledger.
    The balance supplies canonical ownership; its clock-derived wallet amount
    is deliberately excluded from the revision. *)
val disabled_account_revision : string -> string
(** The same Disabled identity for its exact observed reason. *)
