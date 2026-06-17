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

(* RFC-0247/RFC-0251: the dedup winner is structural — the
   most-recently-verified row for a claim (else first-seen), tie-broken by file
   order. A relevance/retention score never decides survival. *)
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

let read_all_strict ~keeper_id =
  match Io.read_facts_all_strict ~keeper_id with
  | Ok facts -> facts
  | Error msg -> invalid_arg ("Keeper_memory_os_gc.run_gc: " ^ msg)
;;

(* RFC-0251: GC is structural only. It removes legacy rows whose persisted
   [valid_until] has passed, dedups duplicate claims, and leaves every remaining
   row untouched. New facts no longer produce hard TTLs, and no score/decay
   verdict can discard a fact. *)
let run_gc ?(dry_run = false) ~keeper_id ~now () =
  let facts = read_all_strict ~keeper_id in
  let indexed = List.mapi (fun index fact -> { index; fact }) facts in
  let live, expired =
    List.partition (fun item -> not (ttl_expired ~now item.fact)) indexed
  in
  let deduped = dedup_by_claim live in
  let survivors = List.map (fun item -> item.fact) deduped in
  let changed =
    (not (List.is_empty expired)) || List.length live <> List.length deduped
  in
  if (not dry_run) && changed then Io.rewrite_facts_atomically ~keeper_id survivors;
  { total_input = List.length facts
  ; ttl_expired = List.length expired
  ; dedup_removed = List.length live - List.length deduped
  ; written = List.length survivors
  ; dry_run
  }
;;
