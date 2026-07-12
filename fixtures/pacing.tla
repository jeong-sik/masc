(* RFC-0313 W0: KeeperPacing TLA+ Spec (clean)
   Formal specification of the per-runtime revisit pacing algorithm.
   
   This spec defines the correct behavior of KeeperPacing:
   - Exponential backoff on consecutive failures
   - Cap on maximum delay
   - Success resets consecutive count
   - next_turn_due returns the earliest eligible runtime from catalog
   
   See lib/keeper/keeper_pacing.ml for the OCaml implementation.
*)

---- MODULE pacing ----
EXTENDS Integers, Reals, FiniteSets

(* === Constants === *)
CONSTANT Runtimes

(* === Variables === *)
(* pacing: mapping from runtime_id -> { eligible_at \in Real, consecutive \in Nat } *)
VARIABLES pacing, clock

(* === Definitions === *)
Policy == { base_sec \in Real+, multiplier \in Real+, cap_sec \in Real+ }

Revisit == { eligible_at \in Real+, consecutive \in Nat }

State == { pacing: [Runtimes -> Revisit], clock: Real+ }

(* === Actions === *)

(* on_failure: runtime fails, increment consecutive, compute delay *)
OnFailure(runtime, policy, retry_after) ==
  /\ clock' = clock + 0
  /\ IF runtime \in DOMAIN pacing
     THEN /\ new_consec = (pacing[runtime])\`consecutive + 1
          /\ delay = 
             IF retry_after \in DOMAIN retry_after
             THEN MIN(policy`cap_sec, MAX(0, retry_after[runtime]))
             ELSE MIN(policy`cap_sec, policy`base_sec * (policy`multiplier ** (new_consec - 1)))
          /\ pacing' = pacing \with runtime \-> 
                         <<clock + delay, new_consec>>
     ELSE /\ delay = MIN(policy`cap_sec, policy`base_sec * (policy`multiplier ** 0))
          /\ pacing' = pacing \with runtime \-> <<clock + delay, 1>>
  /\ UNCHANGED <<clock>>

(* on_success: runtime succeeds, remove from pacing *)
OnSuccess(runtime) ==
  /\ pacing' = [
       r \in (DOMAIN pacing \ {runtime}) |-> pacing[r]
     ]
  /\ UNCHANGED clock

(* next_turn_due: return the earliest eligible time from catalog *)
NextTurnDue(catalog) ==
  IF catalog = {}
  THEN clock
  ELSE \min { IF r \in DOMAIN pacing 
              THEN MAX(clock, (pacing[r])\`eligible_at)
              ELSE clock 
            : r \in catalog }

(* === Init === *)
Init == /\ pacing = [r \in Runtimes |-> [eligible_at |-> 0, consecutive |-> 0]]
        /\ clock = 0

(* === Next === *)
Next == \E r \in Runtimes, p \in Policy, ra \in [Runtimes -> Real+ \union {0}]:
           OnFailure(r, p, ra)
         \/ OnSuccess(r)

(* === Invariants === *)
PacingBounded ==
  /\ \A r \in DOMAIN pacing:
     /\ (pacing[r])\`eligible_at > clock
     /\ (pacing[r])\`consecutive >= 1
  /\ \A r \in DOMAIN pacing:
     /\ delay = (pacing[r])\`eligible_at - clock
     /\ delay <= policy`cap_sec

Spec == Init /\ [][Next]_<<pacing, clock>>

====