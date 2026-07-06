(** Gh_capability_policy — the capability axis for gh verbs (RFC-0309 §3.3, W2).

    RFC-0309 separates three axes that PR #23362 conflated:
    - risk ([Shell_ir_risk]) — is the operation factually reversible?
    - capability policy (THIS module) — may a keeper perform this verb family?
    - disposition wiring (W3) — run / ask a human asynchronously / refuse?

    This module owns the middle axis. It answers "may a keeper do this?" with a
    typed [disposition], distinct from (not overloaded onto) the risk class.
    The defining input of the axis — whether the verb touches a durable remote
    surface ([creates_durable_remote_surface]) — is risk-independent (G-4
    externality).

    W2 scope: this is the policy SSOT. It is NOT yet consulted by the approval
    floor — [Approval_policy.decide] still gates on the catastrophic floor and
    the per-risk-band trust overlay only. W3 (G-7) wires [Requires_approval]
    into the non-blocking HITL queue; until then this module is observability
    and an executable specification of the target policy.

    Ordering note (why [Requires_approval] does not fire for repo-create yet):
    [disposition_of] reads [Shell_ir_risk.risk_of_gh_verb], and PR #23362 still
    places repo-create/fork and the durable discussion mutations in the
    irreversible table (R2), so they resolve to [Denied] here today. Moving them
    to R1 (their true reversibility) is RFC-0309 W4/G-9 and must not land before
    W3's approval wiring, or they would auto-run. The contract test pins both the
    current dispositions and the W4 target. *)

type disposition =
  | Allowed
      (** The keeper may run this autonomously (reads, local reversible
          mutations within an existing repo). *)
  | Requires_approval
      (** The keeper must route this to non-blocking human approval (W3).
          Reserved for reversible mutations that create/mutate a durable remote
          surface, and for unrecognized verbs a human should adjudicate. *)
  | Denied
      (** Never permitted for a keeper. These are also floored on the risk axis
          (R2/Destructive); the capability axis records the policy intent. *)

val string_of_disposition : disposition -> string
(** Stable lowercase label for logs/metrics: "allowed" | "requires_approval" |
    "denied". *)

val creates_durable_remote_surface : Gh_verb.gh_family -> bool
(** G-4 externality axis (risk-independent): [true] for gh families that create
    or mutate a durable remote surface whose ownership, lifecycle, and
    moderation policy are not modeled in keeper tool contracts — [Repo] and
    [Discussion]. [Pr]/[Issue]/[Release]/etc. act within an already-owned repo,
    so [false]. This is the fact that makes repo-create/discussion a capability
    decision rather than an ordinary reversible mutation. *)

val disposition_of : Gh_verb.t -> disposition
(** The capability disposition for a gh verb. Reads
    [Shell_ir_risk.risk_of_gh_verb] as an input (a distinct axis may still
    consult risk):
    - [Gh_verb.Other] (unrecognized area) -> [Requires_approval] (a human
      decides; never silently allowed — the W3 fail-safe);
    - risk R2/Destructive -> [Denied];
    - risk R0 -> [Allowed];
    - risk R1 -> [Requires_approval] if [creates_durable_remote_surface],
      else [Allowed]. *)
