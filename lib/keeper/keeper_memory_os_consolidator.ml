(** Keeper_memory_os_consolidator — RFC-0244 Tier 2 cross-keeper consolidation.

    The per-keeper Tier-1 stores (keepers/<id>.facts.jsonl) stay isolated. This
    pass reads them read-only, finds claims corroborated by [>= min_keepers]
    DISTINCT keepers (above a confidence floor, on a category whitelist), and
    writes them into a single shared Tier-2 store
    (keepers/_shared.facts.jsonl) with [observed_by] = the contributing keeper
    set. It never mutates a keeper's own store, so it is additive and safe to
    wire ahead of the destructive per-keeper [run_gc].

    Determinism (the memory-os offline/reproducible tenet): the output is a pure
    function of the input facts, emitted in normalized-claim order, so a test can
    assert exact output and a re-run on an unchanged fleet rewrites the same file.
    Confidence is recomputed from scratch each sweep via noisy-OR over the
    per-keeper best confidence, so a shared fact's confidence rises only when a
    NEW distinct keeper corroborates it; a same-keeper repeat collapses into that
    keeper's single contribution and does not inflate it. *)

open Keeper_memory_os_types

module Io = Keeper_memory_os_io

(* Which categories are objective enough to share across keepers is a
   compile-time property of the closed [category] taxonomy
   (Keeper_memory_os_types.is_promotable: only Fact/Constraint), not a runtime
   list. Default-deny is structural: a new arm (e.g. the [Ephemeral]
   coordination-boilerplate kind, RFC-0246 §2.5 / #21244) cannot leak into the
   shared tier unless it is classified promotable at the type level. This
   strengthens #21241's typed [category list] into an exhaustive predicate, so a
   future arm forces a compile-time promotability decision rather than silently
   defaulting out of a list. *)

(* A contributing observation must clear this confidence floor; below it a claim
   is too weak to count as corroboration. *)
let default_confidence_threshold = 0.5

(* Minimum distinct keepers that must hold a claim before it is shared. Two is
   the smallest set that distinguishes corroboration from a single keeper's echo
   (RFC-0244 §2.2). *)
let default_min_keepers = 2

let clamp01 v = Float.max 0.0 (Float.min 1.0 v)

(* Noisy-OR over independent per-keeper confidences: 1 - Π(1 - c_k). Monotone in
   each c_k and in the number of keepers, bounded in [0, 1]. *)
let noisy_or confidences =
  clamp01 (1.0 -. List.fold_left (fun acc c -> acc *. (1.0 -. clamp01 c)) 1.0 confidences)

type report =
  { keepers_scanned : int
  ; claims_considered : int (* distinct normalized claims with >= 1 eligible contribution *)
  ; promoted : int
  ; dry_run : bool
  }

(* A contribution is one keeper's eligible observation of a claim. *)
type contribution =
  { keeper_id : string
  ; fact : fact
  }

let eligible ~threshold fact =
  fact.confidence >= threshold && is_promotable fact.category
;;

(* Pick the representative fact for a claim group: highest confidence, then
   earliest first_seen, then lexically smallest claim, then keeper id — a total
   order so selection is deterministic regardless of input order. *)
let representative contribs =
  let better a b =
    match Float.compare a.fact.confidence b.fact.confidence with
    | c when c > 0 -> true
    | c when c < 0 -> false
    | _ ->
      (match Float.compare a.fact.first_seen b.fact.first_seen with
       | c when c < 0 -> true
       | c when c > 0 -> false
       | _ ->
         (match String.compare a.fact.claim b.fact.claim with
          | c when c < 0 -> true
          | c when c > 0 -> false
          | _ -> String.compare a.keeper_id b.keeper_id < 0))
  in
  match contribs with
  | [] -> None
  | first :: rest ->
    Some (List.fold_left (fun best c -> if better c best then c else best) first rest)
;;

(* Per-keeper best confidence among that keeper's contributions, returned as a
   (keeper_id-sorted) assoc so the keeper set and the noisy-OR input are both
   deterministic. *)
let per_keeper_best contribs =
  let tbl : (string, float) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun c ->
       match Hashtbl.find_opt tbl c.keeper_id with
       | Some existing when existing >= c.fact.confidence -> ()
       | Some _ | None -> Hashtbl.replace tbl c.keeper_id c.fact.confidence)
    contribs;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

let consolidate_into_shared ~now ~min_keepers contribs =
  match representative contribs with
  | None -> None
  | Some rep ->
    let keeper_best = per_keeper_best contribs in
    let distinct_keepers = List.map fst keeper_best in
    if List.length distinct_keepers < min_keepers
    then None
    else
      Some
        { claim = rep.fact.claim
        ; confidence = noisy_or (List.map snd keeper_best)
        ; category = rep.fact.category
        ; source = rep.fact.source
        ; observed_by = distinct_keepers
        ; access_count =
            List.fold_left (fun acc c -> acc + c.fact.access_count) 0 contribs
        ; first_seen =
            List.fold_left (fun acc c -> Float.min acc c.fact.first_seen) rep.fact.first_seen contribs
        ; last_accessed =
            List.fold_left (fun acc c -> Float.max acc c.fact.last_accessed) rep.fact.last_accessed contribs
        ; valid_until = None
        ; stale_factor = 0.0
          (* The consolidation IS the verification of the shared fact. *)
        ; last_verified_at = Some now
        ; expected_lifetime_cycles = None
        ; schema_version
        }
;;

(* Pure core: given each keeper's Tier-1 facts, return the Tier-2 shared facts in
   normalized-claim order. No IO, no clock read — [now] is injected. *)
let promote_facts
      ?(threshold = default_confidence_threshold)
      ?(min_keepers = default_min_keepers)
      ~now
      ~keeper_facts
      ()
  =
  let groups : (string, contribution list) Hashtbl.t = Hashtbl.create 256 in
  List.iter
    (fun (keeper_id, facts) ->
       List.iter
         (fun fact ->
            if eligible ~threshold fact
            then (
              let key = normalize_claim fact.claim in
              let prev = Option.value (Hashtbl.find_opt groups key) ~default:[] in
              Hashtbl.replace groups key ({ keeper_id; fact } :: prev)))
         facts)
    keeper_facts;
  let considered = Hashtbl.length groups in
  let promoted =
    Hashtbl.fold (fun key contribs acc -> (key, contribs) :: acc) groups []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.filter_map (fun (_key, contribs) ->
      consolidate_into_shared ~now ~min_keepers contribs)
  in
  considered, promoted
;;

(* IO-driven entry: read each source keeper's Tier-1 store, consolidate, and
   (unless [dry_run]) rewrite the shared store atomically. The shared id itself
   is filtered out of the source list so a prior sweep's output is never folded
   back in as a "keeper". *)
let run ?(dry_run = false) ?threshold ?min_keepers ~keeper_ids ~now () =
  let source_ids =
    List.filter (fun id -> not (String.equal id shared_store_id)) keeper_ids
  in
  let rec read_sources acc = function
    | [] -> Ok (List.rev acc)
    | id :: rest ->
      (match Io.read_facts_all_strict ~keeper_id:id with
       | Ok facts -> read_sources ((id, facts) :: acc) rest
       | Error message -> Error message)
  in
  match read_sources [] source_ids with
  | Error message -> invalid_arg ("memory os consolidation input invalid: " ^ message)
  | Ok keeper_facts ->
    let considered, promoted =
      promote_facts ?threshold ?min_keepers ~now ~keeper_facts ()
    in
    if not dry_run then Io.rewrite_facts_atomically ~keeper_id:shared_store_id promoted;
    { keepers_scanned = List.length source_ids
    ; claims_considered = considered
    ; promoted = List.length promoted
    ; dry_run
    }
;;
