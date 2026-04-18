(** A3 — pure decide function from a walked capability list to a
    three-way [Verdict.t].

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
(** Pure policy decision.  The rule cascade (checked top to bottom):

    - [Destructive] git op anywhere in the cap list + overlay deny on →
      [Deny Destructive_git].
    - [Write_path] whose scope is [Outside_worktree] or
      [Absolute_unknown] → [Deny Path_escape].
    - [Exec_bin] on a [Privileged] [Bin.t] (also the unknown-bin path) →
      [Ask].
    - [Exec_bin] on an [Audited] [Bin.t] →
      [Ask] when [overlay.ask_audited], otherwise [Allow].
    - Any construct we explicitly match but do not have a rule for →
      [Ask] (never [Allow]).
    - Otherwise (all-Safe caps under the worktree) →
      [Allow] when [overlay.allow_safe_in_worktree], otherwise [Ask]. *)
