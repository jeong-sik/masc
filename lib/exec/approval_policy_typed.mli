(** Approval_policy_typed — GADT-based policy decision.

    Bridges the typed IR back to the existing approval policy by
    1. extracting capabilities via [Capability_check_typed],
    2. looking up the agent overlay in [Approval_config],
    3. delegating to [Approval_policy.decide] with the reconstructed
       capability list and the original [Shell_ir.simple].

    The typed command is used for capability extraction; the untyped
    [Shell_ir.simple] is retained so that [Verdict.trust] can mint a
    [Trusted_argv.t] carrying the original env / cwd / redirects. *)

val decide :
  config:Approval_config.t ->
  actor:Agent_id.t ->
  Shell_ir_typed.wrapped ->
  Shell_ir.simple ->
  Verdict.t
