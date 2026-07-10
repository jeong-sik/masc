(** Approval_config — declarative policy settings per agent.

    This module defines the shape of the policy overlay that governs
    [Approval_policy.decide] behavior.  It carries {i only} data —
    no I/O.  Loading from TOML (or any other source) happens outside
    lib/exec to keep the sub-library closed to storage concerns.

    The per-agent bag is looked up at decide time; keys are agent
    names (agent identity).  Missing agent keys
    fall through to [defaults]. *)

type trust_level =
  | Observe      (** Allow all in the risk class, log telemetry. *)
  | Suggest      (** Auto-allow with confirmation suggestion telemetry. *)
  | Auto_safe    (** Auto-allow for the given risk class. *)
  | Enforced     (** Strict ask/deny — fail-closed default. *)
(** Progressive trust spectrum.  [Enforced] preserves current strict
    behavior.  Lower levels auto-allow with increasing telemetry. *)

val trust_level_to_string : trust_level -> string

val trust_level_of_string : string -> trust_level option
(** Parse a loose trust-level token.
    Accepted values (case-insensitive):
    - observe, obs
    - suggest, s
    - auto_safe, auto-safe, autosafe, allow
    - enforced, ask, strict, deny. *)

type agent_overlay = {
  safe_trust : trust_level;
  (** Trust level for [Safe] bins ([ls], [cat], [rg]). *)

  audited_trust : trust_level;
  (** Trust level for [Audited] bins ([git], [curl]). *)

  privileged_trust : trust_level;
  (** Trust level for [Privileged] bins ([rm], [sudo]).
      Destructive git ops are handled by the trust-independent catastrophic
      floor, not by this trust level — RFC-0254 §5.3. *)
}
(** Per-agent knobs.  Each risk class has an independent trust level,
    allowing fine-grained escalation without all-or-nothing overrides. *)

type t = {
  defaults : agent_overlay;
  per_agent : (Agent_id.t * agent_overlay) list;
}
(** The whole config.  [per_agent] is an association list rather than
    a hashtable so the whole config can be compared structurally in
    tests.  Lookup is linear but the list is tiny (one entry per
    keeper / worker). *)

val enforced_all : agent_overlay
(** All risk classes at [Enforced].  The safest default. *)

val permissive_default : agent_overlay
(** [safe_trust = Auto_safe], audited/privileged at [Enforced].
    For well-trusted keeper agents in a dev worktree. *)

val agent_overlay_of_profile : string -> agent_overlay option
(** Parse a loose profile token to a complete overlay.
    Accepted values (case-insensitive):
    - autonomous, observe
    - enforced, enforced_all, strict, deny_all, all_enforced
    - permissive, permissive_default, perm
    - suggest
    - auto_safe, auto-safe, autosafe.

    Returns [None] for unknown values. *)

val shell_ir_approval_overlay_of_string : string -> agent_overlay option
(** Parse a single env string to Shell IR overlay.
    Accepted forms:
    - preset profile token (e.g. [autonomous], [permissive])
    - key/value overrides (comma-separated), e.g.
      [safe=observe,audited=enforced,privileged=auto_safe]
    - [profile=permissive,safe=enforced] (profile + overrides).
    A profile must be present either as a bare token or via [profile=].

    Unknown keys or values return [None]. *)

val autonomous : agent_overlay
(** All risk classes at [Observe] (allow + telemetry).  The overlay for an
    autonomous keeper lane, where no human or resolver can answer an [Ask].
    The trust-independent catastrophic floor in [Approval_policy.decide]
    still applies above this overlay — RFC-0254 §5.5. *)

val empty : t
(** [empty] has [defaults = enforced_all] and no per-agent entries.
    Fail-closed bootstrap for CI and new agents. *)

val lookup : t -> actor:Agent_id.t -> agent_overlay
(** [lookup cfg ~actor] returns the per-agent overlay if one is
    registered for [actor]; otherwise [cfg.defaults]. *)
