(** Memory-OS "brain" end-to-end verification harness.

    This is NOT another unit test. The unit tests in [test_keeper_memory_os]
    exercise each organ in isolation with hand-built fixtures, bypassing the env
    switches and testing one function at a time. This harness fills the gap
    between those unit tests and the live fleet by exercising the REAL production
    functions in their REAL composition order, on a fixture modelled on the
    #21244 live finding (ephemeral coordination boilerplate mixed with durable
    facts, some cross-keeper corroborated).

    VERIFIES (offline, deterministic):
    - S1 consolidation typed-gate has TEETH: ephemeral-labelled corroborated
      claims do NOT promote; and if the producer were to MISLABEL them as fact
      (the exact #21244 bug), they WOULD leak — so the gate is real, and the
      label is load-bearing.
    - S2 forgetting (GC) COMPOSES with consolidation: GC expires ephemeral facts,
      keeps durable ones, and never clobbers the consolidator-owned _shared tier
      (the production sweep excludes it).
    - S3 structural recall ordering: recall ranks by truth anchor
      ([last_verified_at] or [first_seen]), not by a composite score or
      activation boost. A fact verified later is recalled ahead of an older
      fact, deterministically.
    - S4 truth-anchor refresh via reobserve_fact: re-extracting the same claim
      advances [last_verified_at] while preserving [first_seen] provenance; an
      unreobserved control keeps its original anchor.

    DOES NOT VERIFY (honest boundary — do not claim otherwise):
    - That the LLM librarian assigns categories correctly, or which facts are
      valuable. That is the residual #21244 PRODUCER risk and the LLM-judgment
      layer; S1's teeth check demonstrates the gate is load-bearing but cannot
      prove the producer correct. Verifying it needs live-fleet data or a
      transcript eval, not an offline deterministic harness.
    - Live fleet behaviour: this seeds synthetic data. Run with
      [--keepers-dir <path>] for a read-only DRY-RUN against a real store
      (observability only — no pass/fail, since real ground truth is unknown).
    - The env-fiber scheduling in [server_bootstrap_maintenance]; this drives the
      same functions those fibers call, not the fiber wiring itself. *)

module Types = Masc.Keeper_memory_os_types
module Policy = Masc.Keeper_memory_os_policy
module Memory_io = Masc.Keeper_memory_os_io
module GC = Masc.Keeper_memory_os_gc
module Recall = Masc.Keeper_memory_os_recall
module Consolidator = Masc.Keeper_memory_os_consolidator

external unsetenv : string -> unit = "masc_test_unsetenv"

(* ---------- tiny verdict framework (prints + exit code) ---------- *)

let passed = ref 0
let failed = ref 0

let check msg cond =
  if cond
  then (
    incr passed;
    Printf.printf "  [PASS] %s\n%!" msg)
  else (
    incr failed;
    Printf.printf "  [FAIL] %s\n%!" msg)
;;

let note fmt = Printf.ksprintf (fun s -> Printf.printf "    · %s\n%!" s) fmt
let section title = Printf.printf "\n=== %s ===\n%!" title

(* ---------- fixture helpers (faithful to test_keeper_memory_os conventions) ---------- *)

let contains substring s =
  let sub_len = String.length substring in
  let str_len = String.length s in
  let rec aux i =
    if i + sub_len > str_len
    then false
    else if String.sub s i sub_len = substring
    then true
    else aux (i + 1)
  in
  if sub_len = 0 then true else aux 0
;;

let mk_fact
      ~now
      ?(category = Types.Fact)
      ?(valid_until = None)
      ?(age_seconds = 3600.0)
      ?(claim_kind = None)
      claim
  =
  { Types.claim
  ; Types.category
  ; Types.external_ref = None
  ; Types.claim_kind
  ; Types.source = { Types.trace_id = "harness-trace"; Types.turn = 1; Types.tool_call_id = None }
  ; Types.observed_by = []
  ; Types.first_seen = now -. age_seconds
  ; Types.valid_until
  ; Types.last_verified_at = Some (now -. age_seconds)
  ; Types.schema_version = Types.schema_version
  ; Types.claim_id = None
  }
;;

let mk_episode ~created_at claim_strings =
  { Types.trace_id = "harness-ep"
  ; Types.generation = 0
  ; Types.episode_summary = "harness episode"
  ; Types.claims =
      List.map (fun claim -> mk_fact ~now:created_at claim) claim_strings
  ; Types.open_items = []
  ; Types.constraints = []
  ; Types.preserved_tool_refs = []
  ; Types.source_turn_range = None
  ; Types.created_at
  ; Types.valid_until = None
  ; Types.terminal_marker = None
  ; Types.schema_version = Types.schema_version
  }
