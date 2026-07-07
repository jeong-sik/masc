----- MODULE KeeperPacing -----
\ RFC-0313 W0: KeeperPacing TLA+ Spec (Clean)
*\
*\ Models keeper turn pacing with token-bucket rate limiting,
* queue depth management, and storm-mode recovery.
\ Runtime truth being modelled: lib/keeper/keeper_pacing.ml implements the token bucket, lib/keeper/keeper_scheduler.ml drains the queue.
\ Bug Model: clean spec holds all invariants; buggy spec reproduces trace-1782657520174-00001 storm behaviour.

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
    storm_mode,          \ BOOLEAN -- TRUE when storm backpressure active
    cooldown_until,     \ Nat -- step at which storm cooldown ends
    turn_count,          \ [k in KEEPERS -> Nat] turns executed per keeper in current window
    window_start,        \ Nat -- step when current window started
    step                 \ Nat -- global step counter

vars == << tokens, queue_depth, storm_mode, cooldown_until, turn_count, window_start, step >>

\ Type invariant
TypeOK ==
    /\ tokens in [KEEPERS -> 0..MAX_TOKENS]
    /\ queue_depth in 0..MAX_QUEUE_DEPTH]
    /\ storm_mode in BOOLEAN
    /\ cooldown_until in Nat
    /\ turn_count in [KEEPERS -> 0..MAX_TURNS]
    /\ window_start in 0..step
    /\ step in Nat

\ Initial state
Init ==
    /\ tokens = [k in KEEPERS |-> MAX_TOKENS]
    /\ queue_depth = 0
    /\ storm_mode = FALSE
    /\ cooldown_until = 0
    /\ turn_count = [k in KEEPERS |-> 0]
    /\ window_start = 0
    /\ step = 0

\ Total turns across all keepers in current window
TotalTurns == \SUM k in KEEPERS: turn_count[k]

\ Window reset: when step - window_start >= WINDOW_SIZE, reset counters
WindowReset ==
    /\ step - window_start >= WINDOW_SIZE
    /\ turn_count' = [k in KEEPERS |-> 0]
    /\ window_start' = step
    /\ UNCHANGED << tokens, queue_depth, storm_mode, cooldown_until, step >>
\ Token refill: each keeper gets one token per step (up to MAX_TOKENS)
TokenRefill ==
    /\ tokens' = [k in KEEPERS |-> IF tokens[k] < MAX_TOKENS THEN tokens[k] + 1 ELSE MAX_TOKENS]
    /\ UNCHANGED << queue_depth, storm_mode, cooldown_until, turn_count, window_start, step >>

\ Turn dispatch: a keeper consumes a token and executes a turn
TurnDispatch(k) ==
    /\ k in KEEPERS
    \ Must have a token
    /\ tokens[k] >= 1
    \ In storm mode, only dispatch if queue is draining
    /\ ~storm_mode \/ queue_depth < STORM_THRESHOLD
    \ Must not exceed max turns per window
    /\ turn_count[k] < MAX_TURNS
    /\ tokens' = [tokens EXCEPT \![k] = tokens[k] - 1]
    /\ turn_count' = [turn_count EXCEPT \![k] = turn_count[k] + 1]
    /\ queue_depth' = IF queue_depth > 0 THEN queue_depth - 1 ELSE 0
    /\ UNCHANGED << storm_mode, cooldown_until, window_start, step >>

\ Turn enqueue: when no token available, queue the turn
TurnEnqueue ==
    /\ queue_depth < MAX_QUEUE_DEPTH]
    /\ queue_depth' = queue_depth + 1
    /\ UNCHANGED << tokens, storm_mode, cooldown_until, turn_count, window_start, step >>

\ Enter storm mode: queue exceeds threshold
EnterStormMode ==
    /\ queue_depth >= STORM_THRESHOLD
    /\ storm_mode = FALSE
    /\ storm_mode' = TRUE
    /\ cooldown_until' = step + WINDOW_SIZE
    /\ UNCHANGED << tokens, queue_depth, turn_count, window_start, step >>

\ Exit storm mode: queue drained and cooldown elapsed
ExitStormMode ==
    /\ storm_mode = TRUE
    /\ queue_depth < STORM_THRESHOLD
    /\ step >= cooldown_until
    /\ storm_mode' = FALSE
    /\ UNCHANGED << tokens, queue_depth, cooldown_until, turn_count, window_start, step >>

\ Step advance
AdvanceStep ==
    /\ step' = step + 1
    /\ UNCHANGED << tokens, queue_depth, storm_mode, coolddown_until, turn_count, window_start >>

\ Next-state relation
Next ==
    \/ WindowReset
    \/ TokenRefill
    \/ \E k in KEEPERS: TurnDispatch(k)
    \/ TurnEnqueue
    \/ EnterStormMode
    \/ ExitStormMode
    \/ AdvanceStep

\ Fairness
FairTurnDispatch == \A \ k in KEEPERS: WF_vars(TurnDispatch(k))
FairStormExit == WF_vars(ExitStormMode)

\ Safety invariants
NoExcessTurns ==
    \A \ k in KEEPERS:
        turn_count[k] <= MAX_TURNS

NoQueueOverflow ==
    queue_depth <= MAX_QUEUE_DEPTH )

NoTokenOverflow ==
    \A \ k in KEEPERS:
        tokens[k] <= MAX_TOKENS

\ Liveness properties
StormRecovery ==
    storm_mode => <> (queue_depth < STORM_THRESHOLD /\ ~storm_mode)

WorkProgress ==
    (queue_depth > 0) => <> (\E k in KEEPERS: turn_count[k] > 0)

\ Temporal specification
Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ FairTurnDispatch
    /\ FairStormExit

=====