---- MODULE LibrarianRead ----
\* Which atoms a Librarian round reads, against the writers of the turn-boundary
\* log (RFC librarian-lifecycle 4.4 and 4.6; lib/keeper/keeper_librarian_range.ml).
\*
\* A finished Keeper turn appends a line saying where the saved history ended.
\* A round of the Librarian reads the lines, loads the checkpoint, picks the
\* atoms it has not read, and writes back where it got to. The rules must leave
\* no atom behind: a read position may not pass an atom no round delivered.
\*
\* Every atom digest is taken to collide, which is the worst case for the rules
\* that compare a line against the loaded checkpoint (4.4 rows 2a and 5): with
\* one digest, "this line describes the history I loaded" is just
\* end_atom <= atom count, so a line of an older history can pass.
\*
\* An append that fails needs no action of its own: a turn that finished its
\* saves and left no line is the same state as a turn that died after them,
\* which TurnDie already reaches.
\*
\* The clean model is explored to the end, so its state count is the same on
\* every run. A buggy model stops at the first violation, and what a parallel
\* search had explored by then is not: run those with -workers 1 to get the
\* same answer twice. Measured that way, the shortest counterexample is 9
\* steps for the refused line, 12 for the position taken over a restart line,
\* and 9 for the log purged without the read position.
\*
\* Not modelled: how much of what is unread one round takes (row 3a) and which
\* trace the caller reads (row 1b). Neither decides whether an atom is lost --
\* they decide how many rounds it takes and how many rounds stop for nothing.

EXTENDS TLC, Integers, Sequences, FiniteSets

CONSTANTS
    MaxTurns,       \* turns that may start
    MaxSaves,       \* checkpoint saves within one turn
    MaxClears,      \* masc_keeper_clear runs
    MaxBad          \* appends that land as bytes the decoder refuses

ASSUME Bounds ==
    /\ MaxTurns \in Nat /\ MaxTurns >= 1
    /\ MaxSaves \in Nat /\ MaxSaves >= 1
    /\ MaxClears \in Nat
    /\ MaxBad \in Nat

NoTurn == [none |-> TRUE]
NoProgress == [none |-> TRUE]

RestartLine == [kind |-> "HR", fresh |-> FALSE, end |-> 0]
RefusedLine == [kind |-> "BAD", fresh |-> FALSE, end |-> 0]

VARIABLES
    hist,       \* the saved checkpoint: the atom ids it holds, in order
    ckTurns,    \* the turn count the store has, which decides a stale save
    log,        \* the turn-boundary lines, in the order they reached the file
    turn,       \* the running turn, or NoTurn (turns of one keeper are serial)
    progress,   \* the read position [end, seen], or NoProgress
    readIds,    \* atom ids some round delivered to the Librarian
    nextId,
    budget,     \* [turns, clears, bad]
    clearHalf,  \* a clear emptied the history and owes its line
    snap        \* the line count the running round took, or -1 when none runs

vars == << hist, ckTurns, log, turn, progress, readIds, nextId,
           budget, clearHalf, snap >>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* ---------------------------------------------------------------- the rules

\* Row 3d. Two kinds of line say the atoms are numbered from zero again.
IsRestart(l) == l.kind = "HR" \/ (l.kind \in {"TE", "TN"} /\ l.fresh)

\* Row 2a. A line is a place to cut only when it describes the history that was
\* loaded. Every digest collides here, so that is end_atom <= atom count.
IsCut(l, ck) == l.kind = "TE" /\ l.end <= Len(ck)

CutsOf(lines, ck) ==
    { lines[i].end : i \in { j \in 1..Len(lines) : IsCut(lines[j], ck) } }

\* Row 2c. The first line the decoder refuses, or 0.
FirstRefused(lines) ==
    LET refused == { i \in 1..Len(lines) : lines[i].kind = "BAD" }
    IN IF refused = {} THEN 0 ELSE Min(refused)

\* Row 2c'. A restart line after the refused one settles what the refused line
\* could have said: the round starts at atom zero and no start is smaller.
RefusedIsDead(lines, at) ==
    \E i \in (at + 1)..Len(lines) : IsRestart(lines[i])

\* A restart settles the refused lines before it and no others, so the question
\* is asked of each of them, not of the first alone.
FirstBlockingRefused(lines) ==
    LET blocking == { i \in 1..Len(lines) :
                        lines[i].kind = "BAD" /\ ~RefusedIsDead(lines, i) }
    IN IF blocking = {} THEN 0 ELSE Min(blocking)

