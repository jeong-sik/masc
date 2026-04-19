(** Approval_config — declarative policy settings per agent.

    This module defines the shape of the policy overlay that governs
    [Approval_policy.decide] behavior.  It carries {i only} data —
    no I/O.  Loading from TOML (or any other source) happens outside
    lib/exec to keep the sub-library closed to storage concerns.

    The per-agent bag is looked up at decide time; keys are agent
    names matching [Approval_context.t.actor].  Missing agent keys
    fall through to [defaults]. *)

type agent_overlay = {
  allow_safe_in_worktree : bool;
  (** If true, Safe bins whose write caps stay [Inside_worktree] or
      [Inside_sandbox] short-circuit to [Verdict.Allow] without asking.
      Set false for strict agents that should Ask even on Safe bins. *)

  ask_audited : bool;
  (** If true, [Audited] bins produce [Verdict.Ask].
      If false, they produce [Verdict.Allow] (for experienced agents
      the operator has granted broader trust). *)

  deny_destructive_git : bool;
  (** If true, [Git_op.Destructive _] emits [Verdict.Deny] outright.
      If false, the hard deny is removed and the command falls through
      to the normal risk-class rules.  Default true; a future operator
      UI may flip this per-session for planned history rewrites. *)
}
(** Per-agent knobs.  Intentionally narrow — add fields only when a
    policy rule actually reads them, not "for future flexibility". *)

type t = {
  defaults : agent_overlay;
  per_agent : (string * agent_overlay) list;
}
(** The whole config.  [per_agent] is an association list rather than
    a hashtable so the whole config can be compared structurally in
    tests.  Lookup is linear but the list is tiny (one entry per
    keeper / worker). *)

val strict_default : agent_overlay
(** Strictest possible overlay: never allows Safe in worktree, always
    asks on Audited, always denies Destructive git.  The safe landing
    pad for agents we have not yet profiled. *)

val permissive_default : agent_overlay
(** Conventional default for well-trusted keeper agents in a dev
    worktree.  [allow_safe_in_worktree = true], [ask_audited = true],
    [deny_destructive_git = true]. *)

val empty : t
(** [empty] has [defaults = strict_default] and no per-agent entries.
    Fail-closed bootstrap for CI and new agents. *)

val lookup : t -> actor:string -> agent_overlay
(** [lookup cfg ~actor] returns the per-agent overlay if one is
    registered for [actor]; otherwise [cfg.defaults]. *)
