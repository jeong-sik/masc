--------------------------- MODULE LibrarianWriter ---------------------------
(***************************************************************************)
(* The Librarian writer of one Keeper: the state machine, boot, the commit *)
(* of one line, the operator acts, the alerts and the writer registry.     *)
(* It stands for the RFC "Librarian call only proposes and one writer per  *)
(* Keeper commits in one line": section 8.6 (boot) with 8.7 (Adopt),       *)
(* section 9 (the state machine: its rules, its table, who sends an event) *)
(* and section 12 (what the operator sees: the row and the alerts).        *)
(*                                                                         *)
(* What is modelled                                                        *)
(*  - The commit log (one line per commit: basis, after, cause, position), *)
(*    the Memory snapshot, the lock, the turn log as a row of units.       *)
(*  - The writer: Booting, Idle, Asking, Resting, Refused_at_bottom (RaB), *)
(*    Stopped with its reason, Retired; "Absent" is no writer at all.      *)
(*  - Boot. No commit log is a first boot whatever the turn log holds:     *)
(*    Started at the start of the turn log. A tail line that does not      *)
(*    parse is Stopped Log_unreadable. The Keeper never waits for its      *)
(*    writer: turns close in every writer state, and a Write sent during a *)
(*    boot waits in the mailbox until the boot ends.                       *)
(*  - The registry. One function, ensure, makes a writer in Booting when   *)
(*    the Keeper is registered and has no live writer. Its callers are the *)
(*    Turn_closed hint, the Write path, view and the pulse. The pulse      *)
(*    sends Retire to a live writer whose Keeper is not registered.        *)
(*  - Adopt. In Log_diverged it appends an Adopt line at the last line's   *)
(*    position. In Log_unreadable it appends Started at the start of the   *)
(*    turn log: with no known position, reading starts at the start.       *)
(*  - The asks (a range, one item alone, Make_room), their results, the    *)
(*    reader's faults, Skip_item, Skip_line, Restart_reading, Resume, a    *)
(*    declaration change, a crash at each point of a commit.               *)
(*  - The alerts E1 to E5 and W1 as functions of the writer's memory.      *)
(*                                                                         *)
(* Old rules are kept as constants so that a cfg can show what each one    *)
(* breaks: Maker ("launcher": a launch path makes the writer and one path  *)
(* forgets), AdoptPos ("end"), BootSplit ("turnline", "unit"), KeeperRule, *)
(* SkipEmptiesLast (FALSE), Reader, E4Rule, E5Rule, ForeignLane, and Bug.  *)
(* RetireRule and ReadMark: the RFC's rule is "checks_registry" (a writer  *)
(* drops a Retire while its Keeper is registered) and "not_running" (a     *)
(* read is marked while Booting or with no writer). "always" and "booting" *)
(* are the old rules; RefusedRetiredOnlyAfterUnregister and                *)
(* UnmarkedReadIsChecked fail under them.                                  *)
(*                                                                         *)
(* Properties                                                              *)
(*  Chain                 basis of a line is the after of the line before. *)
(*  SnapshotLag           the snapshot is at most one line behind the log. *)
(*  PositionMoves         only a read, a skip or a restart moves the       *)
(*                        position; ranges are contiguous.                 *)
(*  PositionHasLine       the position in memory is the tail line's.       *)
(*  PassedAccounted       every unit the position passed is named in a     *)
(*                        read or a skip line. No exception for Adopt.     *)
(*  AnswerAtMostOnce      an answer is committed at most once.             *)
(*  AnswerOnlyWhenCurrent only the current ask's answer is committed.      *)
(*  NoUndoRetract         an answer never adds back a fact retracted after *)
(*                        its question was built.                          *)
(*  AdoptOnlyAfterLostLog Stopped Log_unreadable needs a tail line that    *)
(*                        stopped parsing.                                 *)
(*  AdoptOnlyInTwoStops   Adopt writes only in Log_diverged and            *)
(*                        Log_unreadable.                                  *)
(*  OnlyStartedWhileBooting  boot writes no line but Started.              *)
(*  KeeperNeverWaits      no writer state holds the Keeper's turns back.   *)
(*  OneLiveWriter         the registry never pushes a live writer out.     *)
(*  RegisteredHasWriter   a Keeper that stays registered gets a live       *)
(*                        writer (pulse fairness).                         *)
(*  RegisteredWriteReachesAWriter  a Write for a registered Keeper never   *)
(*                        finds a Retired writer and no new one.           *)
(*  UnregisteredNotRead   a Keeper that is not registered and whose writer *)
(*                        is gone has no writer until it is registered.    *)
(*  BootingReadFlagged    a Memory read during a boot is marked, and its   *)
(*                        snapshot is at most one commit behind.           *)
(*  QueuedWriteEnds       a Write that waits for a boot does not wait for  *)
(*                        ever.                                            *)
(*  ReadsAllOnceRunning   once the writer keeps running, everything is     *)
(*                        read with no operator act.                       *)
(*  NoSilentPark          something unread and nothing in flight means an  *)
(*                        alert is on.                                     *)
(*  E3OnHeadLine          E3 never stands on a line the position passed.   *)
(*  EveryAskEnds          the writer does not sit on one ask for ever.     *)
(*                                                                         *)
(* Not modelled                                                            *)
(*  - Memory is a set of fact names; what a model call adds is any subset. *)
(*  - The turn log is a row of units with a kind each: no bytes, no        *)
(*    bundles, no sweep, no marks. The turn-log model covers those.        *)
(*  - One Keeper. The registry is one flag and one writer record.          *)
(*  - Slots are not modelled by key. The width memory has its own model;  *)
(*    the size facts per slot at one item are not modelled.                *)
(*  - A view read and a Memory read are not steps: their answers are       *)
(*    functions of the state.                                              *)
(*  - A refused operator act changes nothing, so it is not a step.         *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
  Facts, MaxTurns, Lanes, Reread, Bug, MaxAskNo,
  KeeperRule, BootSplit, AdoptPos, Ghosts, Reader, E4Rule, E5Rule, RoomEmptied, ForeignLane,
  OddKinds, SameLenReplace, ResetWhileDown, ResetKinds, OpenedStep, LoseHint, Settle,
  MaxCrash, MaxWrite, MaxDecl, MaxForeign, MaxRest, MaxRefuse, MaxInput, MaxAllNot, MaxFail,
  MaxIo, MaxHold, MaxPulse, MaxResume, MaxSkip, MaxSkipLine, MaxRestart, MaxAdopt, MaxRetire,
  MaxBadSnap, MaxLock, MaxLose, MaxLoseAlive, MaxBreakLog, MaxRepairLog, MaxReplace, MaxCut, MaxOdd, MaxNone, MaxReset,
  Maker, RetireRule, ReadMark, SkipEmptiesLast, MaxReg, MaxUnreg

VARIABLES
  log, snap, snapBad, lockFree, dpos,  \* the Memory stores: commit log (<< >> = absent), snapshot, "does not decode", the lock, (bug only) a separate position file
  tid, closed, kinds, op,              \* the turn log: its id, how many units it holds, the kind of each, an Opened with no Closed after it
  m, keeperUp,                         \* writer memory; the Keeper has started (turns may close)
  fibers, mailbox, hint,               \* ask fibers, their Ask_ended messages, a pending Turn_closed
  held,                                \* backpressure holds every slot of the lane
  c, lost,                             \* counters that bound the environment, and ghosts; ghost: the commit log was deleted once
  reg                                  \* the Keeper registry holds this Keeper

vars == << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, c, lost, reg >>
Env8 == << snapBad, lockFree, tid, closed, kinds, op, held, lost, reg >>

Q(l) == l \div 10
GhostBit == IF Ghosts THEN 1 ELSE 0            \* a ghost flag is raised only when the cfg reads ghosts
HasLog == log # << >>
Last == log[Len(log)]
Running == {"Idle", "Asking", "Resting", "RaB"}
States == Running \cup {"Booting", "Stopped", "Retired", "Absent"}
Live == m.state \notin {"Absent", "Retired"}       \* the registry holds a writer that is not Retired
EnsureOn == Maker = "ensure"

IsItem(k) == k \in {"item", "ritem"}
IsNone(k) == k \in {"none", "rnone"}
IsSpan(k) == k \in {"span", "rspan"}
IsTurnUnit(k) == k \in {"item", "none", "bad", "span", "missing"}     \* written by a turn's line writer: an Opened or a Closed line stands with it
HasTurnLine == op \/ \E i \in 1..closed : IsTurnUnit(kinds[i])
LooksLost == CASE BootSplit = "unit" -> closed # 0          \* the turn log holds a unit
               [] BootSplit = "turnline" -> HasTurnLine    \* an Opened or a Closed line
               [] OTHER -> FALSE                           \* no commit log is never read as a lost one

FileLen == IF SameLenReplace THEN closed ELSE << tid, closed, op >>
NoLen == IF SameLenReplace THEN 0 - 1 ELSE << 0, 0, FALSE >>

Line(b, a, cause, from, p, tl, gid, added, gret, cur, clean) ==
  [basis |-> b, after |-> a, cause |-> cause, from |-> from, pos |-> p, tl |-> tl,
   gid |-> gid, added |-> added, gret |-> gret, cur |-> cur, clean |-> clean, bad |-> FALSE]

(* Boot empties last, last_room, read_alone, narrowing and bottom.
   A writer is created with the lane value. *)
FreshMem(l) ==
  [state |-> "Booting", stop |-> "none", facts |-> {}, pos |-> 0, tl |-> 0, askNo |-> 0, asked |-> "none",
   rs |-> {}, lane |-> l, askLane |-> 0,
   last |-> "none", lastOne |-> FALSE, lastSil |-> FALSE, lastBasis |-> {},
   room |-> "none", roomMem |-> {}, roomLane |-> 0,
   alone |-> FALSE, bottom |-> FALSE, seen |-> NoLen, stopEnd |-> 0,
   retq |-> FALSE, lastPos |-> 0, lastTl |-> 0]
NoWriter(l) == [FreshMem(l) EXCEPT !.state = "Absent"]
NewProc(l) == IF EnsureOn THEN NoWriter(l) ELSE FreshMem(l)     \* process start: no writer until the first ensure (the old rule: a launcher made it)
(* ensure makes a writer: none is live and the Keeper is registered. "ensure_any" forgets the registry. *)
MakesWriter == EnsureOn /\ ~Live /\ (reg \/ Bug = "ensure_any")
Remade(made) == IF made /\ m.state = "Retired" THEN 1 ELSE c.remade

Init ==
  /\ log = << >> /\ snap = {} /\ snapBad = FALSE /\ lockFree = TRUE /\ dpos = 0
  /\ tid = 1 /\ closed = 0 /\ kinds = << >> /\ op = FALSE
  /\ m = NewProc(CHOOSE l \in Lanes : Q(l) # 0) /\ keeperUp = (KeeperRule = "never") /\ reg = TRUE
  /\ fibers = {} /\ mailbox = {} /\ hint = FALSE /\ held = FALSE /\ lost = FALSE
  /\ c = [gid |-> 0, crash |-> 0, write |-> 0, decl |-> 0, foreign |-> 0, rest |-> 0, refuse |-> 0,
          input |-> 0, allnot |-> 0, fail |-> 0, io |-> 0, hold |-> 0, pulse |-> 0, resume |-> 0,
          skip |-> 0, skipline |-> 0, restart |-> 0, adopt |-> 0, retire |-> 0, badsnap |-> 0,
          lock |-> 0, lose |-> 0, losealive |-> 0, breaklog |-> 0, repairlog |-> 0, replace |-> 0, cut |-> 0,
          odd |-> 0, none |-> 0,
          reset |-> 0, refact |-> 0,
          \* ghosts
          chain |-> 0,          \* asks started one after another with no pulse, no commit and no outside event between
          fl |-> 0,           \* how often a result on a lane that is no longer held went to the next ask
          gl |-> "oth",         \* the last current result: "ref" every slot refused or sized, "sil" a slot was silent, "noout" no slot declared now had an outcome
          started |-> 0,        \* a Started line was written once
          fbstop |-> 0,         \* a first boot stopped once
          rdmax |-> 0,          \* the highest unit a read commit has covered in this turn log
          again |-> 0,          \* 1: a unit written by the reset function was read a second time; 2: a unit written by a turn was
          cov |-> {},           \* the units of this turn log that a read or a skip line has covered
          ungone |-> 0,         \* a unit that no read or skip line covered left the turn log (replaced or cut)
          early |-> 0,          \* the highest unit closed before any Started line was ever written
          tb |-> 0, ts |-> 0,   \* a turn closed while the writer was Booting / Stopped
          tloss |-> {},         \* the Memory the commit log last recorded when it was deleted
          retr |-> {},          \* facts a direct write retracted and no line added again since
          rloss |-> {},         \* `retr` when the commit log was deleted
          rnl |-> 0,            \* the turn log was replaced while no commit log had ever been written
          wqr |-> 0,            \* a Write that waited for the boot was refused
          stale |-> 0,          \* Adopt left Log_unreadable although the tail line parsed again
          regs |-> 0, unreg |-> 0,   \* bounds: Register, Unregister
          wra |-> 0,            \* a Write for a registered Keeper found no live writer and was refused Keeper_retired
          wrr |-> 0,            \* a Write sent while the Keeper was registered, and not unregistered since, was refused Keeper_retired
          saw |-> {},           \* (bug) ensure callers that looked, found no writer and have not inserted yet
          orphans |-> 0,        \* (bug) a live writer was pushed out of the registry by a second one
          remade |-> 0,         \* a writer was made in place of a Retired one
          wnew |-> 0,           \* a Write was committed by a writer made after a Retire, the Keeper registered again
          wun |-> 0,            \* a Write was committed while the Keeper was not registered
          off |-> 0,            \* the Keeper is not registered and its writer is gone (cleared by Register)
          sef |-> 0]            \* an operator skip was sent while `last` was a fault or a failure

(* ---- the reader's view of the unread lines, shared by the next-ask rule, the fiber, W1, E3 and the row ---- *)
First(p) ==      \* the first unread line that is not a unit without an item; 0: there is none
  IF \E i \in (p + 1)..closed : ~IsNone(kinds[i])
    THEN CHOOSE i \in (p + 1)..closed : ~IsNone(kinds[i]) /\ \A k \in (p + 1)..(i - 1) : IsNone(kinds[k])
    ELSE 0
(* One function says "something unread" *)
Unread(mm) == tid # mm.tl \/ mm.pos > closed \/ First(mm.pos) # 0
RunEnds(j) ==    \* where a range ask that starts at the item j may end: readable units only
  { t \in j..closed : IsItem(kinds[t]) /\ \A k \in j..t : IsItem(kinds[k]) \/ IsNone(kinds[k]) }
CleanFront(a, b) == \A k \in a..(b - 1) : k <= closed /\ IsNone(kinds[k])                    \* ghost: only item-less units lie in front
ReadClean(a, b) == \A k \in a..b : k <= closed /\ (IsItem(kinds[k]) \/ IsNone(kinds[k]))    \* ghost: a read covers readable units only

NewFiber(n, kind) ==
  [no |-> n, kind |-> kind, disp |-> FALSE, basis |-> {}, from |-> 0, through |-> 0, gret |-> {},
   one |-> (kind = "alone"), flag |-> FALSE]
Asked(mm, n, kind) ==
  [mm EXCEPT !.state = "Asking", !.askNo = n, !.asked = kind, !.rs = {}, !.askLane = mm.lane]
Start(mm, cc, fb) ==
  IF Q(mm.lane) # 0 /\ Unread(mm)
    THEN /\ m' = [Asked(mm, cc.gid + 1, "range") EXCEPT !.seen = FileLen]
         /\ fibers' = fb \cup { NewFiber(cc.gid + 1, "range") }
         /\ c' = [cc EXCEPT !.gid = @ + 1]
    ELSE /\ m' = [mm EXCEPT !.state = "Idle", !.askNo = 0, !.asked = "none", !.rs = {},
                            !.askLane = 0, !.seen = FileLen]
         /\ fibers' = fb
         /\ c' = [cc EXCEPT !.chain = 0]
(* "at once": Read_item_alone after input, Make_room after an alone commit, the narrower range after a refusal *)
StartKind(mm, cc, fb, kind) ==
  /\ m' = Asked(mm, cc.gid + 1, kind)
  /\ fibers' = fb \cup { NewFiber(cc.gid + 1, kind) }
  /\ c' = [cc EXCEPT !.gid = @ + 1]

Stop(mm, why) ==
  [mm EXCEPT !.state = "Stopped", !.stop = why, !.askNo = 0, !.asked = "none", !.rs = {}, !.askLane = 0]

SetLast(mm, v, one, sil, basis) ==
  [mm EXCEPT !.last = v, !.lastOne = one, !.lastSil = sil,
             !.lastBasis = IF v = "lane" /\ one /\ ~sil THEN basis ELSE {},
             !.lastPos = IF v \in {"lane", "fault", "failed"} THEN m.pos ELSE 0,    \* ghost: the head the result was about
             !.lastTl = IF v \in {"lane", "fault", "failed"} THEN m.tl ELSE 0]
Emptied(mm) == IF SkipEmptiesLast THEN SetLast(mm, "none", FALSE, FALSE, {}) ELSE mm
Sef == IF m.last \in {"fault", "failed"} THEN 1 ELSE c.sef
SetRoom(mm, v) == [mm EXCEPT !.room = v, !.roomMem = {}, !.roomLane = 0]

WipeTo(cc) ==
  /\ m' = NewProc(m.lane)
  /\ fibers' = {} /\ mailbox' = {} /\ hint' = FALSE /\ keeperUp' = (KeeperRule = "never")
  /\ c' = [cc EXCEPT !.crash = @ + 1, !.chain = 0, !.gl = "oth", !.saw = {},
                     !.off = IF EnsureOn /\ ~reg THEN 1 ELSE @]

(* ghost: which units a read or a skip line covers, and which a read commit covers a second time *)
Rd(cc, line) ==
  LET c1 == IF Ghosts /\ line.cause \in {"read", "skip"}
              THEN [cc EXCEPT !.cov = @ \cup { k \in line.from..line.pos : k >= 1 /\ k <= closed }] ELSE cc IN
  IF ~Ghosts \/ line.cause # "read" THEN c1
  ELSE LET top == IF line.pos < cc.rdmax THEN line.pos ELSE cc.rdmax
           hi  == IF top < closed THEN top ELSE closed
       IN [c1 EXCEPT !.rdmax = IF line.pos > @ THEN line.pos ELSE @,
                     !.again = IF line.from > cc.rdmax THEN @
                               ELSE IF \E k \in line.from..hi : IsTurnUnit(kinds[k]) THEN 2
                               ELSE IF @ = 2 THEN 2 ELSE 1]

(* ---- One commit. mm is the memory after the
   commit landed. mode "next" runs the next-ask rule afterwards, "room" asks Make_room at once,
   "stay" keeps mm.state. Sets log, snap, dpos, m, fibers, mailbox, hint, keeperUp, c. ---- *)
Committing(line, mm, mode, cc, mbOk, fbOk, mbFail) ==
  LET c0 == [cc EXCEPT !.chain = 0]
      cr == [Rd(c0, line) EXCEPT !.retr = IF ~Ghosts THEN @
                                          ELSE IF line.cause = "direct" THEN (@ \ line.added) \cup (line.basis \ line.after)
                                          ELSE @ \ line.added,
                         !.wnew = IF line.cause = "direct" /\ c0.remade = 1 /\ reg THEN 1 ELSE @,
                         !.wun = IF line.cause = "direct" /\ ~reg THEN 1 ELSE @] IN
  \/ /\ ~HasLog                               \* the commit log is gone under a living writer: the append at the known end fails
     /\ m' = Stop(m, "unwritable")
     /\ mailbox' = mbFail /\ c' = c0
     /\ UNCHANGED << log, snap, dpos, fibers, hint, keeperUp >>
  \/ /\ HasLog /\ (snapBad \/ snap # m.facts)  \* the before-state check fails: Stopped (Log_diverged _), no line
     /\ m' = Stop(m, "diverged")
     /\ mailbox' = mbFail /\ c' = c0
     /\ UNCHANGED << log, snap, dpos, fibers, hint, keeperUp >>
  \/ /\ HasLog /\ ~snapBad /\ snap = m.facts             \* the line and the snapshot land
     /\ log' = Append(log, line) /\ snap' = line.after /\ dpos' = line.pos
     /\ mailbox' = mbOk /\ UNCHANGED << hint, keeperUp >>
     /\ CASE mode = "next"   -> Start(mm, cr, fbOk)
          [] mode = "room" -> StartKind(mm, cr, fbOk, "room")
          [] OTHER         -> m' = mm /\ fibers' = fbOk /\ c' = cr
  \/ /\ HasLog /\ ~snapBad /\ snap = m.facts /\ cc.crash < MaxCrash   \* the line lands, the process dies before the snapshot
     /\ log' = Append(log, line) /\ dpos' = line.pos /\ UNCHANGED snap
     /\ WipeTo(cr)
  \/ /\ HasLog /\ ~snapBad /\ snap = m.facts /\ cc.io < MaxIo         \* IO fails after the line is durable
     /\ log' = Append(log, line) /\ dpos' = line.pos /\ UNCHANGED snap
     /\ m' = Stop(m, "unwritable")
     /\ mailbox' = mbFail /\ c' = [cr EXCEPT !.io = @ + 1]
     /\ UNCHANGED << fibers, hint, keeperUp >>
  \/ /\ HasLog /\ ~snapBad /\ snap = m.facts /\ cc.io < MaxIo         \* IO fails before the line is durable
     /\ m' = Stop(m, "unwritable")
     /\ mailbox' = mbFail /\ c' = [c0 EXCEPT !.io = @ + 1]
     /\ UNCHANGED << log, snap, dpos, fibers, hint, keeperUp >>
  \/ /\ Bug = "position_first"                 \* the position is saved on its own first; the process dies before the line
     /\ HasLog /\ ~snapBad /\ snap = m.facts /\ cc.crash < MaxCrash
     /\ dpos' = line.pos /\ UNCHANGED << log, snap >>
     /\ WipeTo(c0)

(* ---- Boot ---- *)
BootFinish ==
  /\ m.state = "Booting"
  /\ LET up(hasLog) == CASE KeeperRule \in {"never", "after_boot"} -> TRUE                \* it is up already; or it starts now
                         [] KeeperRule = "after_started" -> keeperUp \/ hasLog
                         [] OTHER -> keeperUp \/ hasLog \/ HasTurnLine             \* "after_turn_line"
         stopped(why, hasLog, cc) == /\ m' = [Stop(m, why) EXCEPT !.stopEnd = closed]
                                     /\ keeperUp' = up(hasLog) /\ c' = cc
                                     /\ UNCHANGED << log, snap, fibers >>
         first == Line(snap, snap, "started", 0, 0, tid, 0, {}, {}, TRUE, TRUE)
         fb(cc) == [cc EXCEPT !.fbstop = GhostBit]
     IN
     IF ~lockFree THEN stopped("unwritable", HasLog, IF HasLog \/ LooksLost THEN c ELSE fb(c))
     ELSE IF ~HasLog THEN
       IF LooksLost THEN stopped("log_unreadable", FALSE, c)          \* only under the deleted splits
       ELSE IF snapBad THEN stopped("mem_unreadable", FALSE, fb(c))   \* first boot, the snapshot does not decode
       ELSE \/ /\ log' = << first >>                                  \* first boot, whatever the turn log holds: Started at Log_started
               /\ keeperUp' = TRUE /\ UNCHANGED snap
               /\ Start([m EXCEPT !.facts = snap, !.pos = 0, !.tl = tid, !.stop = "none"],
                        [c EXCEPT !.started = GhostBit], fibers)
            \/ /\ c.io < MaxIo                                    \* the write of Started fails before the line is durable
               /\ stopped("unwritable", FALSE, fb([c EXCEPT !.io = @ + 1]))
            \/ /\ c.io < MaxIo                                    \* ... or after it: the file is there and the writer is Stopped
               /\ log' = << first >> /\ UNCHANGED << snap, fibers >>
               /\ m' = [Stop(m, "unwritable") EXCEPT !.stopEnd = closed]
               /\ keeperUp' = up(TRUE)
               /\ c' = [c EXCEPT !.io = @ + 1, !.started = GhostBit]
     ELSE IF Last.bad THEN stopped("log_unreadable", TRUE, c)         \* the commit log has lines and its tail line does not parse
     ELSE IF snapBad THEN stopped("mem_unreadable", TRUE, c)
     ELSE IF snap = Last.after \/ snap = Last.basis
       THEN /\ snap' = Last.after /\ keeperUp' = TRUE /\ UNCHANGED log   \* recovered, or the snapshot write is redone
            /\ Start([m EXCEPT !.facts = Last.after,
                               !.pos = IF Bug = "position_first" THEN dpos ELSE Last.pos,
                               !.tl = Last.tl, !.stop = "none"], c, fibers)
       ELSE stopped("diverged", TRUE, c)
  /\ UNCHANGED << snapBad, lockFree, dpos, tid, closed, kinds, op, mailbox, hint, held, lost, reg >>

(* ---- the ask fiber ---- *)
Post(f, res) == [no |-> f.no, kind |-> f.kind, res |-> res, basis |-> f.basis, from |-> f.from,
                 through |-> f.through, gret |-> f.gret, one |-> f.one, flag |-> f.flag]

Dispatch(f) ==    \* the fiber's read: the view, the snapshot bytes, the turn log (faults in order: id, position, decode)
  /\ f \in fibers /\ ~f.disp
  /\ m.state # "Booting"
  /\ LET ends(res, a, b) ==
           /\ fibers' = fibers \ {f}
           /\ mailbox' = mailbox \cup { Post([f EXCEPT !.basis = m.facts, !.from = a, !.through = b,
                                                       !.one = FALSE, !.flag = Unread(m)], res) }
         j == First(m.pos)
         notFirst == Reader # "passes_front" /\ j # m.pos + 1     \* "only when that line is the first unread one"
     IN
     IF snapBad \/ snap # m.facts
       THEN /\ Reread = "fault"                \* Memory_diverged; with "loop" the fiber reads again: no step
            /\ ends("diverged", 0, 0)
     ELSE IF f.kind = "room"
       THEN /\ fibers' = (fibers \ {f}) \cup { [f EXCEPT !.disp = TRUE, !.basis = m.facts] }
            /\ UNCHANGED mailbox
     ELSE IF tid # m.tl \/ m.pos > closed THEN ends("fault", 0, 0)       \* Turn_log_replaced, Position_lost
     ELSE IF j = 0 THEN ends("nothing", 0, 0)                            \* Nothing_to_ask
     ELSE IF kinds[j] = "bad"                                            \* Line_unreadable
       THEN IF notFirst THEN ends("nothing", 0, 0) ELSE ends("fault", 0, 0)
     ELSE IF IsSpan(kinds[j])                                            \* Span_unknown; the Skip passes the item-less units in front
       THEN IF notFirst THEN ends("nothing", 0, 0) ELSE ends("span", m.pos + 1, j)
     ELSE IF kinds[j] = "missing" THEN ends("missing", m.pos + 1, j)     \* Nothing_readable
     ELSE /\ \E t \in (IF f.kind = "alone" THEN {j} ELSE RunEnds(j)) :
               fibers' = (fibers \ {f}) \cup
                 { [f EXCEPT !.disp = TRUE, !.basis = m.facts, !.from = m.pos + 1, !.through = t,
                             !.one = (f.kind = "alone" \/ Cardinality({ k \in j..t : IsItem(kinds[k]) }) = 1),
                             !.flag = TRUE] }
          /\ UNCHANGED mailbox
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, hint, held, c, lost, reg >>

(* A one-item ask that no slot answered ends in one of:
   "input" (all, each Input_too_large), "allnot" (all, not input), and not all:
   "notall_r" every declared slot refused or has a size fact (a bare 400 is a refusal with no size),
   "notall_s" some declared slot was silent. *)
LaneRes == {"refused", "silent", "input", "allnot", "notall_r", "notall_s"}
ResultsOf(f) ==
  IF f.kind = "room" THEN {"room_answer", "room_fits_none", "room_other"}
  ELSE IF f.one THEN {"answer", "input", "allnot", "notall_r", "notall_s", "failed"}
  ELSE {"answer", "refused", "silent", "failed"}

FiberEnds(f) ==
  /\ f \in fibers /\ f.disp
  /\ \E r \in ResultsOf(f) :
       /\ r \in {"silent", "notall_r", "notall_s"} => c.rest < MaxRest
       /\ r = "refused" => c.refuse < MaxRefuse
       /\ r = "input" => c.input < MaxInput
       /\ r = "allnot" => c.allnot < MaxAllNot
       /\ r = "failed" => c.fail < MaxFail
       /\ mailbox' = mailbox \cup { Post(f, r) }
       /\ c' = [c EXCEPT !.rest = IF r \in {"silent", "notall_r", "notall_s"} THEN @ + 1 ELSE @,
                         !.refuse = IF r = "refused" THEN @ + 1 ELSE @,
                         !.input = IF r = "input" THEN @ + 1 ELSE @,
                         !.allnot = IF r = "allnot" THEN @ + 1 ELSE @,
                         !.fail = IF r = "failed" THEN @ + 1 ELSE @]
  /\ fibers' = fibers \ {f}
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, hint, held, lost, reg >>

(* ---- Ask_ended ---- *)
HandleAsk(msg) ==
  /\ msg \in mailbox /\ msg.kind # "write"
  /\ LET current  == m.state = "Asking" /\ msg.no = m.askNo
         \* the bug: the current-ask check is forgotten; the position rule still holds
         staleBug == /\ Bug = "apply_stale" /\ ~current /\ m.state \in Running
                     /\ msg.res = "answer" /\ msg.kind = "range" /\ msg.from = m.pos + 1
         mb       == mailbox \ {msg}
         G(cl)    == [c EXCEPT !.gl = cl]
         quiet(mm, cl) == /\ m' = mm /\ mailbox' = mb /\ c' = [G(cl) EXCEPT !.chain = 0]
                          /\ UNCHANGED << log, snap, dpos, fibers, hint, keeperUp >>
         askNextC(mm, cc)   == /\ Start(mm, [cc EXCEPT !.chain = @ + 1], fibers) /\ mailbox' = mb
                          /\ UNCHANGED << log, snap, dpos, hint, keeperUp >>
         askNext(mm, cl)    == askNextC(mm, G(cl))
         atOnce(mm, kind, cl) == /\ StartKind(mm, [G(cl) EXCEPT !.chain = @ + 1], fibers, kind) /\ mailbox' = mb
                                 /\ UNCHANGED << log, snap, dpos, hint, keeperUp >>
         park(st, v, one, sil, b) ==
           [SetLast(m, v, one, sil, msg.basis) EXCEPT !.state = st, !.askNo = 0, !.asked = "none", !.rs = {},
                                                      !.askLane = 0, !.bottom = b]
         basisNow == msg.basis = m.facts
         deny     == IF Bug = "undo_retract" THEN {} ELSE m.rs
         skipLine == Line(m.facts, m.facts, "skip", msg.from, msg.through, m.tl, 0, {}, {}, TRUE,
                          CleanFront(msg.from, msg.through))
         skipped  == SetLast([m EXCEPT !.pos = msg.through, !.bottom = FALSE], "answered", FALSE, FALSE, {})
         noRoom(mm) == IF RoomEmptied THEN SetRoom(mm, "none") ELSE mm    \* "a Read_range answer whose question showed Memory empties last_room"
         decide(res) ==
           CASE res = "diverged" -> quiet(Stop(m, "diverged"), "oth")
             [] res = "nothing"  ->                                           \* last is not replaced
                  IF Reader = "first_only_idle"
                    THEN quiet([m EXCEPT !.state = "Idle", !.askNo = 0, !.asked = "none", !.rs = {},
                                         !.askLane = 0, !.seen = FileLen], "oth")
                    ELSE askNext(m, "oth")
             [] res = "fault"    -> quiet(park("Resting", "fault", FALSE, FALSE, m.bottom), "oth")
             [] res = "failed"   -> quiet(park("Resting", "failed", FALSE, FALSE, m.bottom), "oth")
             [] res \in {"span", "missing"} ->                                \* Skip (Unknown_span), Skip (Content_missing)
                  Committing(skipLine, skipped, "next", G("oth"), mb, fibers, mb)
             [] res = "answer" /\ msg.kind = "range" ->
                  \E add \in SUBSET Facts, drop \in SUBSET msg.basis,
                     gone \in (IF Settle THEN SUBSET Facts ELSE {{}}), wd \in (IF Settle THEN SUBSET msg.basis ELSE {{}}) :
                    LET addA  == (add \ deny) \ gone                 \* settle: the fixpoint may take an add back
                        dropA == ((drop \ deny) \cap m.facts) \ wd    \* settle: a removal may be withdrawn
                        nf    == (m.facts \ dropA) \cup addA
                        line  == Line(m.facts, nf, "read", msg.from, msg.through, m.tl, msg.no,
                                      nf \ m.facts, msg.gret, current, ReadClean(msg.from, msg.through))
                        mm    == [noRoom(SetLast(m, "answered", FALSE, FALSE, {}))
                                    EXCEPT !.facts = nf, !.pos = msg.through, !.alone = FALSE, !.bottom = FALSE]
                    IN Committing(line, mm, "next", G("oth"), mb, fibers, mb)
             [] res = "answer" /\ msg.kind = "alone" ->                       \* Add only; then Make_room at once
                  \E add \in SUBSET Facts :
                    LET nf   == m.facts \cup (add \ deny)
                        line == Line(m.facts, nf, "read", msg.from, msg.through, m.tl, msg.no,
                                     nf \ m.facts, msg.gret, current, ReadClean(msg.from, msg.through))
                        mm   == [SetLast(m, "answered", FALSE, FALSE, {})
                                   EXCEPT !.facts = nf, !.pos = msg.through, !.alone = TRUE, !.bottom = FALSE]
                        mode == IF m.rs = {} /\ m.askLane = m.lane /\ Bug # "room_never" THEN "room" ELSE "next"
                    IN Committing(line, mm, mode, G("oth"), mb, fibers, mb)
             [] res = "refused"  -> atOnce(SetLast(m, "lane", FALSE, FALSE, {}), "range", "oth")   \* above one item: narrow at once
             [] res = "silent"   -> quiet(park("Resting", "lane", FALSE, TRUE, m.bottom), "oth")
             [] res \in {"input", "allnot", "notall_r", "notall_s"} /\ ~basisNow -> askNext(m, "oth")
             [] res = "notall_r" /\ basisNow -> quiet(park("Resting", "lane", TRUE, FALSE, m.bottom), "ref")
             [] res = "notall_s" /\ basisNow -> quiet(park("Resting", "lane", TRUE, TRUE, m.bottom), "sil")
             [] res = "allnot" /\ basisNow -> quiet(park("RaB", "lane", TRUE, FALSE, TRUE), "ref")
             [] res = "input" /\ basisNow /\ msg.kind = "range" ->
                  atOnce([SetLast(m, "lane", TRUE, FALSE, msg.basis) EXCEPT !.bottom = TRUE], "alone", "ref")
             [] res = "input" /\ basisNow /\ msg.kind = "alone" ->          \* Skip (Item_exceeds_window)
                  Committing(skipLine, SetLast(skipped, "lane", TRUE, FALSE, msg.basis), "next", G("ref"), mb, fibers, mb)
             [] res = "room_answer" ->
                  IF m.rs # {} THEN askNext(SetRoom(m, "stale"), "oth")
                  ELSE \E add \in SUBSET Facts, drop \in SUBSET msg.basis :
                         LET nf == (m.facts \ drop) \cup add IN
                         IF nf = m.facts THEN askNext(SetRoom(m, "unchanged"), "oth")
                         ELSE Committing(Line(m.facts, nf, "room", 0, m.pos, m.tl, msg.no, nf \ m.facts, msg.gret, current, TRUE),
                                         [SetRoom(m, "made") EXCEPT !.facts = nf], "next", G("oth"), mb, fibers, mb)
             [] res = "room_fits_none" ->                                     \* Room_refused, every declared slot Input_too_large: reading goes on
                  askNext([m EXCEPT !.room = "fits_none", !.roomMem = msg.basis, !.roomLane = m.askLane], "oth")
             [] res = "room_other"     -> askNext(SetRoom(m, "not_judged"), "oth")
     IN
     IF current \/ staleBug THEN
       IF msg.res \in LaneRes /\ m.askLane # m.lane          \* a slots-only change landed during the ask
         THEN \/ IF ForeignLane = "ask_again"                              \* no slot declared now has an outcome
                   THEN askNextC(m, [G("noout") EXCEPT !.fl = @ + 1])
                   ELSE quiet(park("Resting", "lane", msg.one, TRUE, m.bottom), "noout")
              \/ decide(msg.res)                             \* every slot declared now has its outcome in the result
              \/ /\ msg.res \in {"input", "allnot", "notall_r"}      \* a slot declared now has no outcome: not `all`, and E4's test is false
                 /\ decide("notall_s")
         ELSE decide(msg.res)
     ELSE /\ m' = m /\ mailbox' = mb                         \* not the current ask: dropped
          /\ UNCHANGED << log, snap, dpos, fibers, hint, keeperUp, c >>
  /\ UNCHANGED Env8

(* ---- the turn log's writers ---- *)
TurnOpened ==            \* admission: the Opened line (only with OpenedStep; otherwise it is written with the Closed)
  /\ OpenedStep /\ keeperUp /\ reg /\ ~op /\ closed < MaxTurns
  /\ op' = TRUE
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, m, keeperUp, fibers, mailbox, hint, held, c, lost, reg >>

(* The Turn_closed hint goes through ensure: a live writer gets it; with none live and the Keeper
   registered a writer is made in Booting; for a Keeper that is not registered none is made. *)
Hinted(h) == IF Live THEN hint' = (hint \/ h) /\ UNCHANGED m
             ELSE IF h /\ MakesWriter THEN hint' = TRUE /\ m' = FreshMem(m.lane)
             ELSE UNCHANGED << hint, m >>

TurnClosed ==
  /\ keeperUp /\ reg /\ closed < MaxTurns /\ (OpenedStep => op)
  /\ \E k \in {"item"} \cup (IF c.none < MaxNone THEN {"none"} ELSE {}) \cup (IF c.odd < MaxOdd THEN OddKinds ELSE {}),
        h \in (IF LoseHint THEN {TRUE, FALSE} ELSE {TRUE}) :
       /\ kinds' = Append(kinds, k) /\ closed' = closed + 1 /\ op' = FALSE
       /\ Hinted(h)
       /\ c' = [c EXCEPT !.odd = IF k \in OddKinds THEN @ + 1 ELSE @,
                         !.remade = Remade(h /\ MakesWriter),
                         !.none = IF k = "none" THEN @ + 1 ELSE @,
                         !.early = IF Ghosts /\ ~HasLog /\ c.started = 0 THEN closed + 1 ELSE @,
                         !.tb = IF m.state = "Booting" THEN GhostBit ELSE @,
                         !.ts = IF m.state = "Stopped" THEN GhostBit ELSE @]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, keeperUp, fibers, mailbox, held, lost, reg >>

(* A Reset line written by the reset function outside a turn: the recovering purge,
   the history clear, the process-start step, the CLI purge with no server.
   "stopped": only while the writer is Stopped; "any": while it is Booting or Stopped (also before
   the first boot ends); "always": at any time. Under the deleted Keeper rules "stopped" and "any"
   also need a Keeper that has not started, as in the 22 model. *)
ResetOutside ==
  /\ ResetWhileDown # "no" /\ c.reset < MaxReset /\ closed < MaxTurns /\ ~op
  /\ (ResetWhileDown \in {"stopped", "any"} /\ KeeperRule # "never") => ~keeperUp
  /\ ResetWhileDown = "stopped" => m.state = "Stopped"
  /\ ResetWhileDown = "any" => m.state \in {"Booting", "Stopped"}
  /\ \E k \in ResetKinds : kinds' = Append(kinds, k)
  /\ closed' = closed + 1 /\ Hinted(TRUE)
  /\ c' = [c EXCEPT !.reset = @ + 1, !.remade = Remade(MakesWriter)]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, op, keeperUp, fibers, mailbox, held, lost, reg >>

HandleHint ==
  /\ hint /\ Live /\ m.state # "Booting"
  /\ hint' = FALSE
  /\ IF m.state = "Idle" THEN Start(m, c, fibers) ELSE UNCHANGED << m, fibers, c >>
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, mailbox, held, lost, reg >>

(* ---- Pulse: Resting, Idle ---- *)
PulseResting ==
  /\ m.state = "Resting" /\ ~held /\ c.pulse < MaxPulse
  /\ Start(m, [c EXCEPT !.pulse = @ + 1, !.chain = 0], fibers)
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, mailbox, hint, held, lost, reg >>
PulseIdle ==
  /\ m.state = "Idle" /\ Bug # "idle_no_stat" /\ FileLen # m.seen
  /\ Start(m, c, fibers)
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, mailbox, hint, held, lost, reg >>

Hold ==
  /\ ~held /\ c.hold < MaxHold
  /\ held' = TRUE /\ c' = [c EXCEPT !.hold = @ + 1]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, lost, reg >>
Unhold ==
  /\ held /\ held' = FALSE
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, c, lost, reg >>

(* ---- direct writes that commit a line ---- *)
MarkF(S, r) == { [x EXCEPT !.gret = IF x.disp THEN @ \cup r ELSE @] : x \in S }
MarkM(S, r) == { [x EXCEPT !.gret = @ \cup r] : x \in S }

Write ==
  /\ m.state \in Running /\ ~m.retq /\ c.write < MaxWrite
  /\ \E f \in Facts, w \in {"remember", "retract"}, extra \in (IF Settle THEN SUBSET Facts ELSE {{}}) :
       /\ w = "remember" => (f \notin m.facts /\ extra = {})
       /\ w = "retract" => (f \in m.facts /\ extra \subseteq m.facts \ {f})    \* the support fixpoint may take derived facts
       /\ LET nf      == IF w = "remember" THEN m.facts \cup {f} ELSE m.facts \ ({f} \cup extra)
              removed == m.facts \ nf
              line    == Line(m.facts, nf, "direct", 0, m.pos, m.tl, 0, nf \ m.facts, {}, TRUE, TRUE)
              mm      == [m EXCEPT !.facts = nf,
                                   !.rs = IF m.state = "Asking" THEN @ \cup removed ELSE @]
              mode    == IF m.state = "RaB" THEN "next" ELSE "stay"        \* any write that changed Memory
          IN Committing(line, mm, mode, [c EXCEPT !.write = @ + 1],
                        MarkM(mailbox, removed), MarkF(fibers, removed), mailbox)
  /\ UNCHANGED Env8

(* ---- a Write that waits for the boot ---- *)
(* A Write message. from = 1: it waited for a boot. one: a Retire was in the mailbox ahead of it.
   flag: the Keeper was registered when it was sent. through: how often the Keeper had been unregistered by then. *)
WMsg(f, w, boot, aft) == [no |-> 0, kind |-> "write", res |-> w, basis |-> {f}, from |-> boot, through |-> c.unreg, gret |-> {},
                          one |-> aft, flag |-> reg]
WriteQueued ==            \* the writer boots, or a Retire is ahead in its mailbox: the Write waits
  /\ c.write < MaxWrite
  /\ m.state = "Booting" \/ (m.state \in Running /\ m.retq)
  /\ \E f \in Facts, w \in {"remember", "retract"} :
       mailbox' = mailbox \cup { WMsg(f, w, IF m.state = "Booting" THEN 1 ELSE 0, m.retq) }
  /\ c' = [c EXCEPT !.write = @ + 1]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, hint, held, lost, reg >>
WriteNoWriter ==          \* the Write path calls ensure for a registered Keeper with no live writer
  /\ ~Live /\ reg /\ c.write < MaxWrite
  /\ IF EnsureOn
       THEN /\ m' = FreshMem(m.lane)                                  \* a new writer in Booting; the Write waits for its boot
            /\ \E f \in Facts, w \in {"remember", "retract"} : mailbox' = mailbox \cup { WMsg(f, w, 1, FALSE) }
            /\ c' = [c EXCEPT !.write = @ + 1, !.remade = Remade(TRUE)]
       ELSE /\ c' = [c EXCEPT !.write = @ + 1, !.wra = 1]             \* the old rule: Refused Keeper_retired for a registered Keeper
            /\ UNCHANGED << m, mailbox >>
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, fibers, hint, held, lost, reg >>

HandleWrite(msg) ==       \* the boot has ended: the Write meets the state boot ended in
  /\ msg \in mailbox /\ msg.kind = "write" /\ Live /\ m.state # "Booting"
  /\ msg.one => ~m.retq                    \* a Write behind a Retire is handled after it
  /\ LET f  == CHOOSE x \in msg.basis : TRUE
         mb == mailbox \ {msg}
         changes == IF msg.res = "remember" THEN f \notin m.facts ELSE f \in m.facts
     IN IF m.state \in Running /\ changes
          THEN LET nf      == IF msg.res = "remember" THEN m.facts \cup {f} ELSE m.facts \ {f}
                   removed == m.facts \ nf
                   line    == Line(m.facts, nf, "direct", IF msg.from = 1 THEN 0 - 1 ELSE 0, m.pos, m.tl, 0, nf \ m.facts, {}, TRUE, TRUE)   \* ghost: from = -1 marks a Write that waited for a boot
                   mm      == [m EXCEPT !.facts = nf, !.rs = IF m.state = "Asking" THEN @ \cup removed ELSE @]
                   mode    == IF m.state = "RaB" THEN "next" ELSE "stay"
               IN Committing(line, mm, mode, c, MarkM(mb, removed), MarkF(fibers, removed), mb)
          ELSE /\ mailbox' = mb         \* Stopped: Refused (Store_stopped s). Retired: Refused Keeper_retired. Running and nothing changes: a reply, no line
               /\ c' = [c EXCEPT !.wqr = IF m.state \in Running THEN @ ELSE GhostBit]
               /\ UNCHANGED << log, snap, dpos, m, fibers, hint, keeperUp >>
  /\ UNCHANGED Env8

(* ---- Declaration_changed with another value (the same value changes no state: only its resolution, which the model does not carry, is held) ---- *)
Declaration ==
  /\ c.decl < MaxDecl /\ m.state \in Running \cup {"Stopped", "Absent", "Retired"}
  /\ \E l \in Lanes \ {m.lane} :
       LET cc == [c EXCEPT !.decl = @ + 1, !.chain = 0] IN
       IF m.state \in {"Stopped", "Absent", "Retired"} \/ (m.state = "Asking" /\ Q(l) = Q(m.lane) /\ Bug # "slots_cancel")
         THEN m' = [m EXCEPT !.lane = l] /\ c' = cc /\ UNCHANGED fibers     \* store; a slots-only change lets the ask finish
         ELSE Start([m EXCEPT !.lane = l], cc, fibers)                      \* the old ask number is no longer current: cancelled
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, mailbox, hint, held, lost, reg >>

(* ---- operator acts ---- *)
OpStates == {"Idle", "Asking", "Resting", "RaB"}

Resume ==
  /\ c.resume < MaxResume
  /\ \/ /\ m.state \in {"Resting", "RaB"}
        /\ Start([m EXCEPT !.bottom = FALSE], [c EXCEPT !.resume = @ + 1, !.chain = 0], fibers)
     \/ /\ m.state = "Stopped"                          \* a boot
        /\ m' = FreshMem(m.lane) /\ c' = [c EXCEPT !.resume = @ + 1, !.chain = 0, !.gl = "oth"] /\ UNCHANGED fibers
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, mailbox, hint, held, lost, reg >>

SkipItem ==              \* i is the first unread item as the reader gives it now; item-less units in front go with it
  /\ c.skip < MaxSkip /\ m.state \in OpStates
  /\ tid = m.tl /\ m.pos <= closed
  /\ LET j == First(m.pos) IN
     /\ j # 0 /\ IsItem(kinds[j])
     /\ LET line == Line(m.facts, m.facts, "skip", m.pos + 1, j, m.tl, 0, {}, {}, TRUE, CleanFront(m.pos + 1, j))
            mm   == Emptied([m EXCEPT !.pos = j, !.bottom = FALSE])
            cc   == [c EXCEPT !.skip = @ + 1, !.sef = Sef]
        IN Committing(line, mm, IF Bug = "skip_keeps_ask" /\ m.state = "Asking" THEN "stay" ELSE "next",
                      cc, mailbox, fibers, mailbox)
  /\ UNCHANGED Env8

SkipLine ==              \* the reader, run again at the commit, returns Line_unreadable for that offset
  /\ c.skipline < MaxSkipLine /\ m.state \in OpStates
  /\ tid = m.tl /\ m.pos <= closed
  /\ LET j == First(m.pos) IN
     /\ j # 0 /\ kinds[j] = "bad"
     /\ Reader # "passes_front" => j = m.pos + 1          \* the old reader does not report a line behind an item-less unit
     /\ Committing(Line(m.facts, m.facts, "skip", m.pos + 1, j, m.tl, 0, {}, {}, TRUE, CleanFront(m.pos + 1, j)),
                   Emptied([m EXCEPT !.pos = j, !.bottom = FALSE]), "next",
                   [c EXCEPT !.skipline = @ + 1, !.sef = Sef], mailbox, fibers, mailbox)
  /\ UNCHANGED Env8

RestartReading ==        \* (a) another id, (b) the same id and the position is lost
  /\ c.restart < MaxRestart /\ m.state \in OpStates
  /\ tid # m.tl \/ m.pos > closed
  /\ Committing(Line(m.facts, m.facts, "restart", 0, 0, tid, 0, {}, {}, TRUE, TRUE),
                Emptied([m EXCEPT !.pos = 0, !.tl = tid, !.bottom = FALSE]), "next",
                [c EXCEPT !.restart = @ + 1, !.sef = Sef], mailbox, fibers, mailbox)
  /\ UNCHANGED Env8

(* The bug: an act that is refused still cancels the ask. *)
RefusedActCancels ==
  /\ Bug = "refused_act_cancels" /\ m.state = "Asking" /\ c.refact < 1   \* e.g. Skip_item of an item that is not the head
  /\ m' = [m EXCEPT !.askNo = 0 - 1] /\ c' = [c EXCEPT !.refact = @ + 1]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, fibers, mailbox, hint, held, lost, reg >>

Adopt ==                 \* two rows. The file's sha is observed and it decodes.
  /\ c.adopt < MaxAdopt /\ m.state = "Stopped" /\ ~snapBad
  /\ \/ /\ m.stop = "diverged" /\ HasLog
        /\ log' = Append(log, Line(Last.after, snap, "adopt", 0, Last.pos, Last.tl, 0, {}, {}, TRUE, TRUE))
        /\ UNCHANGED keeperUp
        /\ Start([m EXCEPT !.facts = snap, !.pos = Last.pos, !.tl = Last.tl, !.stop = "none"],
                 [c EXCEPT !.adopt = @ + 1, !.chain = 0], fibers)
     \/ /\ m.stop = "log_unreadable" /\ HasLog
        \* A Started line is appended. "end": at the end of the turn log (the old row). "prev": at the position of the
        \* last line that parses, when there is one. Ghost: from = the position the tail line holds; -1 when no line parses.
        /\ LET good == { i \in 1..Len(log) : ~log[i].bad }
               prev == IF good = {} THEN 0 ELSE CHOOSE i \in good : \A k \in good : k <= i
               back == AdoptPos = "prev" /\ prev # 0
               p    == IF AdoptPos = "start" THEN 0 ELSE IF back THEN log[prev].pos ELSE closed    \* with no known position, the start
               t    == IF back THEN log[prev].tl ELSE tid
           IN /\ log' = Append(log, Line(snap, snap, "started_adopt", IF prev = 0 THEN 0 - 1 ELSE Last.pos, p, t, 0, {}, {}, TRUE, TRUE))
              /\ UNCHANGED keeperUp
              /\ Start([m EXCEPT !.facts = snap, !.pos = p, !.tl = t, !.stop = "none"],
                       [c EXCEPT !.adopt = @ + 1, !.chain = 0, !.started = GhostBit,
                                 !.stale = IF Last.bad THEN @ ELSE GhostBit], fibers)
     \/ /\ m.stop = "log_unreadable" /\ ~HasLog /\ BootSplit # "none"
        \* The deleted splits: Started is the first line, at the end of the turn log.
        \* Ghost: from = where the turn log ended when this stop was found.
        /\ log' = << Line(snap, snap, "started_adopt", m.stopEnd, closed, tid, 0, {}, {}, TRUE, TRUE) >>
        /\ keeperUp' = TRUE
        /\ Start([m EXCEPT !.facts = snap, !.pos = closed, !.tl = tid, !.stop = "none"],
                 [c EXCEPT !.adopt = @ + 1, !.chain = 0, !.started = GhostBit], fibers)
  /\ UNCHANGED << snap, snapBad, lockFree, dpos, tid, closed, kinds, op, mailbox, hint, held, lost, reg >>

(* ---- the registries ---- *)
Register ==              \* a launcher puts the Keeper in the registry. Under ensure no launcher knows the writer.
  /\ ~reg /\ c.regs < MaxReg
  /\ reg' = TRUE
  /\ \/ /\ UNCHANGED m /\ c' = [c EXCEPT !.regs = @ + 1, !.off = 0]       \* ensure; or, under the old rule, the launch path that forgets
     \/ /\ ~EnsureOn /\ ~Live                                             \* the old rule: a launch path that makes the writer
        /\ m' = FreshMem(m.lane) /\ c' = [c EXCEPT !.regs = @ + 1, !.off = 0, !.remade = Remade(TRUE)]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, fibers, mailbox, hint, held, lost >>

Unregister ==            \* a stop or a delete takes the Keeper out of the registry; its turn has ended
  /\ reg /\ c.unreg < MaxUnreg /\ ~op
  /\ reg' = FALSE
  /\ \/ /\ EnsureOn \/ ~Live                                             \* the pulse will send Retire
        /\ UNCHANGED m /\ c' = [c EXCEPT !.unreg = @ + 1, !.off = IF Live THEN @ ELSE 1]
     \/ /\ Live /\ ~m.retq                                                \* the stop path sends it now
        /\ m' = [m EXCEPT !.retq = TRUE] /\ c' = [c EXCEPT !.unreg = @ + 1]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, fibers, mailbox, hint, held, lost >>

RetireEarly ==           \* the stop or delete path sends Retire while the Keeper is still in the registry
  /\ c.retire < MaxRetire /\ Live /\ ~m.retq
  /\ m' = [m EXCEPT !.retq = TRUE] /\ c' = [c EXCEPT !.retire = @ + 1]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, fibers, mailbox, hint, held, lost, reg >>

PulseRegistry ==         \* the pulse walks the registered Keepers (ensure) and the writers (Retire); view's ensure is the first half
  /\ EnsureOn /\ Bug # "ensure_two_steps"
  /\ \/ /\ reg /\ ~Live
        /\ m' = FreshMem(m.lane) /\ c' = [c EXCEPT !.remade = Remade(TRUE)]
     \/ /\ ~reg /\ Live /\ ~m.retq
        /\ m' = [m EXCEPT !.retq = TRUE] /\ UNCHANGED c
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, fibers, mailbox, hint, held, lost, reg >>

(* The bug that shows why ensure is one step: the look and the insert are two steps, and view and the pulse both look. *)
EnsureLook(who) ==
  /\ EnsureOn /\ Bug = "ensure_two_steps" /\ reg /\ ~Live /\ who \notin c.saw
  /\ c' = [c EXCEPT !.saw = @ \cup {who}]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>
EnsureInsert(who) ==
  /\ who \in c.saw
  /\ m' = FreshMem(m.lane) /\ fibers' = {} /\ mailbox' = {} /\ hint' = FALSE
  /\ lockFree' = (lockFree /\ (~Live \/ m.state = "Booting"))               \* a pushed-out writer that finished its boot keeps the lock
  /\ c' = [c EXCEPT !.saw = @ \ {who}, !.orphans = IF Live THEN 1 ELSE @]
  /\ UNCHANGED << log, snap, snapBad, dpos, tid, closed, kinds, op, keeperUp, held, lost, reg >>

HandleRetire ==          \* Retire waits for the boot and for the Writes that came before it
  /\ Live /\ m.retq /\ m.state # "Booting"
  /\ \A x \in mailbox : x.kind = "write" => x.one
  /\ IF RetireRule = "checks_registry" /\ reg
       THEN /\ m' = [m EXCEPT !.retq = FALSE]                           \* the variant: the Keeper is registered now, the Retire is dropped
            /\ mailbox' = { IF x.kind = "write" THEN [x EXCEPT !.one = FALSE] ELSE x : x \in mailbox }
            /\ UNCHANGED << fibers, hint, c >>
       ELSE IF RetireRule = "write_retries" /\ reg /\ (\E x \in mailbox : x.kind = "write")
       THEN /\ m' = FreshMem(m.lane)                                   \* variant: the Write path, refused Keeper_retired for a registered Keeper, calls ensure once more
            /\ mailbox' = { [x EXCEPT !.one = FALSE, !.from = 1] : x \in { y \in mailbox : y.kind = "write" } }
            /\ fibers' = {} /\ hint' = FALSE
            /\ c' = [c EXCEPT !.chain = 0, !.gl = "oth", !.remade = 1]
       ELSE /\ m' = [NoWriter(m.lane) EXCEPT !.state = "Retired"]       \* closes the files, releases the lock; the ask is cancelled
            /\ fibers' = {} /\ mailbox' = {} /\ hint' = FALSE           \* the Writes behind it: Refused Keeper_retired
            /\ c' = [c EXCEPT !.chain = 0, !.gl = "oth", !.off = IF reg THEN @ ELSE 1,
                              !.wrr = IF \E x \in mailbox : x.kind = "write" /\ x.flag /\ reg /\ x.through = c.unreg THEN 1 ELSE @]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, keeperUp, held, lost, reg >>

(* ---- the environment ---- *)
Crash ==
  /\ c.crash < MaxCrash /\ Live
  /\ WipeTo(c)
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, closed, kinds, op, held, lost, reg >>

LoseLog ==               \* the commit log is gone when the process comes back
  /\ c.lose < MaxLose /\ c.crash < MaxCrash /\ Live /\ HasLog
  /\ log' = << >> /\ lost' = TRUE
  /\ WipeTo([c EXCEPT !.lose = @ + 1, !.tloss = IF Ghosts THEN Last.after ELSE @, !.rloss = c.retr])
  /\ UNCHANGED << snap, snapBad, lockFree, dpos, tid, closed, kinds, op, held, reg >>

LoseLogAlive ==          \* the commit log is deleted while the process lives, in any writer state (outside the product)
  /\ c.losealive < MaxLoseAlive /\ Live /\ HasLog
  /\ log' = << >> /\ lost' = TRUE
  /\ c' = [c EXCEPT !.losealive = @ + 1, !.tloss = IF Ghosts THEN Last.after ELSE @, !.rloss = c.retr]
  /\ UNCHANGED << snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, reg >>

BreakLogTail ==          \* the tail line of the commit log no longer parses (outside the product)
  /\ c.breaklog < MaxBreakLog /\ m.state # "Retired" /\ HasLog /\ ~Last.bad
  /\ log' = [log EXCEPT ![Len(log)].bad = TRUE]
  /\ c' = [c EXCEPT !.breaklog = @ + 1]
  /\ UNCHANGED << snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>
RepairLogTail ==         \* the operator restores the file (the bytes it had)
  /\ c.repairlog < MaxRepairLog /\ HasLog /\ Last.bad
  /\ log' = [log EXCEPT ![Len(log)].bad = FALSE]
  /\ c' = [c EXCEPT !.repairlog = @ + 1]
  /\ UNCHANGED << snap, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>

ForeignEdit ==           \* something other than the writer rewrites memory-current.json
  /\ c.foreign < MaxForeign
  /\ \E s \in SUBSET Facts : s # snap /\ snap' = s
  /\ c' = [c EXCEPT !.foreign = @ + 1]
  /\ UNCHANGED << log, snapBad, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>

BreakSnap ==             \* the snapshot file does not decode
  /\ c.badsnap < MaxBadSnap /\ ~snapBad
  /\ snapBad' = TRUE /\ c' = [c EXCEPT !.badsnap = @ + 1]
  /\ UNCHANGED << log, snap, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>
RestoreSnap ==           \* the operator restores the file (the bytes it had)
  /\ snapBad /\ snapBad' = FALSE
  /\ UNCHANGED << log, snap, lockFree, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, c, lost, reg >>

LockBusy ==              \* another process holds the lock while this writer boots
  /\ c.lock < MaxLock /\ lockFree /\ m.state = "Booting"
  /\ lockFree' = FALSE /\ c' = [c EXCEPT !.lock = @ + 1]
  /\ UNCHANGED << log, snap, snapBad, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>
LockFreed ==
  /\ ~lockFree /\ lockFree' = TRUE
  /\ UNCHANGED << log, snap, snapBad, dpos, tid, closed, kinds, op, m, keeperUp, fibers, mailbox, hint, held, c, lost, reg >>

ReplaceTurnLog ==        \* turns.jsonl is deleted; the turn-log module writes Log_started with a new id
  /\ c.replace < MaxReplace
  /\ tid' = tid + 1
  /\ IF SameLenReplace                        \* a stated limit: the new file has the length of the old one
       THEN /\ closed' = closed /\ UNCHANGED op
            /\ kinds' = [i \in 1..closed |-> IF IsTurnUnit(kinds[i]) THEN "item" ELSE "ritem"]
       ELSE closed' = 0 /\ kinds' = << >> /\ op' = FALSE
  /\ c' = [c EXCEPT !.replace = @ + 1, !.rdmax = 0, !.cov = {}, !.early = 0,
                    !.rnl = IF ~HasLog /\ c.started = 0 THEN GhostBit ELSE @,
                    !.ungone = IF (1..closed) \ c.cov # {} THEN GhostBit ELSE @]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>
CutTurnLog ==            \* the file is cut or an older copy is restored: the same id, fewer lines
  /\ c.cut < MaxCut /\ closed > 0
  /\ \E n \in 0..(closed - 1), o \in BOOLEAN :
       /\ o => (OpenedStep /\ IsTurnUnit(kinds[n + 1]))     \* the Opened of the first unit that was cut may stay
       /\ closed' = n /\ kinds' = SubSeq(kinds, 1, n) /\ op' = o
       /\ c' = [c EXCEPT !.cut = @ + 1, !.rdmax = IF @ > n THEN n ELSE @, !.cov = @ \cap (1..n),
                         !.early = IF @ > n THEN n ELSE @,
                         !.ungone = IF ((n + 1)..closed) \ c.cov # {} THEN GhostBit ELSE @]
  /\ UNCHANGED << log, snap, snapBad, lockFree, dpos, tid, m, keeperUp, fibers, mailbox, hint, held, lost, reg >>

DispatchAny  == \E f \in fibers : Dispatch(f)
FiberEndsAny == \E f \in fibers : FiberEnds(f)
HandleAskAny == \E msg \in mailbox : HandleAsk(msg)
HandleWriteAny == \E msg \in mailbox : HandleWrite(msg)

Next ==
  \/ BootFinish \/ DispatchAny \/ FiberEndsAny \/ HandleAskAny
  \/ TurnOpened \/ TurnClosed \/ ResetOutside \/ HandleHint \/ PulseResting \/ PulseIdle \/ Hold \/ Unhold
  \/ Write \/ WriteQueued \/ WriteNoWriter \/ HandleWriteAny \/ Declaration \/ Resume \/ SkipItem \/ SkipLine \/ RestartReading \/ RefusedActCancels
  \/ Adopt \/ Register \/ Unregister \/ RetireEarly \/ PulseRegistry \/ HandleRetire
  \/ (\E who \in {"view", "pulse"} : EnsureLook(who) \/ EnsureInsert(who))
  \/ Crash \/ LoseLog \/ LoseLogAlive \/ BreakLogTail \/ RepairLogTail \/ ForeignEdit \/ BreakSnap \/ RestoreSnap \/ LockBusy \/ LockFreed
  \/ ReplaceTurnLog \/ CutTurnLog

Spec == Init /\ [][Next]_vars

Fair ==
  /\ WF_vars(BootFinish) /\ WF_vars(DispatchAny) /\ WF_vars(FiberEndsAny)
  /\ WF_vars(HandleAskAny) /\ WF_vars(HandleHint) /\ WF_vars(PulseResting) /\ WF_vars(PulseIdle)
  /\ WF_vars(Unhold) /\ WF_vars(HandleWriteAny) /\ WF_vars(PulseRegistry) /\ WF_vars(HandleRetire)
FairSpec == Spec /\ Fair

(***************************************************************************)
(* Properties, with the names the RFC uses                                 *)
(***************************************************************************)
TypeOK ==
  /\ m.state \in States
  /\ m.stop \in {"none", "diverged", "log_unreadable", "mem_unreadable", "unwritable"}
  /\ m.asked \in {"none", "range", "alone", "room"}
  /\ m.last \in {"none", "answered", "lane", "fault", "failed"}
  /\ m.room \in {"none", "made", "unchanged", "stale", "fits_none", "not_judged"}
  /\ m.facts \subseteq Facts /\ snap \subseteq Facts
  /\ closed \in 0..MaxTurns /\ Len(kinds) = closed
  /\ (m.state \in Running /\ c.losealive = 0) => HasLog
  /\ m.state = "Asking" => Q(m.lane) # 0
  /\ reg \in BOOLEAN /\ m.retq \in BOOLEAN
  /\ ~Live => (mailbox = {} /\ fibers = {} /\ ~hint /\ ~m.retq)

(* Chain: basis(n+1) = after(n). A Started line that Adopt appended has a snapshot and no basis. *)
Chain == \A i \in 2..Len(log) : log[i].cause = "started_adopt" \/ log[i].basis = log[i - 1].after

(* SnapshotLag: the snapshot lags the log by at most one line, and a running
   writer has it repaired. For behaviours with no foreign edit and no broken snapshot file. *)
SnapshotLag ==
  (c.foreign = 0 /\ c.badsnap = 0 /\ HasLog) =>
    /\ snap \in { Last.after, Last.basis }
    /\ m.state \in Running => snap = Last.after /\ m.facts = Last.after
    /\ m.stop # "diverged"

(* NoUndoRetract: a fact retracted by a direct write after a question's basis
   is never added by that question's answer. *)
NoUndoRetract == \A i \in 1..Len(log) : log[i].added \cap log[i].gret = {}

AnswerAtMostOnce ==
  \A i, j \in 1..Len(log) : (i # j /\ log[i].gid # 0) => log[i].gid # log[j].gid
AnswerOnlyWhenCurrent == \A i \in 1..Len(log) : log[i].cur

(* PositionMoves: only a read, a skip, or Restart_reading moves the position;
   read and skip ranges are contiguous; a position names the turn log it points into;
   a first-boot Started is at Log_started. *)
PositionMoves ==
  \A i \in 1..Len(log) :
    IF i = 1 THEN /\ log[1].cause \in {"started", "started_adopt"}
                  /\ log[1].cause = "started" => log[1].pos = 0
    ELSE LET p == log[i - 1].pos  t == log[i - 1].tl IN
         CASE log[i].cause = "read"    -> log[i].from = p + 1 /\ log[i].pos >= log[i].from /\ log[i].tl = t
           [] log[i].cause = "skip"    -> log[i].from = p + 1 /\ log[i].pos >= log[i].from /\ log[i].tl = t
           [] log[i].cause = "restart" -> log[i].pos = 0
           [] log[i].cause \in {"direct", "adopt", "room"} -> log[i].pos = p /\ log[i].tl = t
           [] log[i].cause = "started_adopt" -> TRUE
           [] OTHER -> FALSE
(* PositionHasLine: every unit the writer has passed is passed by a line. *)
PositionHasLine == (m.state \in Running /\ HasLog) => (m.pos = Last.pos /\ m.tl = Last.tl)
(* A Skip passes one line and only item-less units in front of it; a read covers readable
   units only. For behaviours in which the turn log was not cut or replaced. *)
SkipsOnlyItemless == (c.cut = 0 /\ c.replace = 0) => \A i \in 1..Len(log) : log[i].clean

(* ---- alerts ---- *)
E1 == m.state = "Stopped"
E2 == m.state = "RaB"
E3 == Unread(m) /\ m.last \in {"fault", "failed"}
OneItemRefusal == m.state = "Resting" /\ m.last = "lane" /\ m.lastOne      \* Resting on a lane result that offered one item
E4 == CASE E4Rule = "narrow" -> OneItemRefusal /\ ~m.lastSil /\ m.lastBasis = m.facts
        [] E4Rule = "any_one_item" -> OneItemRefusal
        [] E4Rule = "stateless" -> m.state # "RaB" /\ Unread(m) /\ m.last = "lane" /\ m.lastOne /\ ~m.lastSil /\ m.lastBasis = m.facts
        [] OTHER -> FALSE
E5 == IF E5Rule = "held_now"
        THEN m.room = "fits_none" /\ m.roomMem = m.facts /\ m.roomLane = m.lane
        ELSE m.room = "fits_none"
W1 == m.state = "Booting" \/ (Unread(m) /\ (Q(m.lane) = 0 \/ m.last = "none" \/ m.last = "lane"))
W3 == m.alone
RowOn == E1 \/ E2 \/ E3 \/ E4 \/ E5 \/ W1
ErrorOn == E1 \/ E2 \/ E3 \/ E4 \/ E5
InFlight ==
  \/ m.state = "Asking"                                   \* an ask is current
  \/ (hint /\ Live)                                       \* a Turn_closed is in the mailbox
  \/ (m.state = "Idle" /\ Bug # "idle_no_stat" /\ FileLen # m.seen)   \* the next pulse runs the next-ask rule
Park == Live /\ Unread(m) /\ ~InFlight
(* NoSilentPark: something unread, nothing in flight that will look at it
   without an operator or a change => a row is on. *)
NoSilentPark == Park => RowOn
(* The same with W1's "last is None" left out. *)
NoSilentParkWithoutSinceBoot ==
  Park => (E1 \/ E2 \/ E3 \/ E4 \/ E5 \/ m.state = "Booting" \/ (Unread(m) /\ (Q(m.lane) = 0 \/ m.last = "lane")))

(* E4 is never on when a slot was silent in the last ask (c.gl is kept by the model, not read from `last`). *)
E4NeverWithSilentSlot == E4 => c.gl = "ref"
(* For E4Rule = "none": an item every declared slot refused is an error, not a warning. *)
RefusedByEverySlotIsAnError ==
  (OneItemRefusal /\ ~m.lastSil /\ m.lastBasis = m.facts) => ErrorOn
(* E5 stands only on a verdict about the Memory and the lane held now. *)
E5OnlyOnBytesHeldNow == E5 => (m.roomMem = m.facts /\ m.roomLane = m.lane)
E5ImpliesReadAlone == E5 => m.alone

AskingHasAnAsk ==
  m.state = "Asking" =>
    \/ \E f \in fibers : f.no = m.askNo
    \/ \E msg \in mailbox : msg.no = m.askNo
OnlyAskingHasAnAsk == m.state # "Asking" => m.askNo = 0

(* ---- boot ---- *)
AdoptLines == { i \in 1..Len(log) : log[i].cause = "started_adopt" }
WriteMsgs == { x \in mailbox : x.kind = "write" }
AskMsgs == { x \in mailbox : x.kind # "write" }
(* `Stopped Log_unreadable` is only: the commit log has lines and its tail line stopped parsing. *)
AdoptOnlyAfterLostLog == (m.state = "Stopped" /\ m.stop = "log_unreadable") => c.breaklog > 0
(* No closed unit at or before the position is passed without a line that says so: a read, a skip,
   or a Started that Adopt wrote, and that one only on a commit log whose tail line stopped parsing.
   For behaviours in which the turn log was not cut. *)
Covered(k) == \E i \in 1..Len(log) : /\ log[i].cause \in {"read", "skip"} /\ log[i].tl = tid
                                      /\ log[i].from <= k /\ k <= log[i].pos
PassedNow == 1..(IF Last.pos < closed THEN Last.pos ELSE closed)
NoUnreadPassedWithoutLoss ==
  (HasLog /\ Last.tl = tid /\ c.cut = 0) =>
    \A k \in PassedNow : Covered(k) \/ (c.breaklog > 0 /\ \E i \in AdoptLines : log[i].tl = tid /\ k <= log[i].pos)
(* The same with one exemption only: Adopt found no line that parses. For AdoptPos = "prev". *)
NoUnitPassedUnread ==
  (HasLog /\ Last.tl = tid /\ c.cut = 0) =>
    \A k \in PassedNow : Covered(k) \/ \E i \in AdoptLines : log[i].from < 0 /\ log[i].tl = tid /\ k <= log[i].pos
(* A line that Adopt wrote is written only in Stopped Log_diverged and Stopped Log_unreadable. *)
AdoptStep == Len(log') > Len(log) /\ log'[Len(log')].cause \in {"adopt", "started_adopt"}
AdoptOnlyInTwoStops == [][AdoptStep => (m.state = "Stopped" /\ m.stop \in {"diverged", "log_unreadable"})]_vars
(* While the writer boots the only line written is Started. *)
OnlyStartedWhileBooting ==
  [][(m.state = "Booting" /\ Len(log') > Len(log)) => log'[Len(log')].cause = "started"]_vars
(* The Keeper is never held down by its writer. *)
KeeperNeverWaits == m.state # "Retired" => keeperUp
(* The weaker form, for the deleted start rules: a writer that stopped does not hold its Keeper down. *)
KeeperRunsWhenWriterStopped == m.state = "Stopped" => keeperUp
(* The premise of the split by turn lines, false by design: a turn line exists only after a Started was written once. *)
TurnLineOnlyAfterStarted == HasTurnLine => c.started = 1
(* A unit is read twice only after the commit log was deleted or its tail stopped parsing
   (for behaviours with no Restart_reading and no cut or replaced turn log). *)
ReadAgainOnlyAfterLoss == (c.cut = 0 /\ c.replace = 0 /\ c.restart = 0 /\ c.again # 0) => (lost \/ c.breaklog > 0)
(* A fresh start with no line: a unit that no read or skip line covered left the turn log, the writer
   reads on in the turn log of now, and no line of the commit log says so. Reached only when the turn
   log was deleted and the commit log too, or the turn log was deleted before any commit log was
   written (or the turn log was cut, another step outside the product). *)
SilentFresh == /\ c.ungone = 1 /\ HasLog /\ m.state \in Running /\ m.tl = tid /\ m.pos <= closed
               /\ \A i \in 1..Len(log) : log[i].cause \notin {"restart", "started_adopt"}
FreshOnlyByDeletingBoth == SilentFresh => ((c.replace > 0 /\ (lost \/ c.rnl = 1)) \/ c.cut > 0)
(* The narrower sentence, false: "only when both files were deleted". *)
FreshOnlyWhenBothWereDeleted == SilentFresh => ((c.replace > 0 /\ lost) \/ c.cut > 0)
(* A Write that waited for the boot does not wait for ever. *)
QueuedWriteEnds == [](WriteMsgs # {} => <>(WriteMsgs = {}))
(* When the writer keeps running, everything is read: no operator act is needed after the boot. *)
ReadsAllOnceRunning == (<>[](m.state \in Running)) => <>[](m.state = "Idle" /\ ~Unread(m))

(* ---- the reader ---- *)
(* The reader returns Nothing_to_ask only where the writer's "something unread" is false on the same bytes. *)
NothingOnlyWhenNothingUnread == \A msg \in mailbox : msg.res = "nothing" => ~msg.flag
(* No run of asks with no pulse, no commit and no outside event between is longer than the
   refusals, the cuts and four more allow. *)
NoAskLoop == c.chain <= MaxRefuse + MaxCut + 4
(* Idle with something unread, the lane on and nothing in flight: some operator act is accepted
   (the cfg must give each act one use). *)
IdleUnreadHasAnAct ==
  (m.state = "Idle" /\ Unread(m) /\ Q(m.lane) # 0 /\ ~InFlight) =>
    (ENABLED SkipItem \/ ENABLED SkipLine \/ ENABLED RestartReading \/ ENABLED Resume)

(* ---- a result on a lane that is no longer held ---- *)
ForeignLaneOncePerChange == c.fl <= c.decl
NoRestOnForeignLane == ~(m.state = "Resting" /\ c.gl = "noout")

(* Make_room is asked only right after an alone commit, and never holds reading back. *)
RoomOnlyAfterAlone == (m.state = "Asking" /\ m.asked = "room") => m.alone

AskNoBound == c.gid <= MaxAskNo

(* DrainsWithoutOperator: a lane that is silent or refuses a finite number of rounds and then
   answers ends with everything read and no operator act (every operator bound is 0). *)
DrainsWithoutOperator == <>[](m.state = "Idle" /\ ~Unread(m))

(* EveryAskEnds: the writer does not sit in Asking on one ask for ever. *)
EveryAskEnds ==
  \A n \in 1..MaxAskNo : [](m.askNo = n => <>(m.askNo # n))

(* A write in Refused_at_bottom starts the asks that judge the new Memory;
   E2 is off and W1 is on from that step. *)
RaBWriteJudged == m.state = "RaB" /\ m'.state = "Asking" /\ m'.facts # m.facts
RaBWriteIsWarn == [][RaBWriteJudged => (~E2' /\ W1')]_vars
NeverRaBWriteJudged == [][~RaBWriteJudged]_vars

(* Parks at warn only, by class; each "ends by itself" is the leads-to below. *)
WarnPark == Park /\ ~ErrorOn
WP_LaneOff   == WarnPark /\ Q(m.lane) = 0
WP_Booting   == WarnPark /\ m.state = "Booting"
WP_Wide      == WarnPark /\ m.state = "Resting" /\ ~m.lastOne
WP_OneSilent == WarnPark /\ m.state = "Resting" /\ m.lastOne /\ m.lastSil
WP_OneStale  == WarnPark /\ m.state = "Resting" /\ m.lastOne /\ ~m.lastSil
WP_Other     == WarnPark /\ ~(Q(m.lane) = 0 \/ m.state \in {"Booting", "Resting"})
LaneOffEnds   == [](WP_LaneOff => <>(~WP_LaneOff))
BootingEnds   == [](WP_Booting => <>(~WP_Booting))
WideEnds      == [](WP_Wide => <>(~WP_Wide))
OneSilentEnds == [](WP_OneSilent => <>(~WP_OneSilent))
OneStaleEnds  == [](WP_OneStale => <>(~WP_OneStale))
E4Ends        == []((Park /\ E4) => <>(~E4))
NoOtherWarnPark == ~WP_Other

(* Prints one line per distinct state that is a park: state, stop, lane on, last, one item, a slot silent,
   basis is the snapshot now, held, E1, E2, E3, E4, E5, W1, W3. *)
ParkPrint ==
  Park => PrintT(<< "PARK", m.state, m.stop, Q(m.lane) # 0, m.last, m.lastOne, m.lastSil,
                    m.lastBasis = m.facts, held, E1, E2, E3, E4, E5, W1, W3 >>)

(* Reachability witnesses: each must be VIOLATED, so the passes are not vacuous. *)
NeverRaB            == m.state # "RaB"
NeverAloneCommit    == ~m.alone
NeverRoomLine       == \A i \in 1..Len(log) : log[i].cause # "room"
NeverFitsNone       == m.room # "fits_none"
NeverAdoptLine      == \A i \in 1..Len(log) : log[i].cause # "adopt"
NeverAdoptStarted   == \A i \in 1..Len(log) : log[i].cause # "started_adopt"
NeverRestartLine    == \A i \in 1..Len(log) : log[i].cause # "restart"
NeverSkipLine       == \A i \in 1..Len(log) : log[i].cause # "skip"
NeverUnwritable     == m.stop # "unwritable"
NeverMemUnreadable  == m.stop # "mem_unreadable"
NeverLogUnreadable  == m.stop # "log_unreadable"
NeverDiverged       == m.stop # "diverged"
NeverLagging        == HasLog => snap = Last.after
NeverStaleMessage   == \A msg \in AskMsgs : m.state = "Asking" /\ msg.no = m.askNo
NeverOpActInIdle    == ~(m.state = "Idle" /\ HasLog /\ Last.cause \in {"skip", "restart"} /\ Q(m.lane) = 0)
NeverSlotsChangeInFlight == ~(m.state = "Asking" /\ m.askLane # m.lane)
NeverFaultRest      == ~(m.state = "Resting" /\ m.last = "fault")
NeverKeeperDownStopped == ~(m.state = "Stopped" /\ ~keeperUp /\ lost)
\* A
NeverKeeperRunsInLogUnreadable == ~(m.state = "Stopped" /\ m.stop = "log_unreadable" /\ keeperUp /\ closed > m.stopEnd)
NeverResetReadAfterFirstBoot ==
  ~(HasLog /\ log[1].cause = "started" /\
    \E i \in 2..Len(log) : log[i].cause = "read" /\ \E k \in log[i].from..log[i].pos : k <= closed /\ kinds[k] = "ritem")
NeverStartedAfterStoppedFirstBootAndReset ==
  ~(c.fbstop = 1 /\ c.reset > 0 /\ HasLog /\ log[1].cause = "started" /\ ~lost)
NeverLostTakenForFirstBoot == ~(HasLog /\ lost /\ log[1].cause = "started")
NeverReadAgain      == c.again = 0
NeverTurnReadAgain  == c.again # 2
NeverAdoptPassesUnread ==
  \A i \in AdoptLines : log[i].tl # tid \/ \A k \in 1..(IF log[i].pos < closed THEN log[i].pos ELSE closed) : Covered(k)
NeverFirstBootWriteFails == ~(m.state = "Stopped" /\ m.stop = "unwritable" /\ c.fbstop = 1 /\ c.lock = 0)
NeverTurnWhileBooting == c.tb = 0
NeverTurnWhileStopped == c.ts = 0
NeverTurnWhileFirstBootStopped == ~(c.ts = 1 /\ c.fbstop = 1 /\ c.started = 0 /\ closed > 0)
NeverEarlyTurnRead ==
  ~(c.early > 0 /\ c.replace = 0 /\ c.cut = 0 /\
    \E i \in 1..Len(log) : log[i].cause = "read" /\ log[i].tl = tid /\ log[i].from <= c.early /\ c.early <= log[i].pos)
NeverEarlyTurnReadAfterStoppedFirstBoot == NeverEarlyTurnRead \/ c.fbstop = 0
NeverSilentFresh    == ~SilentFresh
NeverMemoryBehindLostLog == ~(lost /\ HasLog /\ log[1].cause = "started" /\ c.foreign = 0 /\ log[1].after # c.tloss)
NeverForeignTakenWithoutAdopt ==
  ~(lost /\ HasLog /\ log[1].cause = "started" /\ c.foreign > 0 /\ log[1].after # c.tloss /\ m.state \in Running)
NeverRetractUndoneBySecondReading ==
  ~(lost /\ \E i \in 1..Len(log) : log[i].cause = "read" /\ log[i].added \cap c.rloss # {})
NeverCommitOnGoneLog == ~(m.state = "Stopped" /\ m.stop = "unwritable" /\ ~HasLog /\ lost /\ c.io = 0 /\ c.lock = 0 /\ c.started = 1)
NeverRunningOnGoneLog == ~(m.state \in Running /\ ~HasLog)
NeverQueuedWriteCommitted == \A i \in 1..Len(log) : ~(log[i].cause = "direct" /\ log[i].from < 0)
NeverQueuedWriteRefused == c.wqr = 0
NeverQueuedWrite    == WriteMsgs = {}
NeverAdoptOnARepairedTail == c.stale = 0
NeverBadLineInTheMiddle == \A i \in 1..(Len(log) - 1) : ~log[i].bad
\* B
NeverFaultBehindItemless ==
  ~(m.state = "Resting" /\ m.last = "fault" /\ tid = m.tl /\ m.pos < closed /\ IsNone(kinds[m.pos + 1]))
NeverSkipPassesItemless == \A i \in 1..Len(log) : log[i].cause = "skip" => log[i].pos = log[i].from
NeverReadPassesItemless ==
  \A i \in 1..Len(log) : log[i].cause = "read" => ~\E k \in log[i].from..log[i].pos : k <= closed /\ IsNone(kinds[k])
NeverIdleWithItemlessTail == ~(m.state = "Idle" /\ tid = m.tl /\ m.pos < closed /\ ~Unread(m))
NeverNothing        == \A msg \in mailbox : msg.res # "nothing"
\* C
NeverE4             == ~E4
NeverE4OffAfterWrite == ~(OneItemRefusal /\ ~m.lastSil /\ m.lastBasis # m.facts)
NeverRestWithSilentSlotAtOneItem == ~(OneItemRefusal /\ m.lastSil)
NeverE5             == ~E5
NeverE5OffByMemory  == ~(m.room = "fits_none" /\ m.roomMem # m.facts)
NeverE5OffByLane    == ~(m.room = "fits_none" /\ m.roomLane # m.lane)
NeverE5OffNothingPending ==
  ~(m.room = "fits_none" /\ m.roomMem # m.facts /\ m.roomLane = m.lane /\ m.alone /\ m.state = "Idle"
    /\ Q(m.lane) # 0 /\ ~Unread(m) /\ ~InFlight /\ fibers = {} /\ mailbox = {})
\* D
NeverForeignLaneResult           == c.fl = 0

(***************************************************************************)
(* The registry, Adopt at the start, skips that empty `last`               *)
(***************************************************************************)
(* OneLiveWriter: the registry never pushes a live writer out, so one Keeper has at most one;
   the lock (an OS lock, one holder by its nature) is taken by that one only. *)
OneLiveWriter == c.orphans = 0
(* RegisteredHasWriter, safety form: a Write for a registered Keeper always reaches a live writer. *)
RegisteredWriteReachesAWriter == c.wra = 0
(* RegisteredHasWriter: a Keeper that stays registered gets a live writer (under the pulse's fairness). *)
RegisteredHasWriter == []((reg /\ ~Live) => <>(Live \/ ~reg))
(* The stronger form, which RetireRule = "always" does not give: a Write sent while the Keeper was
   registered is refused Keeper_retired only when the Keeper was unregistered after the Write was sent. *)
RefusedRetiredOnlyAfterUnregister == c.wrr = 0
(* UnregisteredNotRead: once a Keeper is not registered and its writer is gone, it has no writer
   (so no ask starts) until it is registered again. *)
UnregisteredNotRead == (~reg /\ c.off = 1) => (~Live /\ fibers = {})
(* PassedAccounted: every unit the position has passed is named in a read or a skip line. No exception. *)
PassedAccounted == (HasLog /\ Last.tl = tid /\ c.cut = 0) => \A k \in PassedNow : Covered(k)
(* BootingReadFlagged: a Memory read answered while the writer is Booting carries the mark, and the
   snapshot it reads is at most one commit behind the log. *)
Marked == IF ReadMark = "booting" THEN m.state = "Booting" ELSE m.state \notin Running
Untouched == c.foreign = 0 /\ c.badsnap = 0 /\ HasLog           \* nothing outside the product rewrote the snapshot
BootingReadFlagged == (Untouched /\ m.state = "Booting") => (Marked /\ snap \in { Last.after, Last.basis })
(* The other half, which ReadMark = "booting" does not give: a read with no mark and no stop reason sees the Memory of the last line. *)
UnmarkedReadIsChecked == (Untouched /\ ~Marked /\ m.state # "Stopped") => snap = Last.after
(* E3 and E4 stand only on a result about the head the position is at now. *)
OnHead == m.lastPos = m.pos /\ m.lastTl = m.tl
E3OnHeadLine == E3 => OnHead
E4OnHeadLine == E4 => OnHead
\* witnesses
NeverWriteByANewWriter == c.wnew = 0                 \* a Keeper stopped and turned on again; a new writer commits its Write
NeverRemade == c.remade = 0
NeverSecondReadingAfterAdopt ==
  ~\E i, a, j \in 1..Len(log) : /\ i < a /\ a < j /\ log[i].cause = "read" /\ log[a].cause = "started_adopt"
                                /\ log[j].cause = "read" /\ log[j].tl = log[i].tl /\ log[j].from <= log[i].pos
NeverAskWhileUnregistered == ~(~reg /\ m.state = "Asking")
NeverUnregisteredWriteCommitted == c.wun = 0
NeverNoWriterWhileRegistered == ~(reg /\ ~Live /\ closed > 0)
NeverRetireWaitsForBoot == ~(m.state = "Booting" /\ m.retq)
NeverW1AfterSkipOfAFault ==
  ~(c.sef = 1 /\ HasLog /\ Last.cause \in {"skip", "restart"} /\ m.last = "none" /\ Unread(m) /\ m.state \in Running)
NeverUnmarkedBehind == ~(Untouched /\ ~Live /\ snap # Last.after)

=============================================================================
