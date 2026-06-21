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

   RFC-0259 §3.2(b): a volatile (external-ref) claim is non-durable even when its
   category is durable (e.g. a [Fact] naming a PR), so the cap drops it before
   genuine durable knowledge. Keying off [category_valid_until] alone would keep
   it durable; OR-in the external ref. The category check still covers legacy
   Ephemeral rows whose [valid_until] was omitted on disk. *)
let retention_rank ~now (f : fact) =
  let tier =
    if Option.is_some f.external_ref
       || Option.is_some (category_valid_until ~now f.category)
    then 0.0
    else durable_retention_tier
  in
  let recency = reference_time f in
  tier +. recency
;;

(* RFC-0247 (purge): fold a re-observation of an existing fact into that fact.
   [existing] is the persisted row; [incoming] is the newly extracted claim with
   the same producer identity. Identity and first-seen provenance are preserved.

   RFC-0259 §3.7 (P6/F): for a volatile (external-ref) claim the prior row is
   inherited entirely — producer re-extraction is NOT re-verification. Only the
   reconciler ([Stale_open], an external GitHub re-check) advances a volatile
   claim's anchors. A non-volatile fact's [last_verified_at] still advances on
   re-observe (it has no decay horizon to reset).

   The prior merge also blended a confidence float and bumped an access counter;
   both fed the deleted composite score and are gone. There is no numeric
   strength to move — re-observation is a binary "seen again now". *)
let reobserve_fact ~now ~existing ~incoming:(_ : fact) =
  match existing.external_ref with
  | Some _ ->
    (* RFC-0259 §3.7 (P6/F): the librarian re-extracting a volatile (external-ref)
       claim — possibly reworded — is NOT re-verification; it is the same self-
       narrative re-emitted from memory. Inherit the prior row entirely so a
       re-mint cannot reset the volatile TTL or grounding horizon. Only the
       reconciler ([Stale_open], an external GitHub re-check) advances a volatile
       claim's [last_verified_at]. This reverses the pre-P6 "re-observing IS
       re-verification" rule for volatile claims. *)
    existing
  | None ->
    (* Non-volatile (durable [None] / Ephemeral expiry) re-observe: the librarian
       re-asserting a durable claim is fresh evidence it still holds, so advance
       the staleness marker. There is no decay horizon to reset (durable
       [valid_until] is unchanged), so F does not apply. *)
    { existing with last_verified_at = Some now }
;;
