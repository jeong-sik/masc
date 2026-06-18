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
   trigger: durable categories outrank Ephemeral (a typed decision via
   [category_valid_until], which returns [Some] only for Ephemeral), and within a
   tier the most-recently-verified (else first-seen) fact is kept. It never ranks
   recall — recall ordering is structural + judgment, not a number. *)
let retention_rank ~now (f : fact) =
  let tier =
    match category_valid_until ~now f.category with
    | None -> durable_retention_tier
    | Some _ -> 0.0
  in
  let recency = match f.last_verified_at with Some t -> t | None -> f.first_seen in
  tier +. recency
;;

(* RFC-0247 (purge): fold a re-observation of an existing fact into that fact.
   [existing] is the persisted row; [incoming] is the newly extracted claim with
   the same normalized identity. The only effect is to refresh the truth anchor:
   the librarian re-extracting the same claim is fresh evidence that the claim
   still holds, so [last_verified_at] advances to [now] and the staleness marker
   resets. Identity and first-seen provenance are preserved.

   The prior merge also blended a confidence float and bumped an access counter;
   both fed the deleted composite score and are gone. There is no numeric
   strength to move — re-observation is a binary "seen again now". *)
let reobserve_fact ~now ~existing ~incoming:(_ : fact) =
  { existing with last_verified_at = Some now }
;;