\* keeper_librarian_range.select. [kind, start, end]; start is exclusive of what
\* is read and end is inclusive, so a round reads atoms start+1 .. end.
\* refusedMode: "block" asks of every refused line, "first" asks only of the
\* first one and lets a later live one through, "drop" ignores them all.
Choose(lines, ck, prog, refusedMode, restartFirst) ==
    LET first == FirstRefused(lines)
        bad == CASE refusedMode = "block" -> FirstBlockingRefused(lines)
                 [] refusedMode = "first" ->
                      IF first # 0 /\ ~RefusedIsDead(lines, first) THEN first ELSE 0
                 [] OTHER -> 0
    IN IF bad # 0
       THEN [kind |-> "stop", start |-> 0, end |-> 0]
       ELSE LET seen  == IF prog = NoProgress THEN 0 ELSE prog.seen
                cuts  == CutsOf(lines, ck)
                back  == \E i \in (seen + 1)..Len(lines) : IsRestart(lines[i])
                \* Row 3c puts the restart line ahead of a position that seems
                \* to match: a digest carries neither an index nor a time, so
                \* the same message at the same place reads as the same history.
                again == back /\ (restartFirst \/ prog = NoProgress
                                  \/ prog.end > Len(ck))
            IN IF again                                              \* row 3c
               THEN IF cuts = {} THEN [kind |-> "nothing", start |-> 0, end |-> 0]
                    ELSE [kind |-> "read", start |-> 0, end |-> Max(cuts)]
               ELSE IF prog = NoProgress                             \* row 3
               THEN IF cuts = {} THEN [kind |-> "nothing", start |-> 0, end |-> 0]
                    ELSE [kind |-> "baseline", start |-> Min(cuts), end |-> Min(cuts)]
               ELSE IF prog.end > Len(ck)                            \* row 5
               THEN [kind |-> "stop", start |-> 0, end |-> 0]
               ELSE LET beyond == { c \in cuts : c > prog.end }       \* row 2
                    IN IF beyond = {}
                       THEN [kind |-> "nothing", start |-> prog.end, end |-> prog.end]
                       ELSE [kind |-> "read", start |-> prog.end, end |-> Max(beyond)]

\* ---------------------------------------------------------------- invariants

TypeOK ==
    /\ ckTurns \in Nat
    /\ nextId \in Nat
    /\ clearHalf \in BOOLEAN
    /\ snap \in -1..MaxTurns * MaxSaves + MaxTurns + MaxClears + MaxBad + 1
    /\ progress = NoProgress \/ (progress.end \in Nat /\ progress.seen \in Nat)

\* The one thing the rules owe: no atom of the saved history is out of reach.
\*
\* A position that sits past an unread atom is not yet a loss. A restart line
\* the position has not counted takes the next round back to atom zero, which
\* reaches it again -- the rules trade a second reading for never losing one
\* (4.4 row 3c). The atom is lost only when the position is past it, no round
\* read it, and no such line is there to go back for.
\*
\* Atoms a clear or a version cut erased before they were read are not counted:
\* their text is gone (4.6), and they are no longer in the history. A history
\* that restarts later erases these atoms rather than delivering them, so a
\* line that has not been written yet cannot save them.
\* It judges only states where the reader is level with the log. A line no
\* round has counted yet means the round has not had its say: it may be about
\* to stop on a refused line, or to go back to atom zero on a restart. A stop
\* writes no progress, so `seen` stays behind and the state stays excused for
\* as long as the stop lasts -- which is what 4.10 describes, an operator-
\* visible halt rather than a loss. What this invariant forbids is a round
\* that had every line in front of it and moved past an atom anyway.
NoAtomPassedUnread ==
    \/ progress = NoProgress
    \/ Len(log) > progress.seen
    \/ \E j \in (progress.seen + 1)..Len(log) : IsRestart(log[j])
    \/ \A i \in 1..Min({progress.end, Len(hist)}) : hist[i] \in readIds

\* ---------------------------------------------------------------- writers

StartTurn(loaded, fresh, tc, blind, line) ==
    /\ budget.turns > 0
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1 \/ snap >= 0   \* a round may be mid-flight; turns do not wait
    /\ turn' = [loaded |-> loaded, fresh |-> fresh, tc |-> tc, mine |-> << >>,
                accepted |-> FALSE, saves |-> 0, blind |-> blind]
    /\ log' = IF line = "none" THEN log
              ELSE IF line = "restart" THEN Append(log, RestartLine)
              ELSE Append(log, RefusedLine)
    /\ budget' = [budget EXCEPT !.turns = @ - 1,
                                !.bad = IF line = "refused" THEN @ - 1 ELSE @]
    /\ UNCHANGED << hist, ckTurns, progress, readIds, nextId, clearHalf, snap >>

