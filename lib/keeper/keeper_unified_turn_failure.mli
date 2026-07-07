(** Failure-path post-processing for [Keeper_unified_turn]. *)

val record_failure_and_maybe_escalate
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> updated_meta:Keeper_meta_contract.keeper_meta
  -> is_auto_recoverable:bool
  -> pacing_enforced:bool
  -> err:Agent_sdk.Error.sdk_error
  -> error_text:string
  -> unit
(** [pacing_enforced] is the RFC-0313 W3 mode, read once by the caller
    (production wires [Keeper_pacing_shadow.pacing_enforced ()]).  When
    [true] (default runtime config), the three legacy auto-pause flags are
    inert — the failure is expressed as pacing plus a judgment stimulus at
    the routing site; when [false] (shadow kill-switch, removed in W4), the
    legacy [paused=true] writes run. *)
