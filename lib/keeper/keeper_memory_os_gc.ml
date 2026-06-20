(** Keeper_memory_os_gc — deterministic garbage collection for stale facts. *)

open Keeper_memory_os_types

module Io = Keeper_memory_os_io
module String_map = Map.Make (String)
module Int_set = Set.Make (Int)

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; dedup_removed : int
  ; written : int
  ; dry_run : bool
  }

exception Fact_store_corrupt of string

type indexed_fact =
  { index : int
  ; fact : fact
  }

let ttl_expired ~now (fact : fact) =
  match fact.valid_until with
  | None -> false
  | Some ts -> now > ts
;;

(* Claim identity uses the shared SSOT [normalize_claim] (lowercase +
   internal-whitespace-collapse + trailing-trim), the same key the write-time
   upsert ([merge_and_cap_facts]) and recall dedup use, so GC's dedup cannot
   diverge from them (RFC-0247 §2.3 fold). *)
let normalized_claim_key fact = normalize_claim fact.claim

let verified_at fact =
  match fact.last_verified_at with
  | Some ts -> ts
  | None -> fact.first_seen
;;

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
   past their [valid_until] horizon (a typed decision: the Ephemeral TTL, or the
   RFC-0259 §3.2(b) volatile horizon for an external-ref claim), then
   dedup duplicate claims keeping the most-recently-verified. The score-threshold
   discard ([decide_retention] on [score_fact <= 0.02]) was removed: a fact's
   value is not a number GC can threshold. Forgetting is the librarian's
   delete-on-contradiction judgment plus this structural TTL, not a low score. *)
let run_gc ?keepers_dir ?(dry_run = false) ~keeper_id ~now () =
  (* Serialize the whole read-modify-rewrite on the same per-keeper facts lock the
     librarian write path (Keeper_librarian_runtime, wrapping merge_and_cap_facts)
     and the consolidation runtime already hold on facts_path. Without it, a
     librarian merge that commits between GC's read and GC's rewrite is silently
     overwritten — a lost update that permanently drops a freshly persisted fact.
     The lock spans both the read and the rewrite, so no concurrent writer can
     interleave; because the read-modify-rewrite is entirely inside the lock there
     is no unlocked gap to guard with a snapshot CAS (unlike
     Keeper_memory_os_consolidation_runtime, whose LLM call runs between its read
     and rewrite and so re-validates the snapshot under the lock). No clock is
     threaded: lock-retry sleeps run on a systhread (off the keeper hot path, GC
     is a 600s maintenance sweep, so cooperative yielding buys nothing), and
     File_lock_eio already offloads the blocking flock so the Eio domain is not
     stalled. Must run inside an Eio context (the maintenance fiber and tests
     both are). *)
  File_lock_eio.with_lock (Io.facts_path ?keepers_dir ~keeper_id) (fun () ->
    (* Read strictly: a malformed JSONL row aborts the sweep rather than being
       silently dropped by the lenient decoder and then erased by the rewrite
       below. Every other destructive rewrite path already refuses to overwrite a
       store it cannot fully parse — cap_facts / merge_and_cap_facts via
       read_facts_for_rewrite, the consolidator and consolidation runtime via
       read_facts_all_strict. GC was the lone path that turned one corrupt line
       into permanent deletion of the surrounding facts (it read via the lenient
       read_facts_all). Preserve over delete: leave a corrupt store untouched and
       let the raised error surface so an operator can repair it. *)
    match Io.read_facts_all_strict ?keepers_dir ~keeper_id with
    | Error message ->
      raise (Fact_store_corrupt ("memory os gc fact store read failed: " ^ message))
    | Ok facts ->
      let indexed = List.mapi (fun index fact -> { index; fact }) facts in
      let live, expired =
        List.partition (fun item -> not (ttl_expired ~now item.fact)) indexed
      in
      let deduped = dedup_by_claim live in
      let survivors = List.map (fun item -> item.fact) deduped in
      if not dry_run then Io.rewrite_facts_atomically ?keepers_dir ~keeper_id survivors;
      { total_input = List.length facts
      ; ttl_expired = List.length expired
      ; dedup_removed = List.length live - List.length deduped
      ; written = List.length survivors
      ; dry_run
      })
;;