;;

let with_temp_keepers_dir f =
  let marker = Filename.temp_file "memory-os-brain-harness-" ".tmp" in
  Sys.remove marker;
  Memory_io.For_testing.with_keepers_dir marker (fun () -> f marker)
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> unsetenv name
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () -> restore_env name old)
    (fun () ->
      Unix.putenv name value;
      f ())
;;

let with_shared_consolidator_enabled f =
  with_env "MASC_KEEPER_MEMORY_OS_CONSOLIDATE" "true" f
;;

let has_memory_os_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.memory_os_recall.context.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_memory_os_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_memory_os_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let with_prompt_registry f =
  Fun.protect ~finally:Prompt_registry.clear (fun () ->
    Prompt_registry.clear ();
    Prompt_registry.set_markdown_dir (Filename.concat (repo_root ()) "config/prompts");
    Masc.Prompt_defaults.init ();
    f ())
;;

(* ---------- S1 consolidation typed-gate (#21244): non-vacuity + teeth ---------- *)

let scenario_consolidation_gate () =
  section "S1 consolidation typed-gate (#21244) — non-vacuity + teeth";
  let now = 1_000_000.0 in
  let eph c = mk_fact ~now ~category:Types.Ephemeral c in
  let approach c =
    mk_fact
      ~now
      ~category:Types.Validated_approach
      ~claim_kind:(Some Types.Durable_knowledge)
      c
  in
  let lesson c =
    mk_fact
      ~now
      ~category:Types.Lesson
      ~claim_kind:(Some Types.Durable_knowledge)
      c
  in
  (* Modelled on the #21244 live finding: the ONLY >=2-keeper-corroborated claims
     were ephemeral lifecycle boilerplate. Here two ephemeral claims AND two
     outcome-positive durable claims each clear the 2-keeper bar; single-keeper
     noise must never promote regardless of category. *)
  let keeper_facts =
    [ "alpha", [ eph "checkpoint saved"; eph "no tasks pending"; approach "dune cache disabled fixes stale cmx"; approach "alpha local scratch note" ]
    ; "beta", [ eph "checkpoint saved"; eph "no tasks pending"; approach "dune cache disabled fixes stale cmx"; lesson "must not push directly to main" ]
    ; "gamma", [ eph "checkpoint saved"; lesson "must not push directly to main" ]
    ; "delta", [ approach "dune cache disabled fixes stale cmx" ]
    ]
  in
  note "non-vacuity: ephemeral corroborated by >=2 keepers = {checkpoint saved (3), no tasks pending (2)} = 2 present";
  note "non-vacuity: outcome-positive durable corroborated by >=2 keepers = {dune cache disabled fixes stale cmx (3 Validated_approach), must not push directly to main (2 Lesson)} = 2 present";
  let _considered, promoted = Consolidator.promote_facts ~now ~keeper_facts () in
  let promoted_claims = List.map (fun f -> f.Types.claim) promoted |> List.sort String.compare in
  check "exactly 2 claims promoted (completeness — not '>= something')" (List.length promoted = 2);
  check
    "promoted set is exactly the two outcome-positive durable claims"
    (promoted_claims = [ "dune cache disabled fixes stale cmx"; "must not push directly to main" ]);
  check
    "no promoted fact is outside the shared outcome-positive gate"
    (List.for_all
       (fun f ->
          Types.is_promotable f.Types.category
          && Types.is_outcome_positive_for_shared_promotion f.Types.category)
       promoted);
  (* Teeth: reproduce the #21244 pathology by mislabelling the SAME ephemeral
     claims as validated approaches. If they now promote, the gate's decision
     provably hinges on the category label. *)
  let relabel f =
    if f.Types.category = Types.Ephemeral
    then
      { f with
        Types.category = Types.Validated_approach
      ; Types.claim_kind = Some Types.Durable_knowledge
      }
    else f
  in
  let mislabeled = List.map (fun (k, fs) -> (k, List.map relabel fs)) keeper_facts in
  let _c2, promoted_bug = Consolidator.promote_facts ~now ~keeper_facts:mislabeled () in
  check
    "TEETH: mislabel ephemeral->validated_approach and they leak (promoted 2 -> 4) — gate is real, label is load-bearing"
    (List.length promoted_bug = 4);
  note "=> verifies the GATE, not the PRODUCER. Whether the LLM labels boilerplate 'ephemeral' is unverified here."
;;

(* ---------- S2 forgetting (GC) ∘ consolidation composition (disk-backed) ---------- *)

let scenario_forgetting_composition () =
  section "S2 forgetting (GC) ∘ consolidation composition (disk-backed)";
  with_temp_keepers_dir (fun _dir ->
    let now = 2_000_000.0 in
    let expired = mk_fact ~now ~category:Types.Ephemeral ~valid_until:(Some (now -. 10.0)) "scheduled tick alpha" in
    let durable =
      mk_fact
        ~now
        ~category:Types.Lesson
        ~claim_kind:(Some Types.Durable_knowledge)
        ~valid_until:None
        "dune build invariant holds"
    in
    Memory_io.append_fact ~keeper_id:"alpha" expired;
    Memory_io.append_fact ~keeper_id:"alpha" durable;
    Memory_io.append_fact ~keeper_id:"beta" durable;
    check "non-vacuity: the seeded ephemeral IS ttl-expired at now" (GC.ttl_expired ~now expired);
    check "non-vacuity: the durable is NOT ttl-expired (no over-prune bait)" (not (GC.ttl_expired ~now durable));
    let report =
      with_shared_consolidator_enabled (fun () ->
        Consolidator.run ~keeper_ids:[ "alpha"; "beta" ] ~now ())
    in
    check
      "consolidator run status is enabled by explicit harness opt-in"
      (match report.Consolidator.status with
       | Consolidator.Consolidation_ran -> true
       | Consolidator.Consolidation_disabled -> false);
    let shared_before = List.length (Memory_io.read_facts_all ~keeper_id:"_shared") in
    check "consolidation promoted the durable to _shared (shared = 1)" (shared_before = 1);
    check
      "production GC sweep excludes _shared (list_fact_store_keeper_ids omits it)"
      (not (List.mem "_shared" (Memory_io.list_fact_store_keeper_ids ())));
    let g = GC.run_gc ~keeper_id:"alpha" ~now () in
    note "alpha GC: ttl_expired=%d dedup=%d written=%d" g.GC.ttl_expired g.GC.dedup_removed g.GC.written;
    let _ = GC.run_gc ~keeper_id:"beta" ~now () in
    let alpha_after = List.map (fun f -> f.Types.claim) (Memory_io.read_facts_all ~keeper_id:"alpha") in
    check "GC forgot the expired ephemeral" (not (List.mem "scheduled tick alpha" alpha_after));
    check "GC kept the durable fact" (List.mem "dune build invariant holds" alpha_after);
    let shared_after = List.length (Memory_io.read_facts_all ~keeper_id:"_shared") in
    check "composition: _shared untouched by the keeper GC sweep (1 = 1)" (shared_after = shared_before))
;;

(* ---------- S3 structural recall ordering (RFC-0247 purge) ---------- *)

let scenario_structural_recall () =
  section "S3 structural recall ordering — truth-anchor recency (RFC-0247 purge)";
  with_prompt_registry (fun () ->
    with_temp_keepers_dir (fun _dir ->
      let now = 3_000_000.0 in
      let kid = "k" in
      (* older: verified long ago; newer: verified recently. Both are current and
         durable. The ONLY difference is the truth anchor, so any ordering is
         attributable solely to structural recency. *)
      let older = mk_fact ~now ~category:Types.Fact ~age_seconds:86_400.0 "older verified fact" in
      let newer = mk_fact ~now ~category:Types.Fact ~age_seconds:60.0 "newer verified fact" in
      List.iter (Memory_io.append_fact ~keeper_id:kid) [ older; newer ];
      let rendered = Recall.render_context ~keeper_id:kid ~now ~max_facts:1 () in
      check "newer fact is recalled first (structural recency)" (contains "newer verified fact" rendered);
      check "older fact is omitted from top-1" (not (contains "older verified fact" rendered));
      let rendered2 = Recall.render_context ~keeper_id:kid ~now ~max_facts:2 () in
      check "both facts appear when max_facts=2" (contains "older verified fact" rendered2);
      note "recall order is deterministic structure, not a score or activation boost"))
;;

(* ---------- S4 truth-anchor refresh via production write path + control ---------- *)

let scenario_truth_anchor_refresh () =
  section "S4 truth-anchor refresh (RFC-0247 reobserve) — production write path + control";
  with_temp_keepers_dir (fun _dir ->
    let now = 4_000_000.0 in
    let kid = "k" in
    let target = mk_fact ~now ~category:Types.Fact ~age_seconds:3600.0 "truth target claim text" in
    let control = mk_fact ~now ~category:Types.Fact ~age_seconds:3600.0 "untouched control claim text" in
    Memory_io.append_fact ~keeper_id:kid target;
    Memory_io.append_fact ~keeper_id:kid control;
    let later = now +. 100.0 in
    let incoming = [ mk_fact ~now:later ~category:Types.Fact ~age_seconds:0.0 "truth target claim text" ] in
    let window = Memory_io.fact_recall_window in
    (* Replicates keeper_librarian_runtime.ml exactly: upsert via reobserve_fact. *)
    let stats =
      Memory_io.merge_and_cap_facts
        ~now:later
        ~keeper_id:kid
        ~merge:(Policy.reobserve_fact ~now:later)
        ~incoming
        ~keep:window
        ~trigger:(window + (window / 2))
        ~rank:(Policy.retention_rank ~now:later)
    in
    note "merge stats: merged=%d appended=%d dropped=%d" stats.Memory_io.merged stats.Memory_io.appended stats.Memory_io.dropped;
    check "re-observation folded into existing row (merged=1, not appended)" (stats.Memory_io.merged = 1 && stats.Memory_io.appended = 0);
    let facts = Memory_io.read_facts_all ~keeper_id:kid in
    let find c = List.find_opt (fun f -> f.Types.claim = c) facts in
    (match find "truth target claim text" with
     | Some f ->
       check "PROPERTY: target last_verified_at advanced to later" (f.Types.last_verified_at = Some later);
       check "PROPERTY: target first_seen provenance preserved" (f.Types.first_seen = target.Types.first_seen)
     | None -> check "target fact present after upsert" false);
    match find "untouched control claim text" with
    | Some f ->
      check "CONTROL: the un-reobserved fact keeps original last_verified_at"
        (f.Types.last_verified_at = target.Types.last_verified_at)
    | None -> check "control fact present" false)
;;

(* ---------- observability: read-only dry-run against a real store ---------- *)

let observe_real_store dir =
  section (Printf.sprintf "OBSERVABILITY (read-only dry-run) — real store: %s" dir);
  Memory_io.For_testing.with_keepers_dir dir (fun () ->
    try
      let now = Unix.gettimeofday () in
      let keeper_ids = Memory_io.list_fact_store_keeper_ids () in
      note "keepers with a fact store: %d" (List.length keeper_ids);
      let r = Consolidator.run ~dry_run:true ~keeper_ids ~now () in
      note
        "consolidation DRY-RUN: keepers_scanned=%d claims_considered=%d would_promote=%d"
        r.Consolidator.keepers_scanned
        r.Consolidator.claims_considered
        r.Consolidator.promoted;
      List.iter
        (fun kid ->
           let g = GC.run_gc ~dry_run:true ~keeper_id:kid ~now () in
           if g.GC.ttl_expired > 0 || g.GC.dedup_removed > 0
           then
             note
               "GC DRY-RUN keeper=%s would prune: ttl_expired=%d dedup=%d (of %d)"
               kid
               g.GC.ttl_expired
               g.GC.dedup_removed
               g.GC.total_input)
        keeper_ids;
      note "dry-run only — no writes; observability, not pass/fail (real ground truth unknown)"
    with
    | exn -> note "observability aborted: %s" (Printexc.to_string exn))
;;

(* ---------- main ---------- *)

let real_keepers_dir argv =
  let rec find = function
    | "--keepers-dir" :: dir :: _ -> Some dir
    | _ :: rest -> find rest
    | [] -> None
  in
  find (Array.to_list argv)
;;

let () =
  Printf.printf "MEMORY-OS BRAIN HARNESS — deterministic end-to-end organ-composition verification\n%!";
  Printf.printf "VERIFIES: typed-gate teeth (#21244) · GC∘consolidation composition · structural recall ordering · truth-anchor refresh\n%!";
  Printf.printf "DOES NOT VERIFY: LLM producer category/value judgments · live-fleet behaviour · env-fiber scheduling (see module doc)\n%!";
  scenario_consolidation_gate ();
  scenario_forgetting_composition ();
  scenario_structural_recall ();
  scenario_truth_anchor_refresh ();
  (match real_keepers_dir Sys.argv with
   | Some dir -> observe_real_store dir
   | None -> ());
  Printf.printf "\n=== SUMMARY: %d passed, %d failed ===\n%!" !passed !failed;
  if !failed > 0 then exit 1
;;
