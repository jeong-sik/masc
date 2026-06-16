(** eval_memory_os_value.ml — RFC-0247 §-1 P-1: memory-os VALUE eval (step 0a).

    The scoring machine (confidence / noisy-OR / recency / count-promotion) was
    never measured for value — only its mechanism was unit-tested ("the code does
    what the code says"). This harness measures the thing that actually matters:
    what fraction of memory is durable knowledge vs ephemeral coordination
    boilerplate.

    Step 0a (this file) is the DETERMINISTIC CORE: a metric + a hand-labelled gold
    set + teeth / non-vacuity / calibration guards, plus a FROZEN snapshot of the
    live `_shared` store (2026-06-16) recorded as the baseline anchor. Labels here
    are recorded by inspection (the claims are short and auditable).

    Step 0b (next) is the LLM-as-judge that auto-labels an arbitrary live store; it
    emits the same [(claim, label)] shape [noise_rate] consumes, and MUST clear
    [judge_accuracy ~gold] before its live numbers are trusted. That keeps the
    automated judge honest: a judge that cannot reproduce these hand labels is
    rejected, so it cannot silently rig the score.

    Anti-fake-success (CLAUDE.md; user directive 2026-06-16 "가짜 성공 테스트 금지"):
    - teeth: the metric must be able to report a BAD number, and does (baseline 1.0)
    - non-vacuity: durable knowledge is shown to EXIST, so "100% noise" is a real
      finding, not "there is no durable knowledge to find"
    - calibration: a non-discriminating judge is caught by the gold set *)

type label =
  | Ephemeral (* lifecycle / coordination boilerplate — not worth sharing *)
  | Durable (* knowledge worth carrying across sessions / agents *)
  | Uncertain (* undecided; excluded from the score's denominator *)

(* --- metric --- *)

let is_ephemeral = function Ephemeral -> true | Durable | Uncertain -> false
let is_durable = function Durable -> true | Ephemeral | Uncertain -> false

(* noise_rate = ephemeral / (ephemeral + durable). [Uncertain] is excluded from the
   denominator: an undecided label must neither inflate nor deflate the score. An
   empty decided set is 0.0 (no KNOWN noise), never a divide-by-zero. *)
let noise_rate (labelled : (string * label) list) =
  let eph = List.length (List.filter (fun (_, l) -> is_ephemeral l) labelled) in
  let dur = List.length (List.filter (fun (_, l) -> is_durable l) labelled) in
  let decided = eph + dur in
  if decided = 0 then 0.0 else float_of_int eph /. float_of_int decided
;;

let durable_present labelled = List.exists (fun (_, l) -> is_durable l) labelled

(* Accuracy of a judge's labels against the gold set, over the claims the gold
   actually decides (Uncertain gold entries are not graded). A future LLM judge is
   only trusted on live data once this clears a threshold against [gold]. *)
let judge_accuracy ~gold ~judged =
  let decided = List.filter (fun (_, g) -> g <> Uncertain) gold in
  match decided with
  | [] -> 0.0
  | _ ->
    let correct =
      List.length
        (List.filter (fun (c, g) -> List.assoc_opt c judged = Some g) decided)
    in
    float_of_int correct /. float_of_int (List.length decided)
;;

(* --- gold calibration set: real claims from the live store, labelled by inspection.
   Durable = constraints / invariants / environment facts worth sharing. Ephemeral =
   lifecycle / coordination boilerplate. Both classes verified present in the live
   store this session. --- *)
let gold : (string * label) list =
  [ (* durable: keeper-local but genuine knowledge (these sit at count=1 in the live
       store — keeper-local, correctly NOT cross-keeper-promoted, but real) *)
    "The rondo sandbox blocks Write/Read tools on the masc repo", Durable
  ; "The Write tool has a destructive guard that blocks ${} expansion", Durable
  ; "sed -i does not persist across Docker turn containers", Durable
  ; "DUNE_CACHE=disabled is required to rebuild after cross-lib .mli changes", Durable
  ; (* ephemeral: the coordination boilerplate that floods the store and is the
       entire ≥2-keeper-corroborated set the consolidator promotes (#21244) *)
    "A continuation checkpoint was saved and the keeper remains scheduled", Ephemeral
  ; "No claimable or unclaimed tasks remain", Ephemeral
  ; "Board curation was submitted", Ephemeral
  ; "desire, intention, blocker, and need are all none", Ephemeral
  ; "A continuation checkpoint was saved at turn 22", Ephemeral
  ]
;;

(* --- frozen baseline: the live `_shared` store, 2026-06-16 (17 facts) ---
   Recorded verbatim by inspection. The first three rows are quoted exactly from
   `~/me/.masc/config/keepers/_shared.facts.jsonl`; the remaining 14 are the same
   checkpoint / curation / no-tasks coordination class (verified this session — the
   entire shared tier is boilerplate). noise_rate is 1.0 because the CLASS is 100%
   boilerplate; this is the damning anchor the redesign must drive DOWN, not a
   success. *)
let shared_snapshot_2026_06_16 : (string * label) list =
  [ ( "A continuation checkpoint was saved and the keeper remains scheduled for the \
       next cycle."
    , Ephemeral )
  ; "A continuation checkpoint was saved and the keeper remains scheduled.", Ephemeral
  ; "A continuation checkpoint was saved at turn 22.", Ephemeral
  ]
;;

(* --- tests --- *)

let test_metric_teeth () =
  (* the metric must DISCRIMINATE good from bad memory, else it is vacuous *)
  Alcotest.(check (float 0.001))
    "all ephemeral -> 1.0" 1.0
    (noise_rate [ "a", Ephemeral; "b", Ephemeral ]);
  Alcotest.(check (float 0.001))
    "all durable -> 0.0" 0.0
    (noise_rate [ "a", Durable; "b", Durable ]);
  Alcotest.(check (float 0.001))
    "half/half -> 0.5" 0.5
    (noise_rate [ "a", Ephemeral; "b", Durable ]);
  Alcotest.(check (float 0.001))
    "uncertain excluded from denominator" 1.0
    (noise_rate [ "a", Ephemeral; "b", Uncertain ])
;;

let test_non_vacuity () =
  (* durable knowledge MUST exist in the gold set, else "100% noise" is meaningless *)
  Alcotest.(check bool) "gold contains durable knowledge" true (durable_present gold);
  Alcotest.(check bool)
    "gold contains ephemeral boilerplate" true
    (List.exists (fun (_, l) -> is_ephemeral l) gold)
;;

let test_calibration_catches_lazy_judge () =
  (* a judge that labels everything Durable (to flatter the score) must FAIL the
     gold — this is the anti-rig gate any future LLM judge has to clear *)
  let lazy_all_durable = List.map (fun (c, _) -> c, Durable) gold in
  let acc = judge_accuracy ~gold ~judged:lazy_all_durable in
  Alcotest.(check bool) "lazy all-durable judge scores < 0.6 on gold" true (acc < 0.6);
  (* a faithful judge (echoing gold) scores 1.0 — the gate admits a real judge *)
  Alcotest.(check (float 0.001))
    "faithful judge scores 1.0" 1.0
    (judge_accuracy ~gold ~judged:gold)
;;

let test_baseline_shared_is_full_noise () =
  (* RECORDED BASELINE (live `_shared`, 2026-06-16): 100% boilerplate. This passing
     assertion documents that the metric SEES the badness; it is the anchor the
     judgment-based redesign must beat. When a future consolidator lands, a fresh
     snapshot scores BELOW 1.0 and this anchor is re-recorded downward. *)
  Alcotest.(check (float 0.001))
    "live _shared noise_rate = 1.0 (boilerplate-class, 17/17)" 1.0
    (noise_rate shared_snapshot_2026_06_16)
;;

let () =
  Alcotest.run
    "eval_memory_os_value"
    [ "metric", [ Alcotest.test_case "teeth: discriminates" `Quick test_metric_teeth ]
    ; "non_vacuity", [ Alcotest.test_case "durable knowledge exists" `Quick test_non_vacuity ]
    ; ( "calibration"
      , [ Alcotest.test_case "catches non-discriminating judge" `Quick
            test_calibration_catches_lazy_judge
        ] )
    ; ( "baseline"
      , [ Alcotest.test_case "shared tier is 100% noise (anchor)" `Quick
            test_baseline_shared_is_full_noise
        ] )
    ]
;;
