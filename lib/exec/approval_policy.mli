(** A3 — pure decide function from a walked capability list to a
    four-way [Verdict.t].

    The policy is intentionally conservative (fail-closed).  Any
    capability it does not recognise maps to [Ask], never to [Allow].

    [decide] is the {i only} call site that may mint a
    [Verdict.Trusted_argv.t] (via [Verdict.trust]).  Downstream code —
    notably the exec gate — refuses anything that is not a
    [Trusted_argv.t], so forgery is rejected at the type level.

    The decision is overlay-aware: the caller supplies the
    per-actor [Approval_config.agent_overlay] chosen for this exec. *)

type t = {
  raw_source : string;  (** original pre-parse string, for the Ask UI *)
  summary : string;     (** human-readable one-liner, for the Ask UI *)
}

val decide :
  t ->
  overlay:Approval_config.agent_overlay ->
  caps:Capability.t list ->
  simple:Shell_ir.simple ->
  Verdict.t
(** Pure policy decision, evaluated in three stages:

    1. Trust-independent catastrophic floor (checked first, denied
       regardless of [overlay] — RFC-0254 §5.3):
       - any [Destructive] git op → [Deny Destructive_git];
       - a redirect [Write_path] whose scope is [Outside_workspace] or
         [Absolute_unknown] → [Deny Path_escape];
       - an irreversible repository-hosting CLI operation ([gh pr merge],
         [gh repo delete], [gh api -X DELETE]) → [Deny
         Destructive_repo_hosting_cli];
       - a catastrophic-by-identity binary (filesystem-format [mkfs], or
         system-power [shutdown]/[reboot]/[halt]/[poweroff]) → [Deny
         Catastrophic_program];
       - a destructive SQL statement ([DROP]/[TRUNCATE]/[DELETE]) handed to a
         database CLI ([psql -c], [mysql -e]) → [Deny Destructive_db].
    2. Otherwise, a [gh repo create] request that lacks the G-10 contract
       ([OWNER/NAME] plus exactly one visibility flag) → [Deny
       (Policy_deny ...)]. Invalid repo-create requests must be corrected before
       HITL; the approval queue only receives explicit ownership/visibility
       metadata.
    3. Otherwise, a [gh] verb whose capability disposition is
       [Requires_approval] → [Ask], independent of the risk overlay. This is
       how reversible durable-remote mutations such as [gh repo create] and
       [gh discussion create] enter HITL rather than auto-running or being
       disabled.
    4. Otherwise the highest program risk class is graded by the matching
       [overlay.*_trust] level:
       [Enforced] → [Ask], [Auto_safe]/[Observe] → [Allow],
       [Suggest] → [Suggest_confirm].

    Destructive git is no longer graded by [privileged_trust]: it lives in
    the floor, so loosening any trust level can never re-enable
    [git push --force].  Path-bearing destructive programs ([rm], [dd], …)
    are graded in stage 2; their target paths are jailed to the workspace by
    [Exec_policy.validate_shell_ir_paths] downstream of this decision. *)

val catastrophic_floor : Capability.t list -> Verdict.deny_reason option
(** Stage 1 of [decide] on its own: [Some reason] for a [Destructive] git op, a
    redirect [Write_path] escaping the workspace, an irreversible
    repository-hosting CLI operation ([gh pr merge], [gh repo delete],
    [gh api -X DELETE]), a catastrophic-by-identity binary
    (filesystem-format [mkfs] or system-power [shutdown]/[reboot]/[halt]/
    [poweroff]), or a destructive SQL statement on a database CLI
    ([psql -c "drop …"]); [None] otherwise.

    Exposed so the always-run dispatch core
    ([Keeper_tool_execute_shell_ir.dispatch_classified]) can enforce the floor
    on every executed command, independent of the
    [MASC_SHELL_IR_APPROVAL_GATE_ENABLED] flag.  The flag gates only the
    trust-overlay grading (stage 2 / the [Ask] approval path); the floor must
    not be flag-gated — RFC-0254 §4 lesson (c) "a catastrophic floor is
    unconditional, independent of mode/allowlist".  For destructive git this
    floor is the {i only} enforcer: force-push has no path argument, so
    [validate_shell_ir_paths] cannot catch it (RFC-0254 §5.4). *)
