(** Keeper_memory_os_gc — deterministic garbage collection for stale facts. *)

open Keeper_memory_os_types

module Io = Keeper_memory_os_io
module Policy = Keeper_memory_os_policy
module String_map = Map.Make (String)
module Int_set = Set.Make (Int)

type gc_report =
  { total_input : int
  ; ttl_expired : int
  ; verdict_discarded : int
  ; dedup_removed : int
  ; written : int
  ; dry_run : bool
  }

type scored_fact =
  { index : int
  ; fact : fact
  ; score : float
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

let better_scored candidate existing =
  match Float.compare candidate.score existing.score with
  | cmp when cmp > 0 -> true
  | cmp when cmp < 0 -> false
  | _ ->
    (match Float.compare (verified_at candidate.fact) (verified_at existing.fact) with
     | cmp when cmp > 0 -> true
     | cmp when cmp < 0 -> false
     | _ -> candidate.index < existing.index)
;;

let keep_by_verdict scored =
  match Policy.decide_retention scored.score with
  | Policy.KeepVerbatim -> true
  | Policy.Discard -> false
;;

let dedup_by_claim scored =
  let winners =
    List.fold_left
      (fun acc item ->
         let key = normalized_claim_key item.fact in
         match String_map.find_opt key acc with
         | None -> String_map.add key item acc
         | Some existing when better_scored item existing -> String_map.add key item acc
         | Some _ -> acc)
      String_map.empty
      scored
  in
  let winner_indexes =
    String_map.fold (fun _ item acc -> Int_set.add item.index acc) winners Int_set.empty
  in
  List.filter (fun item -> Int_set.mem item.index winner_indexes) scored
;;

let run_gc ?(dry_run = false) ~keeper_id ~now () =
  let facts = Io.read_facts_all ~keeper_id in
  let scored =
    facts
    |> List.mapi (fun index fact -> { index; fact; score = Policy.score_fact ~now fact })
  in
  let live, expired = List.partition (fun item -> not (ttl_expired ~now item.fact)) scored in
  let kept_by_verdict, discarded = List.partition keep_by_verdict live in
  let deduped = dedup_by_claim kept_by_verdict in
  let survivors = List.map (fun item -> item.fact) deduped in
  if not dry_run then Io.rewrite_facts_atomically ~keeper_id survivors;
  { total_input = List.length facts
  ; ttl_expired = List.length expired
  ; verdict_discarded = List.length discarded
  ; dedup_removed = List.length kept_by_verdict - List.length deduped
  ; written = List.length survivors
  ; dry_run
  }
;;
