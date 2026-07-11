(** Keeper_memory_os_gc — deterministic garbage collection for stale facts. *)

open Keeper_memory_os_types

module Io = Keeper_memory_os_io
module String_map = Map.Make (String)
module Int_set = Set.Make (Int)

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; dedup_removed : int
  ; written : int
  ; dry_run : bool
  }

exception Fact_store_corrupt of string

type indexed_fact =
  { index : int
  ; fact : fact
  }

(* Retention boundary SSOT: the writer cap ([partition_expired]) and recall
   both expire through [fact_is_current], whose [fact_effective_valid_until]
   also derives the RFC-0259 P7 horizon for legacy [External_state] facts with
   no explicit [valid_until]. Matching raw [fact.valid_until] here left GC
   blind to that horizon — the memory-os sanity sweep asserts GC and sweep
   agree, which broke main on 2026-07-06 (#23384). Same boundary at equality:
   [ts >= now] current ⇔ [now > ts] expired. *)
let ttl_expired ~now (fact : fact) = not (fact_is_current ~now fact)

let bump_count key counts =
  let current =
    match String_map.find_opt key counts with
    | Some count -> count
    | None -> 0
  in
  String_map.add key (current + 1) counts
;;

let expired_category_counts expired =
  let ephemeral, non_ephemeral, by_category =
    List.fold_left
      (fun (ephemeral, non_ephemeral, by_category) item ->
         let category = item.fact.category in
         let category_key = category_to_string category in
         let ephemeral, non_ephemeral =
           match category with
           | Ephemeral -> ephemeral + 1, non_ephemeral
           | Fact
           | Constraint
           | Preference
           | Code_change
           | Validated_approach
           | Lesson
           | Blocker
           | Goal
           | Unknown _ -> ephemeral, non_ephemeral + 1
         in
         ephemeral, non_ephemeral, bump_count category_key by_category)
      (0, 0, String_map.empty)
      expired
  in
  ephemeral, non_ephemeral, String_map.bindings by_category
;;

(* Claim identity uses the shared SSOT [claim_identity] (RFC-0259 §3.7: the
   producer-emitted [claim_id] when present, else [normalize_claim] of the text),
   the same key the write-time upsert ([merge_and_cap_facts]) and recall dedup
   use, so GC's dedup cannot diverge from them (RFC-0247 §2.3 fold). *)
let normalized_claim_key fact = claim_identity fact

(* The dedup winner's recency anchor: the type-level {!reference_time} SSOT, so
   GC's "which duplicate to keep" reads the same timestamp as recall ordering and
   retention ranking. *)
let verified_at = reference_time

(* RFC-0247 (purge): the dedup winner is structural — the most-recently-verified
   row for a claim (else first-seen), tie-broken by file order. The prior GC
   chose the higher [score_fact]; that composite score is gone, so "which
   duplicate to keep" reduces to the same truth-anchor recency that orders
   recall and the retention cap. No relevance number decides survival. *)
let more_recent candidate existing =
  match Float.compare (verified_at candidate.fact) (verified_at existing.fact) with
  | cmp when cmp > 0 -> true
  | cmp when cmp < 0 -> false
  | _ -> candidate.index < existing.index
;;

let dedup_by_claim items =
  let winners =
    List.fold_left
      (fun acc item ->
         let key = normalized_claim_key item.fact in
         match String_map.find_opt key acc with
         | None -> String_map.add key item acc
         | Some existing when more_recent item existing -> String_map.add key item acc
         | Some _ -> acc)
      String_map.empty
      items
  in
  let winner_indexes =
    String_map.fold (fun _ item acc -> Int_set.add item.index acc) winners Int_set.empty
  in
  List.filter (fun item -> Int_set.mem item.index winner_indexes) items
;;

(* RFC-0247 (purge): GC is now two structural passes only — hard-expire facts
   past their effective horizon ([fact_effective_valid_until]: explicit
   [valid_until], or the RFC-0259 P7 legacy [External_state] horizon), then
   dedup duplicate claims keeping the most-recently-verified.
   The score-threshold
   discard ([decide_retention] on [score_fact <= 0.02]) was removed: a fact's
   value is not a number GC can threshold. Forgetting is the librarian's
   delete-on-contradiction judgment plus this structural TTL, not a low score. *)
let run_gc_with_store
      ~read_facts_all_strict
      ~rewrite_facts_atomically
      ?(dry_run = false)
      ~now
      ()
  =
  (* The caller holds the descriptor-anchored facts capability across this
     strict read-modify-rewrite. A malformed row aborts before rewrite, so GC
     never turns decoder tolerance into permanent data loss. *)
  match read_facts_all_strict () with
  | Error message ->
    raise (Fact_store_corrupt ("memory os gc fact store read failed: " ^ message))
  | Ok facts ->
    let indexed = List.mapi (fun index fact -> { index; fact }) facts in
    let live, expired =
      List.partition (fun item -> not (ttl_expired ~now item.fact)) indexed
    in
    let ttl_expired_ephemeral, ttl_expired_non_ephemeral, ttl_expired_by_category =
      expired_category_counts expired
    in
    let deduped = dedup_by_claim live in
    let survivors = List.map (fun item -> item.fact) deduped in
    if not dry_run then rewrite_facts_atomically survivors;
    { total_input = List.length facts
    ; ttl_expired = List.length expired
    ; ttl_expired_ephemeral
    ; ttl_expired_non_ephemeral
    ; ttl_expired_by_category
    ; dedup_removed = List.length live - List.length deduped
    ; written = List.length survivors
    ; dry_run
    }
;;

let run_gc ?dry_run ~keeper_id ~now () =
  Io.with_facts_lock
    ~keeper_id
    ~on_timeout:Io.raise_lock_timeout
    (fun lock ->
      run_gc_with_store
        ~read_facts_all_strict:(fun () -> Io.read_facts_all_strict_in_lock lock)
        ~rewrite_facts_atomically:(Io.rewrite_facts_in_lock lock)
        ?dry_run
        ~now
        ())
;;

let run_gc_for_keepers_dir ~keepers_dir ?dry_run ~keeper_id ~now () =
  let keeper_name =
    match Keeper_id.Keeper_name.of_string keeper_id with
    | Ok keeper_name -> keeper_name
    | Error detail -> invalid_arg detail
  in
  Io.with_facts_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id:keeper_name
    ~on_timeout:Io.raise_lock_timeout
    (fun lock ->
      run_gc_with_store
        ~read_facts_all_strict:(fun () -> Io.read_facts_all_strict_in_lock lock)
        ~rewrite_facts_atomically:(Io.rewrite_facts_in_lock lock)
        ?dry_run
        ~now
        ())
;;
