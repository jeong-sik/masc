---------------------------- MODULE CuratorNarrow -----------------------------
(*****************************************************************************)
(* The World Memory curator's classification stage: which batch it asks      *)
(* next after a walk ends with no answer, which fact it sets aside, and what *)
(* it remembers between passes (RFC curator-narrows-a-refused-batch          *)
(* sections 4.1 to 4.4 and 8.1). The curator had no model before this one.   *)
(*                                                                           *)
(* A run is the facts of every Keeper that the ledger has no disposition     *)
(* for. A pass takes work from a list. An ask walks the lane's slots in      *)
(* order with one batch and stops at the first answer. Every call may say    *)
(* any outcome, so the properties hold for every slot behaviour of this      *)
(* size. Quiet is the exception: a mute slot says nothing else, and the      *)
(* other slots say it at most MaxQuiet times in a run.                       *)
(*                                                                           *)
(* Names, model = code and RFC                                               *)
(*   Facts, a smaller id is older                                            *)
(*                    Ledger.pending_fact of reconciliation.new_facts, in    *)
(*                    the order Ledger.reconcile gives                       *)
(*   Order, Slots     the slots Exact_lane_slots.walk visits, in order       *)
(*   outcome          the slot outcome table of RFC 4.1 and 4.7:             *)
(*                    "Sized" Refused (Sized _), "Unsized" Refused Unsized,  *)
(*                    "Unusable" Silent (Unusable _) or the new overdue      *)
(*                    branch, "Quiet" every other Silent _                   *)
(*   gen              the lane generation                                    *)
(*                    (Registry.catalog_generation_fingerprint), which also  *)
(*                    stands for a restart, a prompt change and an           *)
(*                    operator's request to ask again (RFC 4.3)              *)
(*   size             owner.classification_size: 0 is Fill_frame, n is       *)
(*                    Up_to n                                                *)
(*   OlderHalf        Workspace_memory_request.narrow, the older             *)
(*                    floor(n / 2) rows                                      *)
(*   Cut              Workspace_memory_request.prepare with Up_to n          *)
(*   StartPass        "commit": a pass woken by a Keeper Memory commit;      *)
(*                    "tick": a pass woken by the 60 s maintenance tick      *)
(*                    (retry_pending_observations)                           *)
(*                                                                           *)
(* Names with no code yet (RFC layer L3)                                     *)
(*   places           the narrowed places: the batches narrowing made that   *)
(*                    no slot answered, kept as they are                     *)
(*   refused          the bottom memory: << fact, slot >> for every slot     *)
(*                    that refused the one-fact request. It replaces         *)
(*                    owner.indivisible_facts                                *)
(*   SetAside         the facts every slot refused alone                     *)
(*   quiet            the facts of a batch that was never narrowed and met   *)
(*                    only quiet slots. RFC 4.1 keeps no such batch. RFC 4.4 *)
(*                    asks waiting facts again only on a tick, so the        *)
(*                    curator has to know these facts wait: without this     *)
(*                    set a commit-woken pass takes them for new facts and   *)
(*                    asks them again (bug no_quiet_memory)                  *)
(*   chain            "fresh": no batch holding these facts was narrowed;    *)
(*                    "sized": every narrowing above it had sized refusals   *)
(*                    and quiet slots only; "other": some narrowing above    *)
(*                    it had an unsized refusal or an unusable answer        *)
(*   passGen          the generation a pass read when it started             *)
(*                                                                           *)
(* Ghosts                                                                    *)
(*   said             what the walks of a generation heard, kept only as     *)
(*                    far as a property reads it:                            *)
(*                    << gen, "refused", slot, {fact} >> a slot refused the  *)
(*                    one-fact request; << gen, "refused", "any", batch >>   *)
(*                    some slot refused the batch; << gen, "narrowed",       *)
(*                    "sized" | "other", batch >> the batch was narrowed,    *)
(*                    on sized refusals only or not; << gen, "heard",        *)
(*                    "any", {fact} >> a slot had a word for the fact alone  *)
(*   due              the facts a pass took when it started                  *)
(*   parked           the facts an ask left waiting since the last tick      *)
(*                    pass started                                           *)
(*                                                                           *)
(* Properties                                                                *)
(*   NoResendOfRefused          no slot is walked with a batch it refused    *)
(*                              in this generation. One fact is a batch      *)
(*   PassSettlesItsFacts        a pass ends with each fact it took           *)
(*                              classified, in a narrowed place or waiting   *)
(*                              for the tick                                 *)
(*   SetAsideOnlyWhenAllRefused a fact set aside was refused alone by every  *)
(*                              slot in this generation                      *)
(*   MemoryIsOfThisGeneration   the bottom memory and the places rest on     *)
(*                              calls of this generation                     *)
(*   SizeOnlyFromSizedRefusals  the kept size changes only when a batch is   *)
(*                              answered whose narrowing had sized refusals  *)
(*                              only                                         *)
(*   ResetEmptiesMemory         a new generation starts with no bottom       *)
(*                              memory, place, waiting fact or size          *)
(*   ReaskOnlyOnTick            a fact an ask left waiting is in no batch    *)
(*                              until a tick pass starts                     *)
(*   RefusalsWithinTwoNMinusOne at most 2N - 1 batches of N facts are        *)
(*                              refused in a generation                      *)
(*   Settles (FairSpec)         when a slot is not mute, every fact is       *)
(*                              classified or comes to stand alone at the    *)
(*                              bottom, whatever the other facts do          *)
(*                                                                           *)
(* Bugs: SpecBuggy adds the BugAction the constant Bug names                 *)
(*   resend             a refused batch is kept whole and asked again, as    *)
(*                      the 60 s resend does today                           *)
(*                                             -> NoResendOfRefused, Settles *)
(*   fail_fast          a refusal ends the pass and nothing is kept, as      *)
(*                      Failed does today      -> PassSettlesItsFacts        *)
(*   aside_on_unusable  an unusable answer or a quiet slot counts as that    *)
(*                      slot's refusal         -> SetAsideOnlyWhenAllRefused *)
(*   size_after_unsized the size is kept after a narrowing that had an       *)
(*                      unsized refusal, as today                            *)
(*                                             -> SizeOnlyFromSizedRefusals  *)
(*   keep_floor         a new generation keeps the bottom memory and the     *)
(*                      places                 -> ResetEmptiesMemory         *)
(*   late_write         a pass that started before the generation changed    *)
(*                      goes on and writes what it hears, as a prompt        *)
(*                      change during a pass does today                      *)
(*                                             -> MemoryIsOfThisGeneration   *)
(*   no_quiet_memory    a fresh batch that met only quiet slots leaves no    *)
(*                      mark                   -> ReaskOnlyOnTick            *)
(*   rebuild_from_all   after the older half the next batch is made from     *)
(*                      every fact left, as today                            *)
(*                                             -> RefusalsWithinTwoNMinusOne *)
(*                                                                           *)
(* Not modelled                                                              *)
(*   - The briefing stage (RFC 4.5), step_end and its projection (4.6).      *)
(*   - A fact that leaves new_facts. If it returns under the same ref its    *)
(*     marks are gone and it is asked once more.                             *)
(*   - Arrival out of age order: a fact arrives after every older fact.      *)
(*   - A call's answer that the ledger then fails to commit, and a host      *)
(*     failure (store, ledger, log).                                         *)
(*   - A generation change takes the memory at once and ends the pass in     *)
(*     flight. The code reads the lane's generation when a pass starts; a    *)
(*     prompt change empties the memory during a pass (bug late_write is     *)
(*     that interleaving). What the ledger does with an answer that comes    *)
(*     back after the change is not modelled.                                *)
(*   - No property says whether the kept size may grow. It does when a       *)
(*     remembered place larger than it is answered.                          *)
(*                                                                           *)
(* No rule here ends a state because time passed, and none holds an act      *)
(* back by a count. MaxGen and MaxQuiet say how often the environment acts.  *)
(*****************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
  Facts,     \* fact ids; a smaller id is an older fact
  Order,     \* the lane's slots, in the order a walk visits them
  Mute,      \* slots that say nothing to any request (auth, billing, not admitted)
  MaxGen,    \* generations 1..MaxGen
  MaxQuiet,  \* calls a slot that is not mute leaves without a word (429, 5xx, transport)
  Bug        \* read by SpecBuggy only

VARIABLES
  arrived,     \* facts the Keepers have committed
  classified,  \* facts the ledger holds a disposition for
  gen,         \* the generation now
  places,      \* narrowed places: [fs, chain]
  refused,     \* the bottom memory: << fact, slot >>
  quiet,       \* facts of a fresh batch that met only quiet slots
  size,        \* the kept size; 0 is none
  phase,       \* "idle" | "pass"
  passGen,     \* the generation the pass in flight started on
  todo,        \* the pass's work list: [fs, chain, asis]
  said,        \* ghost: << gen, kind, who, batch >>
  due,         \* ghost: the facts the pass took at its start
  parked,      \* ghost: facts left waiting since the last tick pass started
  quietCalls   \* how many calls of a slot that is not mute were quiet

vars == << arrived, classified, gen, places, refused, quiet, size,
           phase, passGen, todo, said, due, parked, quietCalls >>

Slots    == { Order[i] : i \in DOMAIN Order }
Outcomes == {"Answered", "Sized", "Unsized", "Unusable", "Quiet"}
Refusals == {"Sized", "Unsized"}
Heard    == Refusals \cup {"Unusable"}
Chains   == {"fresh", "sized", "other"}

ASSUME Facts \subseteq Nat /\ Facts # {}
ASSUME Mute \subseteq Slots /\ Slots # {}
ASSUME MaxGen \in Nat \ {0} /\ MaxQuiet \in Nat

(* Constants for the cfgs. *)
Facts3  == 1..3
Facts4  == 1..4
OrderAB == << "a", "b" >>
OrderA  == << "a" >>

Pos(s)       == CHOOSE i \in DOMAIN Order : Order[i] = s
Before(s, t) == Pos(s) < Pos(t)
Min(S)       == CHOOSE x \in S : \A y \in S : x <= y
One(S)       == CHOOSE x \in S : TRUE

RECURSIVE Oldest(_, _)
Oldest(S, k) == IF k = 0 \/ S = {} THEN {}
                ELSE LET m == Min(S) IN {m} \cup Oldest(S \ {m}, k - 1)
OlderHalf(S) == Oldest(S, Cardinality(S) \div 2)

Item(F, c, a) == [fs |-> F, chain |-> c, asis |-> a]

Pending  == arrived \ classified
InPlaces == UNION { p.fs : p \in places }
New      == Pending \ (InPlaces \cup quiet)

(* A one-fact request walks the slots that have not refused it. *)
Unrefused(f) == { s \in Slots : << f, s >> \notin refused }
Walked(F)    == IF Cardinality(F) = 1 THEN Unrefused(One(F)) ELSE Slots

(* A place waits for the tick unless it is one fact that every slot refused. *)
WaitingPlace(p) == Cardinality(p.fs) > 1 \/ Unrefused(One(p.fs)) # {}
SetAside        == { One(p.fs) : p \in { q \in places : ~WaitingPlace(q) } }
Waiting         == quiet # {} \/ \E p \in places : WaitingPlace(p)

RECURSIVE PlaceSeq(_)
PlaceSeq(P) ==
  IF P = {} THEN << >>
  ELSE LET p == CHOOSE x \in P : \A y \in P : Min(x.fs) <= Min(y.fs)
       IN << Item(p.fs, p.chain, TRUE) >> \o PlaceSeq(P \ {p})

Init ==
  /\ arrived = {} /\ classified = {} /\ gen = 1
  /\ places = {} /\ refused = {} /\ quiet = {} /\ size = 0
  /\ phase = "idle" /\ passGen = 1 /\ todo = << >>
  /\ said = {} /\ due = {} /\ parked = {} /\ quietCalls = 0

(* A Keeper commits a fact. A pass reads the new facts when it starts, so a
   fact that arrives during a pass is the same as one that arrives after it. *)
Arrive ==
  /\ phase = "idle"
  /\ Facts \ arrived # {}
  /\ arrived' = arrived \cup { Min(Facts \ arrived) }
  /\ UNCHANGED << classified, gen, places, refused, quiet, size,
                  phase, passGen, todo, said, due, parked, quietCalls >>

(* A commit-woken pass takes the new facts. A tick pass takes the new facts
   with the quiet ones as one fresh pool, and then every waiting place. *)
StartPass(w) ==
  /\ phase = "idle"
  /\ IF w = "tick" THEN Waiting ELSE New # {}
  /\ LET pool == IF w = "tick" THEN New \cup quiet ELSE New
         back == IF w = "tick" THEN { p \in places : WaitingPlace(p) } ELSE {}
     IN /\ todo' = (IF pool = {} THEN << >> ELSE << Item(pool, "fresh", FALSE) >>)
                   \o PlaceSeq(back)
        /\ due' = pool \cup UNION { p.fs : p \in back }
  /\ quiet'  = IF w = "tick" THEN {} ELSE quiet
  /\ parked' = IF w = "tick" THEN {} ELSE parked
  /\ phase' = "pass" /\ passGen' = gen
  /\ UNCHANGED << arrived, classified, gen, places, refused, size, said, quietCalls >>

(* A batch that is made, not kept as it is, holds no more facts than the
   kept size. *)
CanAsk(h) == h.asis \/ size = 0 \/ Cardinality(h.fs) <= size
Cut ==
  /\ phase = "pass" /\ todo # << >> /\ ~CanAsk(Head(todo))
  /\ LET h     == Head(todo)
         first == Oldest(h.fs, size)
     IN todo' = << Item(first, h.chain, TRUE), Item(h.fs \ first, h.chain, FALSE) >>
                \o Tail(todo)
  /\ UNCHANGED << arrived, classified, gen, places, refused, quiet, size,
                  phase, passGen, said, due, parked, quietCalls >>

(* A slot answered: the ledger takes the batch's dispositions. *)
Commit(rule, h) ==
  /\ classified' = classified \cup h.fs
  /\ places'  = { p \in places : p.fs # h.fs }
  /\ refused' = { x \in refused : x[1] \notin h.fs }
  /\ size' = IF h.chain = "sized" \/ (rule = "size_after_unsized" /\ h.chain = "other")
               THEN Cardinality(h.fs) ELSE size
  /\ todo' = Tail(todo)
  /\ parked' = parked \ h.fs
  /\ UNCHANGED quiet

(* Two facts or more, and a slot refused, answered unusably or ran over its
   deadline: the older half is asked next, then the newer half alone. *)
Narrow(rule, h, o, called, refusers) ==
  LET F      == h.fs
      chain2 == IF h.chain # "other" /\ \A s \in called : o[s] \in {"Sized", "Quiet"}
                  THEN "sized" ELSE "other"
      older  == OlderHalf(F)
      rest   == Tail(todo)
  IN
  IF rule = "resend" /\ refusers # {} THEN
    /\ places' = { p \in places : p.fs # F } \cup { [fs |-> F, chain |-> h.chain] }
    /\ todo' = rest
    /\ UNCHANGED << classified, refused, quiet, size, parked >>
  ELSE IF rule = "fail_fast" /\ refusers # {} THEN
    /\ todo' = << >>
    /\ UNCHANGED << classified, places, refused, quiet, size, parked >>
  ELSE
    /\ places' = { p \in places : p.fs # F }
    /\ todo' = IF rule = "rebuild_from_all" /\ rest # << >> /\ ~Head(rest).asis
                 THEN << Item(older, chain2, TRUE),
                         Item((F \ older) \cup Head(rest).fs, chain2, FALSE) >> \o Tail(rest)
                 ELSE << Item(older, chain2, TRUE), Item(F \ older, chain2, FALSE) >> \o rest
    /\ UNCHANGED << classified, refused, quiet, size, parked >>

(* Two facts or more, and no slot had a word: nothing is narrowed. A batch
   narrowing made is kept as it is. A fresh one leaves only its facts. *)
AllQuiet(rule, h) ==
  /\ IF h.chain = "fresh"
       THEN /\ quiet' = IF rule = "no_quiet_memory" THEN quiet ELSE quiet \cup h.fs
            /\ UNCHANGED places
       ELSE /\ places' = places \cup { [fs |-> h.fs, chain |-> h.chain] }
            /\ UNCHANGED quiet
  /\ todo' = Tail(todo)
  /\ parked' = parked \cup h.fs
  /\ UNCHANGED << classified, refused, size >>

(* One fact, and no answer: the slots that refused it are kept, and it stays
   alone. A fresh fact that met only quiet slots leaves no mark of its own. *)
Bottom(rule, h, o, called, refusers) ==
  LET f     == One(h.fs)
      spoke == \E s \in called : o[s] # "Quiet"
      fixed == \E p \in places : p.fs = h.fs
      marks == IF rule = "aside_on_unusable" THEN called ELSE refusers
  IN
  /\ IF h.chain = "fresh" /\ ~spoke /\ ~fixed
       THEN /\ quiet' = IF rule = "no_quiet_memory" THEN quiet ELSE quiet \cup h.fs
            /\ UNCHANGED << places, refused >>
       ELSE /\ places' = { p \in places : p.fs # h.fs } \cup { [fs |-> h.fs, chain |-> h.chain] }
            /\ refused' = refused \cup { << f, s >> : s \in marks }
            /\ UNCHANGED quiet
  /\ todo' = Tail(todo)
  /\ parked' = parked \cup h.fs
  /\ UNCHANGED << classified, size >>

(* One walk with the head of the list. rule is "none" in Next; a BugAction
   passes the name of its bug. *)
Ask(rule) ==
  /\ phase = "pass" /\ todo # << >> /\ CanAsk(Head(todo))
  /\ LET h == Head(todo)
         F == h.fs
         W == Walked(F)
     IN
     /\ W # {}
     /\ \E o \in [W -> Outcomes] :
          LET called   == { s \in W : \A t \in W : Before(t, s) => o[t] # "Answered" }
              answered == \E s \in called : o[s] = "Answered"
              heard    == { s \in called : o[s] \in Heard }
              refusers == { s \in called : o[s] \in Refusals }
              hushes   == Cardinality({ s \in called \ Mute : o[s] = "Quiet" })
              spoke    == \E s \in called : o[s] # "Quiet"
              stepKind == IF \A s \in called : o[s] \in {"Sized", "Quiet"} THEN "sized" ELSE "other"
              stops    == rule \in {"resend", "fail_fast"} /\ refusers # {}
              marks    ==
                IF answered THEN {}
                ELSE IF Cardinality(F) > 1 THEN
                  (IF refusers # {} THEN { << passGen, "refused", "any", F >> } ELSE {})
                  \cup (IF heard # {} /\ ~stops THEN { << passGen, "narrowed", stepKind, F >> } ELSE {})
                ELSE { << passGen, "refused", s, F >> : s \in refusers }
                     \cup (IF spoke THEN { << passGen, "heard", "any", F >> } ELSE {})
          IN
          /\ \A s \in W \ called : o[s] = "Quiet"
          /\ \A s \in W \cap Mute : o[s] = "Quiet"
          /\ quietCalls + hushes <= MaxQuiet
          /\ quietCalls' = quietCalls + hushes
          /\ said' = said \cup marks
          /\ UNCHANGED << arrived, gen, phase, passGen, due >>
          /\ IF answered THEN Commit(rule, h)
             ELSE IF Cardinality(F) > 1 /\ heard # {} THEN Narrow(rule, h, o, called, refusers)
             ELSE IF Cardinality(F) > 1 THEN AllQuiet(rule, h)
             ELSE Bottom(rule, h, o, called, refusers)

EndPass ==
  /\ phase = "pass" /\ todo = << >>
  /\ phase' = "idle" /\ due' = {}
  /\ UNCHANGED << arrived, classified, gen, places, refused, quiet, size,
                  passGen, todo, said, parked, quietCalls >>

(* A new generation: the memory is emptied, and a pass in flight ends
   without writing. *)
Reset(rule) ==
  /\ gen < MaxGen
  /\ gen' = gen + 1
  /\ IF rule = "keep_floor"
       THEN UNCHANGED << places, refused >>
       ELSE places' = {} /\ refused' = {}
  /\ quiet' = {} /\ size' = 0 /\ parked' = {}
  /\ IF rule = "late_write" /\ phase = "pass"
       THEN UNCHANGED << phase, todo, due >>
       ELSE phase' = "idle" /\ todo' = << >> /\ due' = {}
  /\ said' = IF rule = "late_write" THEN said ELSE {}
  /\ UNCHANGED << arrived, classified, passGen, quietCalls >>

Sys  == StartPass("commit") \/ StartPass("tick") \/ Cut \/ Ask("none") \/ EndPass
Next == Arrive \/ Sys \/ Reset("none")

BugAction ==
  \/ /\ Bug \in {"resend", "fail_fast", "aside_on_unusable", "size_after_unsized",
                 "no_quiet_memory", "rebuild_from_all"}
     /\ Ask(Bug)
  \/ /\ Bug \in {"keep_floor", "late_write"}
     /\ Reset(Bug)

NextBuggy == Next \/ BugAction

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

(* The pass and the tick go on: the owner fiber runs and the maintenance
   tick comes. *)
FairSpec      == Spec /\ WF_vars(Sys)
FairSpecBuggy == SpecBuggy /\ WF_vars(Sys \/ BugAction)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
  /\ arrived \subseteq Facts /\ classified \subseteq arrived
  /\ gen \in 1..MaxGen /\ passGen \in 1..MaxGen
  /\ places \subseteq [fs : SUBSET Facts, chain : Chains]
  /\ refused \subseteq Facts \X Slots
  /\ quiet \subseteq Facts
  /\ size \in 0..Cardinality(Facts)
  /\ phase \in {"idle", "pass"}
  /\ todo \in Seq([fs : SUBSET Facts, chain : Chains, asis : BOOLEAN])
  /\ said \subseteq (1..MaxGen) \X {"refused", "narrowed", "heard"}
                    \X (Slots \cup {"any", "sized", "other"}) \X (SUBSET Facts)
  /\ due \subseteq Facts /\ parked \subseteq Facts
  /\ quietCalls \in 0..MaxQuiet

(* The memory and the work list hold each pending fact at most once. *)
Shape ==
  /\ \A p, q \in places : p = q \/ p.fs \cap q.fs = {}
  /\ \A p \in places : p.fs # {} /\ (Cardinality(p.fs) > 1 => p.chain # "fresh")
  /\ InPlaces \subseteq Pending /\ quiet \subseteq Pending /\ InPlaces \cap quiet = {}
  /\ \A x \in refused : \E p \in places : p.fs = { x[1] }
  /\ \A i, j \in DOMAIN todo : i = j \/ todo[i].fs \cap todo[j].fs = {}
  /\ \A i \in DOMAIN todo :
       /\ todo[i].fs # {} /\ todo[i].fs \subseteq Pending /\ todo[i].fs \cap quiet = {}
       /\ \A p \in places : p.fs \cap todo[i].fs = {} \/ p.fs = todo[i].fs
  /\ phase = "idle" => todo = << >> /\ due = {}

RefusedAlone(g, s, f) == << g, "refused", s, {f} >> \in said
RefusedBatch(g, F)    == << g, "refused", "any", F >> \in said

NoResendOfRefused ==
  (phase = "pass" /\ todo # << >> /\ CanAsk(Head(todo))) =>
    LET F == Head(todo).fs IN
    IF Cardinality(F) = 1
      THEN \A s \in Walked(F) : ~RefusedAlone(passGen, s, One(F))
      ELSE ~RefusedBatch(passGen, F)

PassSettlesItsFacts ==
  [][ (phase = "pass" /\ phase' = "idle" /\ gen' = gen) =>
        \A f \in due : \/ f \in classified'
                       \/ f \in quiet'
                       \/ f \in UNION { p.fs : p \in places' } ]_vars

SetAsideOnlyWhenAllRefused ==
  \A f \in SetAside : \A s \in Slots : RefusedAlone(gen, s, f)

MemoryIsOfThisGeneration ==
  /\ \A x \in refused : RefusedAlone(gen, x[2], x[1])
  /\ \A p \in places : \E x \in said : x[1] = gen /\ p.fs \subseteq x[4]

SizeOnlyFromSizedRefusals ==
  [][ (size' # size /\ size' # 0) =>
        LET F == Head(todo).fs IN
        /\ Cardinality(F) = size'
        /\ \E x \in said : /\ x[1] = gen /\ x[2] = "narrowed" /\ x[3] = "sized"
                            /\ F \subseteq x[4] /\ F # x[4]
        /\ \A x \in said : (x[1] = gen /\ x[2] = "narrowed" /\ F \subseteq x[4] /\ F # x[4])
                              => x[3] = "sized" ]_vars

ResetEmptiesMemory ==
  [][ gen' # gen => places' = {} /\ refused' = {} /\ quiet' = {} /\ size' = 0 ]_vars

ReaskOnlyOnTick ==
  \A i \in DOMAIN todo : todo[i].fs \cap parked = {}

RefusalsWithinTwoNMinusOne ==
  \A g \in 1..MaxGen :
    Cardinality({ x[4] : x \in { y \in said : y[1] = g /\ y[2] = "refused" } })
      <= 2 * Cardinality(Facts) - 1

(* A fact is settled when the ledger holds it or it stands alone at the
   bottom. A poison fact, a refused batch and a slot that never speaks do
   not keep another fact from getting there. *)
AtBottom(f) == \E p \in places : p.fs = {f}
Settles == \A f \in Facts : (f \in arrived) ~> (f \in classified \/ AtBottom(f))

(* Reachability, each used in a -reachable-buggy cfg that must violate it. *)
NeverSetAside          == SetAside = {}
NeverWaitsOnOneSlot    == ~\E p \in places : Cardinality(p.fs) = 1 /\ WaitingPlace(p)
                                             /\ \E s \in Slots : << One(p.fs), s >> \in refused
NeverKeepsAQuietHalf   == ~\E p \in places : Cardinality(p.fs) > 1
NeverKeepsASize        == size = 0
NeverPassesAPoisonFact == ~(SetAside # {} /\ classified # {})
=============================================================================