\* A turn that starts from no atom and knows the saved history holds none says
\* so before it runs; nothing of its own can be saved ahead of the line.
TurnStart ==
    /\ Len(hist) = 0
    /\ StartTurn(hist, TRUE, ckTurns, FALSE, "restart")

TurnStartRefused ==
    /\ budget.bad > 0
    /\ Len(hist) = 0
    /\ StartTurn(hist, TRUE, ckTurns, FALSE, "refused")

TurnStartContinued ==
    /\ Len(hist) > 0
    /\ StartTurn(hist, FALSE, ckTurns, FALSE, "none")

\* A turn whose checkpoint could not be loaded starts from no atom while the
\* saved history still holds some. It has not seen them, so it says nothing yet.
TurnStartBlind ==
    /\ Len(hist) > 0
    /\ StartTurn(<< >>, TRUE, 0, TRUE, "none")

TurnSave ==
    /\ turn # NoTurn
    /\ turn.saves < MaxSaves
    /\ LET mine  == Append(turn.mine, nextId)
           tc    == turn.tc + 1
           takes == tc >= ckTurns
           first == turn.blind /\ takes /\ ~turn.accepted
       IN /\ hist' = IF takes THEN turn.loaded \o mine ELSE hist
          /\ ckTurns' = IF takes THEN tc ELSE ckTurns
          /\ turn' = [turn EXCEPT !.mine = mine, !.tc = tc,
                                  !.accepted = takes, !.saves = @ + 1]
          \* The save that replaced what was on disk is where an unread turn
          \* says the history restarted: it may die before its own end line.
          /\ log' = IF first THEN Append(log, RestartLine) ELSE log
    /\ nextId' = nextId + 1
    /\ UNCHANGED << progress, readIds, budget, clearHalf, snap >>

\* The same save with its restart line landing as bytes the decoder refuses.
\* This is the append that matters most: it is the only line saying the history
\* on disk was replaced, so a round that does not stop on it reads the new
\* history from an old position.
TurnSaveRefusedRestart ==
    /\ turn # NoTurn
    /\ turn.saves < MaxSaves
    /\ turn.blind
    /\ ~turn.accepted
    /\ budget.bad > 0
    /\ LET mine == Append(turn.mine, nextId)
           tc   == turn.tc + 1
       IN /\ tc >= ckTurns
          /\ hist' = turn.loaded \o mine
          /\ ckTurns' = tc
          /\ turn' = [turn EXCEPT !.mine = mine, !.tc = tc,
                                  !.accepted = TRUE, !.saves = @ + 1]
          /\ log' = Append(log, RefusedLine)
    /\ budget' = [budget EXCEPT !.bad = @ - 1]
    /\ nextId' = nextId + 1
    /\ UNCHANGED << progress, readIds, clearHalf, snap >>

EndLine(t) ==
    LET taken == t.loaded \o t.mine
    IN IF t.accepted /\ Len(taken) > 0
       THEN [kind |-> "TE", fresh |-> t.fresh, end |-> Len(taken)]
       ELSE [kind |-> "TN", fresh |-> t.fresh, end |-> 0]

TurnEnd ==
    /\ turn # NoTurn
    /\ turn.saves > 0
    /\ log' = Append(log, EndLine(turn))
    /\ turn' = NoTurn
    /\ UNCHANGED << hist, ckTurns, progress, readIds, nextId, budget,
                    clearHalf, snap >>

TurnEndRefused ==
    /\ turn # NoTurn
    /\ turn.saves > 0
    /\ budget.bad > 0
    /\ log' = Append(log, RefusedLine)
    /\ turn' = NoTurn
    /\ budget' = [budget EXCEPT !.bad = @ - 1]
    /\ UNCHANGED << hist, ckTurns, progress, readIds, nextId,
                    clearHalf, snap >>

TurnDie ==
    /\ turn # NoTurn
    /\ turn' = NoTurn
    /\ UNCHANGED << hist, ckTurns, log, progress, readIds, nextId,
                    budget, clearHalf, snap >>

\* A clear empties the history and then says so, in two steps, so that a round
\* or a turn can land between them.
ClearSave ==
    /\ budget.clears > 0
    /\ ~clearHalf
    /\ hist' = << >>
    /\ clearHalf' = TRUE
    /\ budget' = [budget EXCEPT !.clears = @ - 1]
    /\ UNCHANGED << ckTurns, log, turn, progress, readIds, nextId, snap >>

