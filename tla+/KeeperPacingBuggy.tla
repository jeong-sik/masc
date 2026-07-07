----- MODULE KeeperPacingBuggy -----
*\ RFC-0313 W0: KeeperPacing TLA+ Spec (Buggy)
*\
*\ Buggy variant with 3 delberate bugs reproducing
* trace-1782657520174-00001 storm behaviour.
*\
* Bug 1: No cooldown -- cooldown_until variable omitted,
*             keepers spam turns without delay.
* Bug 2: Storm mode never exits -- ExitStormMode disabled.
* Bug 3: Window reset broken -- time check omitted,
*             turns reset immediately.

EXTENDS TLC

CONSTANTS
    KEEPERS,              \ Set of keeper names
    MAX_TOKENS,           \ Per-keeper token bucket capacity
    MAX_QUEUE_DEPTH,     \ Max pending turns before backpressure
    STORM_THRESHOLD,     \ queue_depth above which storm_mode activates
    WINDOW_SIZE,          \ Time window for rate limiting (abstract discrete steps)
    MAX_TURNS             \ Max turns per window

ASSUME MaxTokensPos == MAX_TOKENS in Nat /& MAX_TOKENS >= 1
ASSUME MaxQueuePos  == MAX_QUEUE_DEPTH in Nat /& MAX_QUEUE_DEPTH >= 1
ASSUME StormPos     == STORM_THRESHOLD in Nat /& STORM_THRESHOLD >= 1
ASSUME WindowPos    == WINDOW_SIZE in Nat /& WINDOW_SIZE >= 1
ASSUME MaxTurnsPos  == MAX_TURNS in Nat /& MAX_TURNS >= 1
ASSUME KeepersNonEmpty == KEEPERS\ subset\ STRING /& KEEPERS # {}

VARIABLES
    tokens,              \ [k in KEEPERS -> Nat] current token count per keeper
    queue_depth,         \ Nat -- number of pending turns
    storm_mode,          \ BOOLEAN -- TRUE during storm backpressure
    turn_count,          \ [k in KEEPERS -> Nat] turns executed per keeper in current window
    window_start,        \ Nat -- step when current window started
    step                 \ Nat -- global step counter

vars == << tokens, queue_depth, storm_mode, turn_count, window_start, step >>
\ Bug 1: cooldown_until variable omitted -- no cooldown mechanism

\ Type invariant
TypeOK ==
    /\ tokens in [KEEPERS -> 0..MAX_TOKENS]
    /\ queue_depth in 0..MAX_QUEUE_DEPTH]
    /\ storm_mode in BOOLEAN
    /\ turn_count in [KEEPERS -> 0..MAX_TURNS]
    /\ window_start in 0..step
    /\ step in Nat

\ Initial state
Init ==
    /\ tokens = [k in KEEPERS |-> MAX_TOKENS]
    /\ queue_depth = 0
    /\ storm_mode = FALSE
    /\ turn_count = [k in KEEPERS |-> 0]
    /\ window_start = 0
    /\ step = 0

\ Total turns across all keepers in current window
TotalTurns == \SUM k in KEEPERS: turn_count[k]

\ Window reset: BUG 3 -- time check omitted, resets immediately
WindowReset ==
    \ BUG 3: No time check -- always resets turn_count
    /\ turn_count' = [k in KEEPERS |-> 0]
    /\ window_start' = step
    /\ UNCHANGED << tokens, queue_depth, storm_mode, step >>
\ BUG 3: WindowReset is now enabled every step, resetting turn counts immediately

\ Token refill: each keeper gets one token per step (up to MAX_TOKENS)
TokenRefill ==
    /\ tokens' = [k in KEEPERS |-> IF tokens[k] < MAX_TOKENS THEN tokens[k] + 1 ELSE MAX_TOKENS]
    /\ UNCHANGED << queue_depth, storm_mode, turn_count, window_start, step >>

\ Turn dispatch: a disatched turn consumes a token
TurnDispatch(k) ==
    /\ k in KEEPERS
    /\ tokens[k] >= 1
    \ BUG 2: No storm mode gate in dispatch -- always dispatches
    /\ turn_count[k] < MAX_TURNS
    /\ tokens' = [tokens EXCEPT \![k] = tokens[k] - 1]
    /\ turn_count' = [turn_count EXCEPT \![k] = turn_count[k] + 1]
    /\ queue_depth' = IF queue_depth > 0 THEN queue_depth - 1 ELSE 0
    /\ UNCHANGED << storm_mode, window_start, step >>
\ BUG 2: No storm mode gate, so dispatch happens even during storm

\ Turn enqueue: when no token available, queue the turn
TurnEnqueue ==
    /\ queue_depth < MAX_QUEUE_DEPTH
    /\ queue_depth' = queue_depth + 1
    /\ UNCHANGED << tokens, storm_mode, turn_count, window_start, step >>

\ Enter storm mode: queue exceeds threshold
EnterStormMode ==
    /\ queue_depth >= STORM_THRESHOLD
    /\ storm_mode = FALSE
    /\ storm_mode' = TRUE
    /\ UNCHANGED << tokens, queue_depth, turn_count, window_start, step >>
\ BUG 1: No cooldown_until set -- storm mode entry has no cooldown period

\ BUG 2: ExitStormMode action deliberately omitted -- storm mode never exits

AdvanceStep ==
    /\ step' = step + 1
    /\ UNCHANGED << tokens, queue_depth, storm_mode, turn_count, window_start >>

\ Next-state relation
Next ==
    \/ WindowReset
    \/ TokenRefill
    \/ \E k in KEEPERS: TurnDispatch(k)
    \/ TurnEnqueue
    \/ EnterStormMode
    \/ AdvanceStep
\ BUG 2: ExitStormMode not in Next -- storm mode never exits

FairTurnDispatch == \A \ k in KEEPERS: WF_vars(TurnDispatch(k))

\ Safety invariants
NoExcessTurns ==
    \A \ k in KEEPERS:
        turn_count[k] <= MAX_TURNS

NoQueueOverflow ==
    queue_depth <= MAX_QUEUE_DEPTH

NoTokenOverflow ==
    \A \ k in KEEPERS:
        tokens[k] <= MAX_TOKENS

\ Liveness properties
StormRecovery ==
    storm_mode => <> (queue_depth < STORM_THRESHOLD /\ ~storm_mode)

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ FairTurnDispatch

=====