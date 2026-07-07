(** Keeper_memory_os_policy — structural retention order for the Memory OS.

    The LLM librarian decides *what facts exist* and *which to forget*; this
    module holds only the structural ordering the bounded store cap and the
    write-time re-observation merge need. RFC-0247 removed the composite
    importance score (confidence × recency × truth-recency × stale-penalty ×
    access × lexical relevance) and every input it multiplied: a fact's value is
    a judgment, not a number this module can compute. *)

open Keeper_memory_os_types

(* Durable facts always outrank Ephemeral in the retention cap, regardless of
   timestamp. The offset exceeds any unix timestamp so the two tiers never
   interleave. *)
let durable_retention_tier = 1.0e15

(* Memory OS recall and retention size policy. Keep raw numbers here so the
   read, write, dashboard, and test surfaces do not drift independently. *)
let fact_recall_window = 256
let fact_store_max = fact_recall_window + (fact_recall_window / 2)
let event_recall_window = 256
let event_store_max = event_recall_window + (event_recall_window / 2)
let episode_file_window = 256
let episode_file_store_max = episode_file_window + (episode_file_window / 2)
let recall_default_max_facts = 8
let recall_default_max_episodes = 2
let recall_default_max_shared_facts = 4
let recall_episode_tail_scan = 32

(* RFC-0247 §-1: structural retention rank for the bounded store cap. This is NOT
   a relevance score — it is a deterministic two-tier lexicographic order used
   ONLY to decide which rows the size cap drops when the store grows past its
   trigger: durable claims outrank non-durable ones, and within a tier the
   most-recently-verified (else first-seen) fact is kept. It never ranks recall —
   recall ordering is structural + judgment, not a number.

   External refs no longer affect retention rank. Memory OS provides claim text as
   context; it does not force PR/issue/task mentions into a lower-retention
   machine status bucket. The category check still covers legacy Ephemeral rows
   whose [valid_until] was omitted on disk. *)
let retention_rank ~now (f : fact) =
  let tier =
    if Option.is_some (category_valid_until ~now f.category)
    then 0.0
    else durable_retention_tier
  in
  let recency = reference_time f in
  tier +. recency
;;

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
    (match existing.claim_kind with
     | Some Self_observation ->
       (* RFC-0285 §3.3: inherit the prior row; do NOT advance
          [last_verified_at]. The librarian re-extracting a recalled
          self-observation is not re-verification; it is the same self-narrative
          re-emitted from memory. *)
       existing
     | Some External_state ->
       (* RFC-0259 P7: do not advance [last_verified_at] on mere re-assertion, but
          do materialize the compatibility-derived horizon for legacy rows whose
          on-disk [valid_until] was absent before P7. The anchor remains
          [first_seen], not [now], so re-observation cannot extend stale external
          state. *)
       { existing with valid_until = fact_effective_valid_until existing }
     | Some Durable_knowledge | Some Diagnostic | None ->
       (* Durable/diagnostic re-observe: re-asserting a timeless claim from fresh
          context is enough to advance the staleness marker. *)
       { existing with last_verified_at = Some now })
;;

let events_to_facts_ratio_attention_threshold = 2.0
