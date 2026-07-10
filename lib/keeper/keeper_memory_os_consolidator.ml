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
    RFC-0247 (purge): corroboration is structural. The prior confidence floor and
    noisy-OR aggregation were removed with the score; there is no confidence
    number to recompute. Shared promotion is additionally limited to categories
    that already encode outcome-derived knowledge, so `_shared` does not amplify
    merely repeated facts before the outcome evaluator can prove usefulness. *)

open Keeper_memory_os_types

module Io = Keeper_memory_os_io

(* RFC-0244 §3.6 / task-1612: env-gate. Default OFF -> opt-in. *)
let consolidation_enabled () =
  Env_config.KeeperMemoryOs.shared_consolidator_enabled ()

(* Which categories are durable enough to consider, and which are
   outcome-positive enough to cross keepers, are compile-time properties of the
   closed [category] taxonomy. Default-deny is structural: a new arm (e.g. the
   [Ephemeral] coordination-boilerplate kind, RFC-0247 §2.5 / #21244) cannot leak
   into the shared tier unless it is classified both promotable and
   outcome-positive at the type level. *)

(* Minimum distinct keepers that must hold a claim before it is shared. Two is
   the smallest set that distinguishes corroboration from a single keeper's echo
   (RFC-0244 §2.2). *)
let default_min_keepers = 2

type report =
  { keepers_scanned : int
  ; claims_considered : int (* distinct normalized claims with >= 1 eligible contribution *)
  ; promoted : int
  ; dry_run : bool
  ; status : report_status
  }

and report_status =
  | Consolidation_ran
  | Consolidation_disabled

(* A contribution is one keeper's eligible observation of a claim. *)
type contribution =
  { keeper_id : string
  ; fact : fact
  }

(* RFC-0247 (purge): eligibility is structural — a promotable, outcome-positive
   category. The prior confidence floor (only claims above 0.5 count as
   corroboration) was a score gate and is gone. *)
(* RFC-0285 §3.5: only objective claim kinds cross keepers. [Self_observation] is
   transient keeper-local state, [External_state] is time-sensitive world state,
   and [Diagnostic] is system-authored evidence for operators, not shared semantic
   memory. Keep this exhaustive so a future [claim_kind] cannot promote by
   accident. *)
let not_stale ~now fact =
  match fact_effective_valid_until fact with
  | Some deadline -> now <= deadline
  | None ->
    (* No explicit TTL (Durable_knowledge, legacy). Apply consensus
       staleness bound from the policy SSOT. *)
    let max_age = Keeper_memory_os_policy.max_consensus_staleness in
    match fact.last_verified_at with
    | Some t -> now -. t <= max_age
    | None -> now -. fact.first_seen <= max_age

let eligible ~now fact =
  is_promotable fact.category
  && is_outcome_positive_for_shared_promotion fact.category
  && not_stale ~now fact
  &&
  match fact.claim_kind with
  | Some Durable_knowledge | None -> true
  | Some Self_observation | Some External_state | Some Diagnostic -> false

(* Pick the representative fact for a claim group by a structural total order:
   freshest explicit verification first; unverified legacy rows fall back to
   earliest first_seen, then lexically smallest claim, then keeper id. Selection
   stays deterministic regardless of input order. The prior tie-breaker on
   highest confidence was removed with the score. *)
let representative contribs =
  let better a b =
    match a.fact.last_verified_at, b.fact.last_verified_at with
    | Some ta, Some tb -> ta > tb
    | Some _, None -> true
    | None, Some _ -> false
    | None, None ->
      match Float.compare a.fact.first_seen b.fact.first_seen with
      | c when c < 0 -> true
      | c when c > 0 -> false
      | _ ->
        (match String.compare a.fact.claim b.fact.claim with
         | c when c < 0 -> true
         | c when c > 0 -> false
         | _ -> String.compare a.keeper_id b.keeper_id < 0)
  in
  match contribs with
  | [] -> None
  | first :: rest ->
    Some (List.fold_left (fun best c -> if better c best then c else best) first rest)
;;

(* The sorted set of distinct keeper ids among the contributions — the structural
   corroboration set, written verbatim as [observed_by]. *)
let distinct_keepers contribs =
  List.map (fun c -> c.keeper_id) contribs |> List.sort_uniq String.compare
;;

let consolidate_into_shared ~now ~min_keepers contribs =
  let current_contribs =
    List.filter (fun c -> not_stale ~now c.fact) contribs
  in
  match representative current_contribs with
  | None -> None
  | Some rep ->
    let keepers = distinct_keepers current_contribs in
    if List.length keepers < min_keepers
    then None
    else
      Some
        { claim = rep.fact.claim
        ; category = rep.fact.category
        ; external_ref = None
          (* External refs are context-only, not shared-store identity or retention
             policy. Keep promoted shared facts free of legacy ref metadata. *)
        ; claim_kind = rep.fact.claim_kind
        ; source = rep.fact.source
        ; observed_by = keepers
        ; first_seen =
            List.fold_left
              (fun acc c -> Float.min acc c.fact.first_seen)
              rep.fact.first_seen
              current_contribs
          (* Route through [fact_valid_until] so self-observation/category TTL policy
             stays centralized. External refs are context-only and do not affect
             retention. *)
        ; valid_until =
            fact_valid_until
              ~now
              ~external_ref:None
              ~claim_kind:rep.fact.claim_kind
              rep.fact.category
          (* The consolidation IS the verification of the shared fact. *)
        ; last_verified_at = Some now
        ; schema_version
          (* RFC-0259 §3.7: carry the group's [claim_id] onto the promoted shared
             fact. The group is keyed on [claim_identity] (see [promote_facts]), so
             every contribution shares one identity and the representative's
             [claim_id] is the group's. Without this the shared fact would key on
             [normalize_claim] while the contributing keepers' private rows key on
             [id:…], so recall's private-precedence dedup (recall.ml) and the user
             model would fail to match across tiers and inject the same conclusion
             twice. *)
        ; claim_id = rep.fact.claim_id
        }
;;

(* Pure core: given each keeper's Tier-1 facts, return the Tier-2 shared facts in
   claim-identity order (RFC-0259 §3.7 SSOT key). No IO, no clock read — [now] is
   injected. *)
let promote_facts ?(min_keepers = default_min_keepers) ~now ~keeper_facts () =
  let groups : (string, contribution list) Hashtbl.t = Hashtbl.create 256 in
  List.iter
    (fun (keeper_id, facts) ->
       List.iter
         (fun fact ->
            if eligible ~now fact
            then (
              let key = claim_identity fact in
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

let sum ints = List.fold_left ( + ) 0 ints

let source_fact_counts ~now keeper_facts =
  List.map
    (fun (keeper_id, facts) ->
       ( keeper_id
       , List.length facts
       , List.length (List.filter (eligible ~now) facts) ))
    keeper_facts

let source_fact_counts_json counts =
  `List
    (List.map
       (fun (keeper_id, facts, eligible_facts) ->
          `Assoc
            [ "keeper_id", `String keeper_id
            ; "facts", `Int facts
            ; "eligible_facts", `Int eligible_facts
            ])
       counts)

let log_run_summary ~now ~dry_run ~min_keepers ~source_ids ~keeper_facts ~considered ~promoted =
  let counts = source_fact_counts ~now keeper_facts in
  let input_facts = sum (List.map (fun (_, facts, _) -> facts) counts) in
  let eligible_facts = sum (List.map (fun (_, _, eligible_facts) -> eligible_facts) counts) in
  let promoted_count = List.length promoted in
  Log.Keeper.info
    "memory os consolidator run dry_run=%b min_keepers=%d keepers=%d input_facts=%d eligible_facts=%d claims_considered=%d promoted=%d"
    dry_run
    min_keepers
    (List.length source_ids)
    input_facts
    eligible_facts
    considered
    promoted_count;
  if promoted_count = 0
  then
    Log.Keeper.warn
      "memory os consolidator promoted_zero dry_run=%b min_keepers=%d keepers=%d input_facts=%d eligible_facts=%d claims_considered=%d source_counts=%s"
      dry_run
      min_keepers
      (List.length source_ids)
      input_facts
      eligible_facts
      considered
      (Yojson.Safe.to_string (source_fact_counts_json counts))

(* IO-driven entry: read each source keeper's Tier-1 store, consolidate, and
   (unless [dry_run]) rewrite the shared store atomically. The shared id itself
   is filtered out of the source list so a prior sweep's output is never folded
   back in as a "keeper". *)
let run ?(dry_run = false) ?min_keepers ~keeper_ids ~now () =
  if not (consolidation_enabled ()) then (
    Log.Keeper.info
      "memory os consolidator skipped: MASC_KEEPER_MEMORY_OS_CONSOLIDATE=false";
    { keepers_scanned = 0
    ; claims_considered = 0
    ; promoted = 0
    ; dry_run
    ; status = Consolidation_disabled
    }
  ) else
  let source_ids =
    List.filter (fun id -> not (String.equal id shared_store_id)) keeper_ids
  in
  let min_keepers =
    match min_keepers with
    | Some value -> value
    | None -> default_min_keepers
  in
  let run_unlocked () =
    let rec read_sources acc = function
      | [] -> Ok (List.rev acc)
      | id :: rest ->
        (match Io.read_facts_all_strict ~keeper_id:id with
         | Ok facts -> read_sources ((id, facts) :: acc) rest
         | Error message -> Error message)
    in
    match read_sources [] source_ids with
    | Error message ->
      Log.Keeper.warn
        "memory os consolidator input_invalid keepers=%d error=%s"
        (List.length source_ids)
        message;
      invalid_arg ("memory os consolidation input invalid: " ^ message)
    | Ok keeper_facts ->
      let considered, promoted =
        promote_facts ~min_keepers ~now ~keeper_facts ()
      in
      log_run_summary
        ~now
        ~dry_run
        ~min_keepers
        ~source_ids
        ~keeper_facts
        ~considered
        ~promoted;
      if not dry_run then Io.rewrite_facts_atomically ~keeper_id:shared_store_id promoted;
      { keepers_scanned = List.length source_ids
      ; claims_considered = considered
      ; promoted = List.length promoted
      ; dry_run
      ; status = Consolidation_ran
      }
  in
  if dry_run
  then run_unlocked ()
  else File_lock_eio.with_lock (Io.facts_path ~keeper_id:shared_store_id) run_unlocked
;;
