(** Keeper_memory_os_policy — Memory OS write-time merge behavior.

    The LLM librarian decides *what facts exist* and *which to forget*; this
    RFC-0247 removed the composite
    importance score (confidence × recency × truth-recency × stale-penalty ×
    access × lexical relevance) and every input it multiplied: a fact's value is
    a judgment, not a number this module can compute. *)

open Keeper_memory_os_types

(* RFC-0285 §8: how the re-observed claim reached the librarian. The write
   boundary decides this once (the production caller joins the incoming claim's
   identity against [Keeper_recall_injection_window]); the policy below is a
   pure function of the decision. A closed sum — not an optional flag — so no
   call site can skip the judgment and silently default to anchor refresh. *)
type reobservation_provenance =
  | Independent_observation
  | Recalled_echo

(* RFC-0247 (purge): fold a re-observation of an existing fact into that fact.
   [existing] is the persisted row; [incoming] is the newly extracted claim with
   the same producer identity. Identity and first-seen provenance are preserved.

   External refs no longer suppress re-observation refresh. They are context, not
   a code-enforced grounding contract. Self-observation remains special: the
   librarian re-extracting it is not proof that the self-state still holds.

   The prior merge also blended a confidence float and bumped an access counter;
   both fed the deleted composite score and are gone. There is no numeric
   strength to move — re-observation is a binary "seen again now". *)
let reobserve_fact ~now ~provenance ~existing ~incoming:(_ : fact) =
  match provenance with
  | Recalled_echo ->
    (* RFC-0285 §8: the claim was recall-injected into the very window the
       librarian summarized. Restating what the prompt just said is an echo of
       stored memory, not re-verification — under the pre-§8 rule an echo
       advanced [last_verified_at], which kept the fact at the top of the
       recency-ranked recall window, which caused the next echo: a fact could
       sustain its own recall slot indefinitely. Inherit the row whole; the
       anchor advances only through independent re-observation after the fact
       rotates out of the recall window. *)
    existing
  | Independent_observation ->
    (* Record the new observation without changing the producer-supplied
       [valid_until]. Claim kind is context, not authority for a different merge. *)
    { existing with last_verified_at = Some now }
;;
