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

(* RFC-0247 (purge): fold a re-observation of an existing fact into that fact.
   [existing] is the persisted row; [incoming] is the newly extracted claim with
   the same producer identity. Identity and first-seen provenance are preserved.

   External refs no longer suppress re-observation refresh. They are context, not
   a code-enforced grounding contract. Self-observation remains special: the
   librarian re-extracting it is not proof that the self-state still holds.

   The prior merge also blended a confidence float and bumped an access counter;
   both fed the deleted composite score and are gone. There is no numeric
   strength to move — re-observation is a binary "seen again now". *)
let reobserve_fact ~now ~existing ~incoming:(_ : fact) =
  match existing.claim_kind with
  | Some Self_observation | Some External_state ->
    (* RFC-0285 §3.3 / RFC-0259 P7: inherit the prior row; do NOT advance
       [last_verified_at]. The librarian re-extracting a recalled claim — a
       self-observation OR a volatile external-state claim — is NOT
       re-verification; it is the same claim re-emitted from memory. Advancing the
       staleness marker would raise [retention_rank] and make the cap keep an
       echoed (possibly now-false) claim as "recently verified" — the opposite of
       the goal. For [External_state] the birth-set finite [valid_until]
       (fact_valid_until, RFC-0259 P7) is what bounds its lifetime; re-assertion
       must not extend it, otherwise a claim about a cancelled task would be kept
       alive forever by repetition. *)
    existing
  | Some Durable_knowledge | Some Diagnostic | None ->
    (* Durable/diagnostic re-observe: re-asserting a timeless claim from fresh
       context is enough to advance the staleness marker. *)
    { existing with last_verified_at = Some now }
;;

let events_to_facts_ratio_attention_threshold = 2.0
