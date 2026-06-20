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
   the same normalized identity. Identity and first-seen provenance are always
   preserved (the merge returns [{ existing with ... }]).

   RFC-0259 §3.7 (P6/F) — producer re-observation is NOT re-verification for a
   volatile (external-ref) claim. This REVERSES the prior §3.2(b) rule. The
   librarian re-extracting "PR #42 is open" from its own session history is not
   evidence the PR is still open; only the grounding reconciler
   ([Keeper_memory_os_reconcile], which checks the external referent) is real
   re-verification. So a volatile re-observe INHERITS the prior row's anchor
   unchanged ([first_seen], [last_verified_at], [valid_until]); the volatile TTL
   and the [UNVERIFIED] grounding horizon keep ticking from the last *real*
   verification (or first extraction). Advancing the anchor on every producer
   re-extraction — the old behavior — let an actively re-extracted false claim
   never age out and never render [UNVERIFIED] (RFC-0259 defect C1 residual
   loop): the same false fact was re-injected into the prompt every cycle. Only
   the reconciler advances the anchor ([keeper_memory_os_reconcile.ml],
   [Stale_open] verdict); the producer inherits it.

   A non-volatile fact ([external_ref = None]) has no external ground truth to
   reconcile against, so re-extraction by the librarian is its only verification
   signal and [last_verified_at] still advances. [valid_until] (durable [None]
   or the original Ephemeral expiry) is preserved by [with].

   The prior merge also blended a confidence float and bumped an access counter;
   both fed the deleted composite score and are gone. There is no numeric
   strength to move — re-observation is a binary "seen again now". *)
let reobserve_fact ~now ~existing ~incoming:(_ : fact) =
  match existing.external_ref with
  | Some _ -> existing
  | None -> { existing with last_verified_at = Some now }
;;
