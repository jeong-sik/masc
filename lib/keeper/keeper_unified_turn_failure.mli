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

val record_failure_observation
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> is_auto_recoverable:bool
  -> err:Agent_sdk.Error.sdk_error
  -> error_text:string
  -> unit
(** Record explicit failure evidence without rewriting Keeper lifecycle or
    escalating a numeric streak into pause/crash. *)
