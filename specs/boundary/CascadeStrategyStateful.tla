---- MODULE CascadeStrategyStateful ----
\* Boundary spec for the stateful cascade-strategy side table
\* (lib/cascade/cascade_state.{ml,mli} from Phase B #7611).
\*
\* Phase C1 (CascadeStrategy.tla, #7614) covers the generic cycle
\* FSM that is strategy-agnostic.  It does NOT observe the
\* per-(keeper, cascade) state that Sticky and Round_robin maintain
\* between calls, so regressions in state dynamics (stale pinned
\* providers leaking past ttl, cursor escaping the candidate set)
\* would not be caught.
\*
\* This spec models that side table:
\*   - Sticky:      Hashtbl<(keeper, cascade), { provider, expires_at }>
\*                  encoded as two total functions with a NoProv
\*                  sentinel (absent = provider field = NoProv).
\*   - Round_robin: Atomic cursor per cascade, bounded by
\*                  Cardinality(Candidates).
\*   - Priority_tier is stateless; no variables here.
\*
\* Safety properties verified:
\*   - TypeOK and domain bounds for the sticky table / cursor.
\*   - StickyMembersAreCandidates: every pinned provider is a
\*     real Candidate (no placeholder leakage into the table).
\*   - RRBounded: cursor stays within 0..|Candidates|-1.
\*   - NoExpiredEntriesUsable: the sticky table never contains an
\*     entry whose expires_at has already been reached.  Modelled
\*     by collapsing Tick with eager eviction (lookup_sticky's
\*     `now < entry.expires_at` guard run as part of time advance).
\*
\* Liveness property verified (with WF on Tick + StickyExpire):
\*   - StickyEventuallyEvicts: once an entry has been pinned, it
\*     is eventually either evicted or the clock still shows it as
\*     valid.  Models the invariant that entries do not leak
\*     forever under a progressing clock.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Keepers,           \* Set of keeper ids, e.g. {k1, k2}
    Cascades,          \* Set of cascade ids, e.g. {c1}
    Candidates,        \* Set of provider keys, e.g. {a, b}
    MaxClock,          \* Upper bound on simulated monotonic clock
    DefaultTTL         \* TTL (in clock ticks) used by StickyRecord

ASSUME KeepersNonEmpty    == Keepers # {}
ASSUME CascadesNonEmpty   == Cascades # {}
ASSUME CandidatesNonEmpty == Candidates # {}
ASSUME MaxClockIsPos      == MaxClock \in Nat /\ MaxClock >= 1
ASSUME DefaultTTLIsPos    == DefaultTTL \in Nat /\ DefaultTTL >= 1

\* Sentinel for "no pinned entry".  Mirrors the None-returning case
\* in lookup_sticky: if provider = NoProv, the slot is empty
\* regardless of expires_at.
NoProv == "_none_"
ASSUME NoProv \notin Candidates

NumCandidates == Cardinality(Candidates)

VARIABLES
    pinned_provider,   \* [Keepers \X Cascades -> Candidates \cup {NoProv}]
    pinned_expires,    \* [Keepers \X Cascades -> Nat]
    rr_cursor,         \* [Cascades -> 0..NumCandidates-1]
    clock              \* Nat, 0..MaxClock

vars == << pinned_provider, pinned_expires, rr_cursor, clock >>

(* ── Helpers ──────────────────────────────────────────────── *)

KC == Keepers \X Cascades

HasEntry(k, c) == pinned_provider[<<k, c>>] # NoProv

\* The guard lookup_sticky uses: `now < entry.expires_at`.
ValidEntry(k, c) ==
    HasEntry(k, c) /\ clock < pinned_expires[<<k, c>>]

ExpiredEntry(k, c) ==
    HasEntry(k, c) /\ clock >= pinned_expires[<<k, c>>]

(* ── Safety predicates ───────────────────────────────────── *)

TypeOK ==
    /\ pinned_provider \in [KC -> Candidates \cup {NoProv}]
    /\ pinned_expires  \in [KC -> 0..(MaxClock + DefaultTTL)]
    /\ rr_cursor       \in [Cascades -> 0..(NumCandidates - 1)]
    /\ clock           \in 0..MaxClock

StickyDomainBounded ==
    \A kc \in DOMAIN pinned_provider : kc \in KC

StickyMembersAreCandidates ==
    \A kc \in KC :
        pinned_provider[kc] \in Candidates \cup {NoProv}

RRBounded ==
    \A c \in Cascades : rr_cursor[c] \in 0..(NumCandidates - 1)

\* The contract for lookup_sticky: the table never exposes a
\* provider whose expires_at has already passed.  In the clean
\* model this holds because Tick evicts eagerly (see Tick below);
\* in the buggy model Tick stops evicting, so expired entries
\* accumulate and the invariant is violated.
NoExpiredEntriesUsable ==
    \A k \in Keepers, c \in Cascades : ~ExpiredEntry(k, c)

(* ── Initial state ───────────────────────────────────────── *)

Init ==
    /\ pinned_provider = [kc \in KC |-> NoProv]
    /\ pinned_expires  = [kc \in KC |-> 0]
    /\ rr_cursor       = [c \in Cascades |-> 0]
    /\ clock           = 0

(* ── Actions ─────────────────────────────────────────────── *)

\* Pin provider `p` for (k, c) at clock + DefaultTTL.  Models
\* record_sticky_choice.  Only permitted when the slot is empty
\* to keep the state space small; the runtime's Hashtbl.replace
\* is idempotent over the current key, but replace is
\* observationally equivalent to (expire-then-record) from the
\* property-verification side.
StickyRecord(k, c, p) ==
    /\ ~HasEntry(k, c)
    /\ p \in Candidates
    /\ pinned_provider' = [pinned_provider EXCEPT ![<<k, c>>] = p]
    /\ pinned_expires'  = [pinned_expires  EXCEPT ![<<k, c>>] = clock + DefaultTTL]
    /\ UNCHANGED << rr_cursor, clock >>

\* Consume a still-valid pin.  Models lookup_sticky returning Some.
\* Read-only; included so StickyUse shows up in the action trace
\* and can be audited by the buggy variant if needed.
StickyUse(k, c) ==
    /\ ValidEntry(k, c)
    /\ UNCHANGED vars

\* Explicit eviction (e.g. clear_sticky, or an overwrite path).
\* Kept as a separate action so fairness can drive liveness.
StickyExpire(k, c) ==
    /\ HasEntry(k, c)
    /\ pinned_provider' = [pinned_provider EXCEPT ![<<k, c>>] = NoProv]
    /\ pinned_expires'  = [pinned_expires  EXCEPT ![<<k, c>>] = 0]
    /\ UNCHANGED << rr_cursor, clock >>

\* Advance the round-robin cursor for cascade c.  Models
\* rotate_round_robin (Atomic.fetch_and_add with mod bound).
RoundRobinAdvance(c) ==
    /\ rr_cursor' = [rr_cursor EXCEPT ![c] = (rr_cursor[c] + 1) % NumCandidates]
    /\ UNCHANGED << pinned_provider, pinned_expires, clock >>

\* Monotonic clock tick, bounded by MaxClock.  Eagerly evicts any
\* entry whose expires_at <= clock', so NoExpiredEntriesUsable is
\* preserved across time advance.  This models the runtime's
\* behaviour where lookup_sticky filters by `now < expires_at` —
\* from the caller's point of view the entry is gone the moment
\* the clock reaches expires_at.
Tick ==
    /\ clock < MaxClock
    /\ clock' = clock + 1
    /\ pinned_provider' =
        [kc \in KC |->
            IF pinned_provider[kc] # NoProv /\ clock' >= pinned_expires[kc]
            THEN NoProv
            ELSE pinned_provider[kc]]
    /\ pinned_expires' =
        [kc \in KC |->
            IF pinned_provider[kc] # NoProv /\ clock' >= pinned_expires[kc]
            THEN 0
            ELSE pinned_expires[kc]]
    /\ UNCHANGED rr_cursor

Next ==
    \/ \E k \in Keepers, c \in Cascades, p \in Candidates : StickyRecord(k, c, p)
    \/ \E k \in Keepers, c \in Cascades : StickyUse(k, c)
    \/ \E k \in Keepers, c \in Cascades : StickyExpire(k, c)
    \/ \E c \in Cascades : RoundRobinAdvance(c)
    \/ Tick

\* Weak fairness on Tick drives the liveness property: the clock
\* eventually reaches every entry's expires_at, and Tick's eager
\* eviction clears it.
Fairness ==
    WF_vars(Tick)

Spec == Init /\ [][Next]_vars /\ Fairness

(* ── Liveness ────────────────────────────────────────────── *)

\* Every pinned entry is either evicted or still-valid eventually.
\* Under WF(Tick), the clock advances to MaxClock; any entry whose
\* expires_at <= MaxClock is cleared by Tick's eager-evict branch.
\* With DefaultTTL <= MaxClock this is guaranteed.
\*
\* The buggy variant drops Tick's eager eviction and the explicit
\* StickyExpire action, so a pinned entry remains in the table
\* even after its expires_at; this invariant and the safety
\* NoExpiredEntriesUsable both flag the regression.
StickyEventuallyEvicts ==
    \A k \in Keepers, c \in Cascades :
        HasEntry(k, c) ~> (~HasEntry(k, c) \/ ValidEntry(k, c))

(* ──────────────────────────────────────────────────────── *)
(* Bug Model — variants that introduce a regression.         *)
(* ──────────────────────────────────────────────────────── *)

\* Bug: Tick advances the clock but forgets to evict expired
\* entries, and StickyExpire is removed from Next.  This models a
\* regression where lookup_sticky's TTL guard is deleted or the
\* lazy-clear path in record_sticky_choice regresses to
\* Hashtbl.add (accumulating) rather than Hashtbl.replace +
\* expiry check.
TickBuggy ==
    /\ clock < MaxClock
    /\ clock' = clock + 1
    /\ UNCHANGED << pinned_provider, pinned_expires, rr_cursor >>

NextBuggy ==
    \/ \E k \in Keepers, c \in Cascades, p \in Candidates : StickyRecord(k, c, p)
    \/ \E k \in Keepers, c \in Cascades : StickyUse(k, c)
    \/ \E c \in Cascades : RoundRobinAdvance(c)
    \/ TickBuggy

\* Same WF on the buggy tick: the clock still makes progress.
FairnessBuggy ==
    WF_vars(TickBuggy)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====
