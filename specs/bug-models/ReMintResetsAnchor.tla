---- MODULE ReMintResetsAnchor ----
\* Bug Model: producer re-mint resets a volatile claim's grounding anchor
\* (RFC-0259 P6/F false-memory defect).
\*
\* Models the keeper Memory OS volatile-claim grounding lifecycle: an
\* external-ref claim is surfaced by recall as a live truth only while its
\* freshness anchor is within the grounding horizon; once the anchor ages
\* past the horizon the claim is demoted as unverified-volatile (P4). The
\* only legitimate way to refresh the anchor is an external re-grounding by
\* the P2/P3 reconciler. The claim is persistent — this model never removes
\* it, because the reconciler keeps a contradicted ref in place (demote-not-
\* delete, RFC-0259 §3.4); supersedes / delete-on-contradiction is unbuilt.
\*
\* OCaml <-> TLA+ mapping (cited by symbol name, not line number):
\*   spec var / op             | OCaml source
\*   --------------------------+-----------------------------------------------
\*   anchor                    | keeper_memory_os_recall.ml — reference_time
\*                             |   (= last_verified_at, else first_seen)
\*   Horizon                   | keeper_memory_os_reconcile.ml —
\*                             |   default_grounding_horizon_seconds
\*   SurfacedAsLive            | keeper_memory_os_recall.ml —
\*                             |   ~ is_unverified_volatile (recall surfaces a
\*                             |   volatile claim as live iff now - anchor <= Horizon)
\*   ReconcilerGround          | keeper_memory_os_reconcile.ml — Stale_open arm
\*                             |   advancing last_verified_at
\*   (clean) re-mint inherit   | keeper_memory_os_policy.ml — reobserve_fact,
\*                             |   external_ref = Some _ branch returns [existing]
\*                             |   (P6/F: re-mint is NOT re-verification)
\*   ReMintResetsAnchor (bug)  | the pre-P6 "re-observing IS re-verification"
\*                             |   rule applied to a volatile claim
\*
\* Ground-truth ghost variables (no implementation field — that is the point):
\*   genesis    when the claim first entered memory (true age reference).
\*   grounded   whether the CURRENT anchor was set by a real external
\*              re-grounding (reconciler), as opposed to the original
\*              unverified mint or an illegitimate re-mint reset. The row
\*              cannot record this; both writes land in the same anchor
\*              field, which is exactly why the bug is undetectable in-band.
\*
\* Bug Model contract (clean cfg vs buggy cfg):
\*   Clean : re-mint does not touch the anchor (reobserve_fact inherits the
\*           prior row), so an unverified claim's anchor stays at genesis and
\*           ages past Horizon -> recall demotes it.
\*           NoUnverifiedVolatileClaimSurvivesBeyondHorizon HOLDS.
\*   Buggy : ReMintResetsAnchor sets anchor := now on every re-extraction, so
\*           the recall horizon test is never tripped while the true age grows
\*           unbounded. A never-grounded claim is surfaced as live forever.
\*           NoUnverifiedVolatileClaimSurvivesBeyondHorizon MUST be VIOLATED.
\*
\* Out-of-scope (intentionally not modelled): durable (external_ref = None)
\* claims (no decay horizon to reset), claim removal (the reconciler does not
\* delete — §3.4 demote-not-delete), recall scoring, and the librarian's
\* claim_id identity key (orthogonal dedup axis; see
\* keeper_memory_os_types.ml — claim_identity).

EXTENDS Naturals

CONSTANTS
    Horizon,    \* grounding horizon in ticks (default_grounding_horizon_seconds)
    MaxTime     \* clock bound

\* The bug-model contract relies on the true age being able to exceed the
\* horizon while the clock is bounded; fail fast on a mis-set cfg rather than
\* let the buggy cfg silently stop violating.
ASSUME MaxTime > Horizon

VARIABLES
    now,        \* discrete clock
    genesis,    \* ghost: true first-seen time (immutable)
    anchor,     \* reference_time the recall horizon test reads
    grounded    \* ghost: current anchor came from a real re-grounding

vars == << now, genesis, anchor, grounded >>

TypeOK ==
    /\ now \in 0..MaxTime
    /\ genesis \in 0..MaxTime
    /\ anchor \in 0..MaxTime
    /\ grounded \in BOOLEAN

Init ==
    /\ now = 0
    /\ genesis = 0
    /\ anchor = 0          \* unverified mint: anchor = first_seen = genesis
    /\ grounded = FALSE     \* a mint is not a grounding

\* ── Clock ───────────────────────────────────────
Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED << genesis, anchor, grounded >>

\* ── Legitimate external re-grounding (reconciler Stale_open) ──
\* Advances the anchor AND records that the refresh was real.
ReconcilerGround ==
    /\ anchor' = now
    /\ grounded' = TRUE
    /\ UNCHANGED << now, genesis >>

\* ── Bug action: producer re-mint resets the anchor ──
\* A re-extraction of the same self-narrative overwrites the row's freshness
\* reference with [now] while contributing no real verification. grounded is
\* cleared because the new row carries last_verified_at = None.
ReMintResetsAnchor ==
    /\ anchor' = now
    /\ grounded' = FALSE
    /\ UNCHANGED << now, genesis >>

Next == Tick \/ ReconcilerGround

NextBuggy == Next \/ ReMintResetsAnchor

\* WF_vars(Tick) is retained for parity with the sibling bug models and a
\* future liveness extension; it is inert for the INVARIANT-only checks here.
Spec      == Init /\ [][Next]_vars /\ WF_vars(Tick)
SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(Tick)

\* ── Recall surface decision (mirrors is_unverified_volatile) ──
\* A volatile claim is surfaced as a live truth exactly while its anchor is
\* within the grounding horizon. The recall path reads only [anchor]; it
\* cannot see [grounded]. "Not surfaced as live" abstracts the P4 outcome —
\* the claim is demoted (hard "[UNVERIFIED — re-check before acting]" prefix,
\* below durable) rather than literally deleted; see recall.ml render_fact.
SurfacedAsLive == now - anchor <= Horizon

\* Ground truth: an unverified-volatile claim whose true age has already
\* passed the grounding horizon and was never legitimately re-grounded. Such
\* a claim MUST NOT be surfaced as a live truth (P4 demotion).
TrulyStaleUngrounded == ~grounded /\ (now - genesis > Horizon)

\* ── Safety Invariant ────────────────────────────
NoUnverifiedVolatileClaimSurvivesBeyondHorizon ==
    TrulyStaleUngrounded => ~SurfacedAsLive

====
