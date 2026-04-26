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

type t =
  { raw_source : string (** original pre-parse string, for the Ask UI *)
  ; summary : string (** human-readable one-liner, for the Ask UI *)
  }

(** Pure policy decision.  The rule cascade (checked top to bottom):

    - [Destructive] git op anywhere in the cap list:
      [Enforced] → [Deny Destructive_git].
      [Auto_safe]/[Observe] → [Allow].
      [Suggest] → [Suggest_confirm].
    - [Write_path] whose scope is [Outside_worktree] or
      [Absolute_unknown] → [Deny Path_escape] (always, regardless of
      trust level).
    - [Exec_bin] on a [Privileged]/[Audited]/[Safe] [Bin.t] →
      dispatch to the corresponding [overlay.*_trust] level:
      [Enforced] → [Ask], [Auto_safe]/[Observe] → [Allow],
      [Suggest] → [Suggest_confirm]. *)
val decide
  :  t
  -> overlay:Approval_config.agent_overlay
  -> caps:Capability.t list
  -> simple:Shell_ir.simple
  -> Verdict.t
