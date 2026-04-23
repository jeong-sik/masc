(** Approval_config — declarative policy settings per agent.

    This module defines the shape of the policy overlay that governs
    [Approval_policy.decide] behavior.  It carries {i only} data —
    no I/O.  Loading from TOML (or any other source) happens outside
    lib/exec to keep the sub-library closed to storage concerns.

    The per-agent bag is looked up at decide time; keys are agent
    names matching [Approval_context.t.actor].  Missing agent keys
    fall through to [defaults]. *)

type trust_level =
  | Observe      (** Allow all in the risk class, log telemetry. *)
  | Suggest      (** Auto-allow with confirmation suggestion telemetry. *)
  | Auto_safe    (** Auto-allow for the given risk class. *)
  | Enforced     (** Strict ask/deny — fail-closed default. *)
(** Progressive trust spectrum.  [Enforced] preserves current strict
    behavior.  Lower levels auto-allow with increasing telemetry. *)

val trust_level_to_string : trust_level -> string

type agent_overlay = {
  safe_trust : trust_level;
  (** Trust level for [Safe] bins ([ls], [cat], [rg]). *)

  audited_trust : trust_level;
  (** Trust level for [Audited] bins ([git], [curl]). *)

  privileged_trust : trust_level;
  (** Trust level for [Privileged] bins ([rm], [sudo]).
      Also governs destructive git ops. *)
}
(** Per-agent knobs.  Each risk class has an independent trust level,
    allowing fine-grained escalation without all-or-nothing overrides. *)

type t = {
  defaults : agent_overlay;
  per_agent : (string * agent_overlay) list;
}
(** The whole config.  [per_agent] is an association list rather than
    a hashtable so the whole config can be compared structurally in
    tests.  Lookup is linear but the list is tiny (one entry per
    keeper / worker). *)

val enforced_all : agent_overlay
(** All risk classes at [Enforced].  The safest default. *)

val strict_default : agent_overlay
(** Alias for [enforced_all].  Backward-compatible name. *)

val permissive_default : agent_overlay
(** [safe_trust = Auto_safe], audited/privileged at [Enforced].
    For well-trusted keeper agents in a dev worktree. *)

val empty : t
(** [empty] has [defaults = strict_default] and no per-agent entries.
    Fail-closed bootstrap for CI and new agents. *)

val lookup : t -> actor:string -> agent_overlay
(** [lookup cfg ~actor] returns the per-agent overlay if one is
    registered for [actor]; otherwise [cfg.defaults]. *)