ClearLine ==
    /\ clearHalf
    /\ log' = Append(log, RestartLine)
    /\ clearHalf' = FALSE
    /\ UNCHANGED << hist, ckTurns, turn, progress, readIds, nextId,
                    budget, snap >>

\* ---------------------------------------------------------------- the round
\* Two steps, so that a writer can land between the lines a round took and the
\* checkpoint it loads. Which way round matters: the lines must be read first.

RoundSnap ==
    /\ snap = -1
    /\ snap' = Len(log)
    /\ UNCHANGED << hist, ckTurns, log, turn, progress, readIds,
                    nextId, budget, clearHalf >>

Apply(refusedMode, restartFirst) ==
    /\ snap >= 0
    /\ LET lines == SubSeq(log, 1, Min({snap, Len(log)}))
           sel == Choose(lines, hist, progress, refusedMode, restartFirst)
           read == IF sel.kind = "read"
                   THEN { hist[i] : i \in (sel.start + 1)..sel.end }
                   ELSE {}
           moves == sel.kind \in {"read", "baseline"}
       IN /\ readIds' = readIds \cup read
          /\ progress' = IF moves THEN [end |-> sel.end, seen |-> snap] ELSE progress
    /\ snap' = -1
    /\ UNCHANGED << hist, ckTurns, log, turn, nextId, budget, clearHalf >>

RoundApply == Apply("block", TRUE)

\* A round that failed: it delivered nothing, so it moves nothing.
RoundFailed ==
    /\ snap >= 0
    /\ snap' = -1
    /\ UNCHANGED << hist, ckTurns, log, turn, progress, readIds,
                    nextId, budget, clearHalf >>

\* ---------------------------------------------------------------- spec

Init ==
    /\ hist = << >>
    /\ ckTurns = 0
    /\ log = << >>
    /\ turn = NoTurn
    /\ progress = NoProgress
    /\ readIds = {}
    /\ nextId = 1
    /\ budget = [turns |-> MaxTurns, clears |-> MaxClears, bad |-> MaxBad]
    /\ clearHalf = FALSE
    /\ snap = -1

Next ==
    \/ TurnStart \/ TurnStartRefused \/ TurnStartContinued \/ TurnStartBlind
    \/ TurnSave \/ TurnSaveRefusedRestart \/ TurnEnd \/ TurnEndRefused \/ TurnDie
    \/ ClearSave \/ ClearLine
    \/ RoundSnap \/ RoundApply \/ RoundFailed

Spec == Init /\ [][Next]_vars

\* Bug witness 1: a round drops the line the decoder refused instead of standing
\* on it. The refused line may have been the one saying the history restarted,
\* and then the round takes an older line as its baseline and never goes back.
RoundApplyDroppingRefused == Apply("drop", TRUE)

NextBuggy ==
    \/ Next
    \/ RoundApplyDroppingRefused

SpecBuggy == Init /\ [][NextBuggy]_vars

\* A purge removes messages from anywhere in the history, not only from its
\* front, and every atom after the one it took is renumbered. Taking one atom
\* from an arbitrary place covers that: whether the shift starts at the front
\* or in the middle, a position counted against the old numbering names a
\* different atom afterwards.
WithoutAtom(h, j) == SubSeq(h, 1, j - 1) \o SubSeq(h, j + 1, Len(h))

\* Bug witness 4: an offline purge rewrites the history shorter and writes no
\* line (RFC-0351 S1; RFC librarian-lifecycle 10, the second open decision).
\* Dropping the oldest atom renumbers every atom after it, so the position's
\* end_atom names a different atom than the one it was taken from, and a digest
\* carries no index to tell them apart. The recommendation on that decision is
\* to refuse a purge while any turn is unread; this measures what the refusal
\* is worth rather than leaving it as advice.
PurgeTrimKeepingProgress ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ Len(hist) > 1
    /\ \E j \in 1..Len(hist) : hist' = WithoutAtom(hist, j)
    /\ UNCHANGED << ckTurns, log, turn, progress, readIds, nextId, budget,
                    clearHalf, snap >>

NextPurgeTrim ==
    \/ Next
    \/ PurgeTrimKeepingProgress

SpecPurgeTrim == Init /\ [][NextPurgeTrim]_vars

