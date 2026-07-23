(** Failure-path post-processing for [Keeper_unified_turn]. *)

val max_consecutive_invalid_request_failures : int
(** Consecutive deterministic [InvalidRequest] failures one keeper may absorb
    without crash accounting before the observation degrades to ordinary
    consecutive-failure accounting. *)

val note_invalid_request_failure : keeper_name:string -> bool
(** Record one deterministic [InvalidRequest] failure for [keeper_name];
    returns [true] once the consecutive count exceeds
    [max_consecutive_invalid_request_failures]. *)

val reset_invalid_request_failures : keeper_name:string -> unit
(** Clear the consecutive [InvalidRequest] count after a successful turn or
    an operator state clear. *)

val empty_completion_exemption_budget : int
(** Maximum number of consecutive empty-completion failures exempted from the
    crash counter per keeper before the exemption is exhausted. *)

val note_turn_success : string -> unit
(** Reset the keeper's empty-completion exemption budget after a successful
    turn or an operator context clear. *)

val account_failure_counting
  :  keeper_name:string
  -> is_auto_recoverable:bool
  -> Agent_sdk.Error.sdk_error
  -> bool
(** Compute whether this failure observation advances the crash counter,
    consuming empty-completion exemption budget or invalid-request budget
    when applicable.  Call exactly once per failure observation, before
    {!record_failure_observation}. *)

val record_failure_observation
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> counts_toward_crash:bool
  -> err:Agent_sdk.Error.sdk_error
  -> error_text:string
  -> unit
(** Record explicit failure evidence without rewriting Keeper lifecycle or
    escalating a numeric streak into pause/crash.
    [counts_toward_crash] must come from {!account_failure_counting} so the
    empty-completion exemption budget and the invalid-request consecutive
    counter are each consumed exactly once. *)
