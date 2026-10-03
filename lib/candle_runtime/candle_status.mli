(** Configuration availability and synchronization of the ledger's half-life.
    [current] owns the existing first-use recovery; [current_view] never repairs
    or truncates a ledger. A failed policy publication disables the view. *)

type prepared = private {
  events : Candle_event.t list;
  policy_events : Candle_event.t list;
  balance : Candle_balance.t;
}
val prepare : at:Candle_time.t -> half_life:Candle_decay.half_life ->
  Candle_event.t list -> (prepared, Candle_balance.error) result
(** Validate all historical money and policy facts before preparing a policy
    change. [policy_events] is empty for an unchanged policy, otherwise the one
    required policy fact. Callers append it with their own operation under CAS. *)

type view = private {
  policy : Candle_config.policy;
  at : Candle_time.t;
  events : Candle_event.t list;
  balance : Candle_balance.t;
}
type error =
  | Off
  | Disabled of string
  | Invalid_time of string
  | Invalid_ledger of Candle_balance.error
  | Ledger_unavailable of string
val error_to_string : error -> string
val observed_view : now:(unit -> float) -> base_path:string -> (view, error) result
(** Read-only ledger observation. Amounts use only recorded half-life boundaries;
    the desired config policy is available for the catalog but takes monetary
    effect only when an authorized writer publishes its boundary. Never appends,
    repairs, or truncates the ledger. *)

val current_view : now:(unit -> float) -> base_path:string -> (view, error) result
(** One immutable current view. Configuration and trusted clock are observed
    again on each CAS attempt. The desired half-life is published before the
    returned amounts are accepted; failure returns no usable balance. *)

val configured : base_path:string -> Candle_config.t
(** Current configuration and appraiser availability only. Does not recover,
    truncate or otherwise change the ledger. Read and purchase surfaces use
    this before their authoritative ledger read. *)

val current : base_path:string -> Candle_config.t
(** Goal control availability and first-use recovery only. A live writer lock
    retains Enabled so Snapshot/Owed's own CAS refuses the transition instead
    of silently skipping its mandatory record. This is not a monetary view. *)
val for_recording : base_path:string -> Candle_config.t
(** Configuration and ledger recovery for durable Snapshot and PayoutOwed
    facts. An unavailable appraiser postpones settlement without discarding
    these facts. Configuration and recovery failures retain the same
    Off/Disabled semantics as {!current}. Each append still acquires its lock. *)

val report_at_start : base_path:string -> unit
val install_appraiser_check : (unit -> (unit, string) result) -> unit
