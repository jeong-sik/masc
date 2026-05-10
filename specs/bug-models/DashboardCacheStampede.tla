---- MODULE DashboardCacheStampede ----
\* Bug Model: Dashboard cache stale-while-revalidate zombie slot.
\*
\* Models lib/dashboard/dashboard_cache.ml:get_or_compute_eio.
\* When a background revalidation fiber is cancelled (Eio.Cancel.Cancelled),
\* the Computing{stale=Some} slot is left orphaned:
\*   - maybe_evict() only targets Ready entries, not Computing
\*   - poll-retry only activates for Computing{stale=None}
\*   - Result: permanent zombie slot returning stale data forever
\*
\* Actual code (verified 2026-04-20):
\*   lib/dashboard/dashboard_cache.ml:60   let maybe_evict map
\*   lib/dashboard/dashboard_cache.ml:219  let get_or_compute_eio
\*   lib/dashboard/dashboard_cache.ml:326  | Eio.Cancel.Cancelled _ -> ...
\*
\* (Path drift: lib/dashboard_cache.ml -> lib/dashboard/dashboard_cache.ml.
\*  Line drift: 265 -> 216 -> 161/262 -> 219/326. Recorded for cross-reference.)

EXTENDS Naturals

CONSTANTS
    MaxFibers   \* Max concurrent request fibers (e.g. 3)

VARIABLES
    slot,           \* "absent" | "fresh" | "stale" | "expired"
                    \* | "computing_fg"       (no stale, foreground)
                    \* | "computing_bg"       (has stale, bg fiber active)
                    \* | "computing_zombie"   (has stale, bg fiber gone)
    active_fibers,  \* Number of fibers currently waiting or computing
    stale_reads     \* Count of reads that got zombie stale data

vars == <<slot, active_fibers, stale_reads>>

TypeOK ==
    /\ slot \in {"absent", "fresh", "stale", "expired",
                 "computing_fg", "computing_bg", "computing_zombie"}
    /\ active_fibers \in 0..MaxFibers
    /\ stale_reads \in 0..99

Init ==
    /\ slot = "absent"
    /\ active_fibers = 0
    /\ stale_reads = 0

\* ── Normal Actions ──────────────────────────────

\* Request on absent/expired -> foreground compute (Computing{stale=None})
RequestMiss ==
    /\ slot \in {"absent", "expired"}
    /\ active_fibers < MaxFibers
    /\ slot' = "computing_fg"
    /\ active_fibers' = active_fibers + 1
    /\ UNCHANGED stale_reads

\* Request on fresh -> hit
RequestFresh ==
    /\ slot = "fresh"
    /\ UNCHANGED vars

\* Request on stale -> return stale, kick bg revalidation
RequestStale ==
    /\ slot = "stale"
    /\ active_fibers < MaxFibers
    /\ slot' = "computing_bg"
    /\ active_fibers' = active_fibers + 1
    /\ UNCHANGED stale_reads

\* Request while bg computing (has stale) -> return stale immediately
RequestDuringBgCompute ==
    /\ slot \in {"computing_bg", "computing_zombie"}
    /\ stale_reads < 99
    /\ stale_reads' = stale_reads + 1
    /\ UNCHANGED <<slot, active_fibers>>

\* Request while fg computing (no stale) -> poll-wait (modeled as noop)
RequestDuringFgCompute ==
    /\ slot = "computing_fg"
    /\ UNCHANGED vars

\* Foreground compute succeeds -> Ready(fresh)
FgComputeSuccess ==
    /\ slot = "computing_fg"
    /\ slot' = "fresh"
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

\* Foreground compute fails -> slot removed (absent)
FgComputeFail ==
    /\ slot = "computing_fg"
    /\ slot' = "absent"
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

\* Background compute succeeds -> Ready(fresh)
BgComputeSuccess ==
    /\ slot = "computing_bg"
    /\ slot' = "fresh"
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

\* Background compute fails -> restore stale with backoff
BgComputeFail ==
    /\ slot = "computing_bg"
    /\ slot' = "stale"
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

\* Background compute CANCELLED -> orphaned zombie slot
\* This is the actual code path: raise Cancelled without cleanup
BgComputeCancel ==
    /\ slot = "computing_bg"
    /\ slot' = "computing_zombie"
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

\* Foreground compute cancelled -> cleanup happens (exception handler)
FgComputeCancel ==
    /\ slot = "computing_fg"
    /\ slot' = "absent"
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

\* Time passes: fresh -> stale -> expired
TimeExpireFresh ==
    /\ slot = "fresh"
    /\ slot' = "stale"
    /\ UNCHANGED <<active_fibers, stale_reads>>

TimeExpireStale ==
    /\ slot = "stale"
    /\ slot' = "expired"
    /\ UNCHANGED <<active_fibers, stale_reads>>

\* Poll-retry eviction of stuck fg compute (max_wait_sec exceeded)
PollEvictFg ==
    /\ slot = "computing_fg"
    /\ slot' = "fresh"   \* cooldown Ready entry
    /\ active_fibers' = active_fibers - 1
    /\ UNCHANGED stale_reads

Next ==
    \/ RequestMiss
    \/ RequestFresh
    \/ RequestStale
    \/ RequestDuringBgCompute
    \/ RequestDuringFgCompute
    \/ FgComputeSuccess
    \/ FgComputeFail
    \/ FgComputeCancel
    \/ BgComputeSuccess
    \/ BgComputeFail
    \/ BgComputeCancel
    \/ TimeExpireFresh
    \/ TimeExpireStale
    \/ PollEvictFg

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariant ────────────────────────────

\* Zombie slots must not persist: any Computing slot must have an active fiber.
\* computing_zombie violates this.
NoZombieSlot ==
    slot # "computing_zombie"

\* ── Bug Model ───────────────────────────────────

\* Clean model: BgComputeCancel is excluded (hypothetical fix: cleanup on cancel).
NextClean ==
    \/ RequestMiss
    \/ RequestFresh
    \/ RequestStale
    \/ RequestDuringBgCompute
    \/ RequestDuringFgCompute
    \/ FgComputeSuccess
    \/ FgComputeFail
    \/ FgComputeCancel
    \/ BgComputeSuccess
    \/ BgComputeFail
    \* BgComputeCancel excluded — fixed version cleans up on cancel
    \/ TimeExpireFresh
    \/ TimeExpireStale
    \/ PollEvictFg

SpecClean == Init /\ [][NextClean]_vars /\ WF_vars(NextClean)

\* Buggy spec includes BgComputeCancel (the actual code behavior)
SpecBuggy == Init /\ [][Next]_vars /\ WF_vars(Next)

====
