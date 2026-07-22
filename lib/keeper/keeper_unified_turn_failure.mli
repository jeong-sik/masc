(** Failure-path post-processing for [Keeper_unified_turn]. *)

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
    consuming empty-completion exemption budget when applicable.  Call exactly
    once per failure observation, before {!record_failure_observation}. *)

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
    empty-completion exemption budget is consumed exactly once. *)
