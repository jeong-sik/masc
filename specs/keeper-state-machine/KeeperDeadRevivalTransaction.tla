---------------- MODULE KeeperDeadRevivalTransaction ----------------
EXTENDS Naturals, TLC

CONSTANTS NoOwner, OwnerA, OwnerB

Owners == {NoOwner, OwnerA, OwnerB}
JournalStates == {"none", "reserved", "committed"}
DurableStates == {"dead", "revived"}
RegistryStates == {"dead", "absent", "live", "newer"}

VARIABLES owner, journal, durable, registry, launched

vars == <<owner, journal, durable, registry, launched>>

Init ==
  /\ owner = NoOwner
  /\ journal = "none"
  /\ durable = "dead"
  /\ registry \in {"dead", "absent"}
  /\ launched = FALSE

Acquire(candidate) ==
  /\ owner = NoOwner
  /\ journal = "none"
  /\ durable = "dead"
  /\ registry \in {"dead", "absent"}
  /\ owner' = candidate
  /\ journal' = "reserved"
  /\ UNCHANGED <<durable, registry, launched>>

RemoveOwnedDead ==
  /\ owner # NoOwner
  /\ journal = "reserved"
  /\ registry = "dead"
  /\ registry' = "absent"
  /\ UNCHANGED <<owner, journal, durable, launched>>

CommitDurable ==
  /\ owner # NoOwner
  /\ journal = "reserved"
  /\ registry = "absent"
  /\ durable' = "revived"
  /\ journal' = "committed"
  /\ UNCHANGED <<owner, registry, launched>>

Launch ==
  /\ owner # NoOwner
  /\ journal = "committed"
  /\ durable = "revived"
  /\ registry = "absent"
  /\ registry' = "live"
  /\ launched' = TRUE
  /\ UNCHANGED <<owner, journal, durable>>

Commit ==
  /\ owner # NoOwner
  /\ journal = "committed"
  /\ durable = "revived"
  /\ registry = "live"
  /\ launched
  /\ owner' = NoOwner
  /\ journal' = "none"
  /\ UNCHANGED <<durable, registry, launched>>

Rollback ==
  /\ owner # NoOwner
  /\ journal \in {"reserved", "committed"}
  /\ registry # "newer"
  /\ owner' = NoOwner
  /\ journal' = "none"
  /\ durable' = "dead"
  /\ registry' = IF registry = "dead" THEN "dead" ELSE "absent"
  /\ launched' = FALSE

Crash ==
  /\ owner # NoOwner
  /\ owner' = NoOwner
  /\ launched' = FALSE
  /\ registry' = "absent"
  /\ UNCHANGED <<journal, durable>>

Recover ==
  /\ owner = NoOwner
  /\ journal \in {"reserved", "committed"}
  /\ owner' = NoOwner
  /\ journal' = "none"
  /\ durable' = "dead"
  /\ registry' = "absent"
  /\ launched' = FALSE

RegisterNewer ==
  /\ owner = NoOwner
  /\ journal = "none"
  /\ durable = "dead"
  /\ registry' = "newer"
  /\ UNCHANGED <<owner, journal, durable, launched>>

PreserveNewer ==
  /\ registry = "newer"
  /\ UNCHANGED vars

PreserveLive ==
  /\ owner = NoOwner
  /\ journal = "none"
  /\ durable = "revived"
  /\ registry = "live"
  /\ launched
  /\ UNCHANGED vars

Next ==
  \/ Acquire(OwnerA)
  \/ Acquire(OwnerB)
  \/ RemoveOwnedDead
  \/ CommitDurable
  \/ Launch
  \/ Commit
  \/ Rollback
  \/ Crash
  \/ Recover
  \/ RegisterNewer
  \/ PreserveNewer
  \/ PreserveLive

TypeOK ==
  /\ owner \in Owners
  /\ journal \in JournalStates
  /\ durable \in DurableStates
  /\ registry \in RegistryStates
  /\ launched \in BOOLEAN

SingleOwner == owner \in Owners

NoUnjournaledPartialCommit ==
  (durable = "revived" /\ registry # "live") => journal = "committed"

LiveMatchesDurable == registry = "live" => durable = "revived"

NewerGenerationPreserved == registry = "newer" => owner = NoOwner

Spec == Init /\ [][Next]_vars

=============================================================================
