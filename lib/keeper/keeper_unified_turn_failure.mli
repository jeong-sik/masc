(** Failure-path post-processing for [Keeper_unified_turn]. *)

val max_consecutive_invalid_request_failures : int
(** Consecutive deterministic [InvalidRequest] failures one keeper may absorb
    without crash accounting before the observation degrades to ordinary
    consecutive-failure accounting. *)

val note_invalid_request_failure : base_path:string -> keeper_name:string -> bool
(** Record one deterministic [InvalidRequest] failure for [keeper_name];
    returns [true] once the consecutive count exceeds
    [max_consecutive_invalid_request_failures]. *)

val empty_completion_exemption_budget : int
(** Maximum number of consecutive empty-completion failures exempted from the
    crash counter per keeper before the exemption is exhausted. *)

val transient_transport_exemption_budget : int
(** Maximum number of consecutive network/timeout failures exempted from the
    crash counter per Keeper. Later consecutive failures use ordinary durable
    failure accounting while the Keeper lifecycle remains active. *)

val reset_failure_exemptions : base_path:string -> keeper_name:string -> bool
(** Durably reset the invalid-request and empty-completion budgets and clear
    the process-local transient-transport budget after a successful turn or
    operator context clear. [false] retains every budget and keeps success
    health from hiding the unresolved accounting state. *)

val account_failure_counting
  :  base_path:string
  -> keeper_name:string
  -> is_auto_recoverable:bool
  -> Agent_core.Error.t
  -> bool
(** Compute whether this failure observation advances the crash counter,
    consuming empty-completion, transient-transport, or invalid-request budget
    when applicable. Call exactly once per failure observation, before
    {!record_failure_observation}. *)

val record_failure_observation
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> counts_toward_crash:bool
  -> err:Agent_core.Error.t
  -> error_text:string
  -> unit
(** Record explicit failure evidence without rewriting Keeper lifecycle or
    escalating a numeric streak into pause/crash.
    [counts_toward_crash] must come from {!account_failure_counting} so the
    bounded exemption budgets and the invalid-request consecutive counter are
    each consumed exactly once. *)