\* Bug witness 5: the same purge under the guard RFC librarian-lifecycle 10
\* recommends for its second open decision -- refuse while a turn is unread,
\* and otherwise make the end of the rewritten history the new baseline. It
\* still loses atoms, in ten steps, because the guard asks about turns while
\* the thing at risk is atoms: a turn that saved and then died leaves atoms
\* that no line ever names, so "no turn is unread" is true while an atom is
\* not. The purge then moves the position over it.
PurgeTrimGuardedByTurns ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ Len(hist) > 1
    /\ progress # NoProgress
    /\ \A c \in CutsOf(log, hist) : c <= progress.end
    /\ \E j \in 1..Len(hist) : hist' = WithoutAtom(hist, j)
    /\ progress' = [end |-> Len(hist) - 1, seen |-> Len(log)]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

NextPurgeTrimGuardedByTurns ==
    \/ Next
    \/ PurgeTrimGuardedByTurns

SpecPurgeTrimGuardedByTurns == Init /\ [][NextPurgeTrimGuardedByTurns]_vars

\* Bug witness 6: the guard stated over atoms -- refuse unless the read
\* position is the end of the history -- with the position rewritten the way
\* the recommendation puts it, counting every line the log now holds. It still
\* loses atoms. The guard is not what fails here: raising the counted lines to
\* the end of the log swallows a restart line no round has taken in, and that
\* line was the one thing that would have sent the next round back to atom
\* zero. A purge may move where a round reads; it may not decide what a round
\* has already seen.
PurgeTrimAtEndCountingLines ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ Len(hist) > 1
    /\ progress # NoProgress
    /\ progress.end = Len(hist)
    /\ \E j \in 1..Len(hist) : hist' = WithoutAtom(hist, j)
    /\ progress' = [end |-> Len(hist) - 1, seen |-> Len(log)]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

NextPurgeTrimAtEndCountingLines ==
    \/ Next
    \/ PurgeTrimAtEndCountingLines

SpecPurgeTrimAtEndCountingLines ==
    Init /\ [][NextPurgeTrimAtEndCountingLines]_vars

\* The guard that does hold: refuse unless the read position is the end of the
\* history being rewritten, and leave the counted lines alone. Then no atom
\* lies beyond the position, the clean rules already say it passed none, and a
\* restart line the position has not counted still sends the next round back to
\* zero -- which re-reads the rewritten history, losing nothing.
\* SpecPurgeTrimAtEnd must NOT violate.
PurgeTrimAtEnd ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ Len(hist) > 1
    /\ progress # NoProgress
    /\ progress.end = Len(hist)
    /\ \E j \in 1..Len(hist) : hist' = WithoutAtom(hist, j)
    /\ progress' = [end |-> Len(hist) - 1, seen |-> progress.seen]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

NextPurgeTrimAtEnd ==
    \/ Next
    \/ PurgeTrimAtEnd

SpecPurgeTrimAtEnd == Init /\ [][NextPurgeTrimAtEnd]_vars

\* Bug witness 3: the turn-boundary file is deleted while the read position that
\* counted its lines is kept. Line numbers start at one again, so a restart line
\* appended after the deletion sits at a number the position has already passed
\* and row 3c never sees it. The purge plan removes the progress file with the
\* boundary file for exactly this reason; this action takes the two apart.
PurgeBoundariesKeepingProgress ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ log # << >>
    /\ log' = << >>
    /\ UNCHANGED << hist, ckTurns, turn, progress, readIds, nextId, budget,
                    clearHalf, snap >>

NextPurgeSplit ==
    \/ Next
    \/ PurgeBoundariesKeepingProgress

SpecPurgeSplit == Init /\ [][NextPurgeSplit]_vars

\* Bug witness 7: the round asks whether the FIRST refused line still matters
\* and, when a restart settles that one, goes on without looking at the rest.
\* A later refused line with no restart after it is then never seen, and it
\* may have been the restart line for the history now on disk. Found in review
\* of the shipped code, which had exactly this shape; the model could not have
\* found it while only one line was ever refused.
RoundApplyFirstRefusedOnly == Apply("first", TRUE)

NextFirstRefusedOnly ==
    \/ Next
    \/ RoundApplyFirstRefusedOnly

SpecFirstRefusedOnly == Init /\ [][NextFirstRefusedOnly]_vars

\* Bug witness 2: a round takes a read position that matches the checkpoint over
\* a restart line it has not counted. The position matches because the digest of
\* the atom at that place is the same, which a replaced history can reproduce.
RoundApplyPositionFirst == Apply("block", FALSE)

NextPositionFirst ==
    \/ Next
    \/ RoundApplyPositionFirst

SpecPositionFirst == Init /\ [][NextPositionFirst]_vars

====
