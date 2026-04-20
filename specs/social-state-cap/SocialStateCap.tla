------------------------------ MODULE SocialStateCap ------------------------------
(* TLA+ spec for the keeper social_state narrative-field cap chain.

   Models the bound established by PR #7692 (Gen8), #7704 (Gen12), and
   #7709 (Gen13). For every speech model and every entry channel, the
   emitted social_state must satisfy:

     |belief_summary|        <= BeliefCap
     |active_desire|         <= OptionCap
     |current_intention|     <= OptionCap
     |blocker|               <= OptionCap
     |need|                  <= OptionCap

   Bug Model pattern (feedback_tla-spec-audit-outcome-trichotomy):
     Clean cfg: CapHolds + PreservesEnum must both pass
     Buggy cfg: CapHolds MUST be violated — otherwise the invariant
                is too weak to catch a cap-free emission path.
*)

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    BeliefCap,    \* default 400
    OptionCap,    \* default 200
    MaxRaw,       \* largest input field length (e.g. 1000)
    Turns         \* number of turns to model (e.g. 3)

VARIABLES
    state,        \* record {belief, desire, intention, blocker, need, speech, surface}
    turn,         \* integer in 0..Turns
    pc            \* "run" | "done"

vars == <<state, turn, pc>>

\* ── Enum domains ────────────────────────────
\*
\* OCaml ↔ TLA+ mapping (verified 2026-04-20, see issue #9065):
\*
\*   spec name in Speeches  ↔ keeper_social_model_types.mli speech_act
\*   ----------------------+----------------------------------------------
\*   "stay_silent"          ↔ Stay_silent
\*   "inform"               ↔ Inform
\*   "request_help"         ↔ Request_help
\*   "claim_task"           ↔ Claim_task
\*   (NOT MODELLED)         ↔ Comment_board, Post_board, Broadcast, Defer
\*
\*   spec name in Surfaces  ↔ keeper_social_model_types.mli delivery_surface
\*   ----------------------+----------------------------------------------
\*   "silent"               ↔ Silent
\*   "visible_reply"        ↔ Visible_reply
\*   "board_post"           ↔ Board_post
\*   "task_claim"           ↔ Task_claim_surface
\*   (NOT MODELLED)         ↔ Board_comment, Broadcast_surface
\*
\* Sound partial coverage rationale:
\*   The cap chain (PR #7692/#7704/#7709) is enforced at a SINGLE
\*   emission point — `Types.cap_social_state` called from
\*   keeper_social_model_magentic_ledger_v1.ml lines 200 and 220
\*   (every emission path goes through it). Because that match is
\*   exhaustive over the OCaml type, all 8 speech_act / 6 delivery_surface
\*   constructors are capped uniformly regardless of which 4 the spec
\*   chose to enumerate. The 4×4 projection here verifies the cap math
\*   itself; unmodelled values are safe by construction (same emission
\*   path, same cap_social_state call).
\*
\*   What this projection does NOT catch: a future change that adds
\*   a new emission site that bypasses cap_social_state. If that happens
\*   the spec must be extended to include the new constructors AND the
\*   new emission action. See issue #9065 option 3 (witness pattern in
\*   keeper_social_model_types.ml) for a compile-time guard.
Speeches == {"stay_silent", "inform", "request_help", "claim_task"}
Surfaces == {"silent", "visible_reply", "board_post", "task_claim"}

\* ── Cap primitive ──────────────────────────

\* Minimum preserves Idempotence: capped twice == capped once.
Cap(n, bound) == IF n <= bound THEN n ELSE bound

\* ── Clean emission: bounded by construction ─

EmitClean(raw) ==
    [ belief     |-> Cap(raw.belief,    BeliefCap),
      desire     |-> Cap(raw.desire,    OptionCap),
      intention  |-> Cap(raw.intention, OptionCap),
      blocker    |-> Cap(raw.blocker,   OptionCap),
      need       |-> Cap(raw.need,      OptionCap),
      speech     |-> raw.speech,
      surface    |-> raw.surface ]

\* ── Buggy emission: caps belief only, forgets option fields ─

EmitBuggy(raw) ==
    [ belief     |-> Cap(raw.belief,    BeliefCap),
      desire     |-> raw.desire,
      intention  |-> raw.intention,
      blocker    |-> raw.blocker,
      need       |-> raw.need,
      speech     |-> raw.speech,
      surface    |-> raw.surface ]

\* ── Arbitrary raw input per turn ─

\* Finite reduction: model each numeric field by a representative
\* size from each regime (below cap / at cap / above cap / much
\* above cap). Keeps the state space tractable while covering
\* every meaningful branch of Cap.
BeliefSizes == {0, 1, BeliefCap, BeliefCap + 1, MaxRaw}
OptionSizes == {0, 1, OptionCap, OptionCap + 1, MaxRaw}

RawInputs ==
    [ belief:    BeliefSizes,
      desire:    OptionSizes,
      intention: OptionSizes,
      blocker:   OptionSizes,
      need:      OptionSizes,
      speech:    Speeches,
      surface:   Surfaces ]

InitialState ==
    [ belief |-> 0, desire |-> 0, intention |-> 0,
      blocker |-> 0, need |-> 0,
      speech |-> "stay_silent", surface |-> "silent" ]

\* ── Init ───────────────────────────────────

Init ==
    /\ state = InitialState
    /\ turn = 0
    /\ pc = "run"

\* ── Next (clean): each turn emits a new state from arbitrary raw input ─

StepClean ==
    /\ pc = "run"
    /\ turn < Turns
    /\ \E raw \in RawInputs:
        state' = EmitClean(raw)
    /\ turn' = turn + 1
    /\ pc' = IF turn + 1 = Turns THEN "done" ELSE "run"

\* ── Next (buggy): same but uses EmitBuggy ─

StepBuggy ==
    /\ pc = "run"
    /\ turn < Turns
    /\ \E raw \in RawInputs:
        state' = EmitBuggy(raw)
    /\ turn' = turn + 1
    /\ pc' = IF turn + 1 = Turns THEN "done" ELSE "run"

NextClean == StepClean \/ (pc = "done" /\ UNCHANGED vars)
NextBuggy == StepBuggy \/ (pc = "done" /\ UNCHANGED vars)

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ─────────────────────

CapHolds ==
    /\ state.belief    <= BeliefCap
    /\ state.desire    <= OptionCap
    /\ state.intention <= OptionCap
    /\ state.blocker   <= OptionCap
    /\ state.need      <= OptionCap

PreservesEnum ==
    /\ state.speech  \in Speeches
    /\ state.surface \in Surfaces

\* ── Liveness ───────────────────────────────

Terminates == <>(pc = "done")

================================================================================
