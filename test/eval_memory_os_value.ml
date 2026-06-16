(** eval_memory_os_value.ml — RFC-0247 §-1 P-1: memory-os value METRIC (math only).

    The VALUE measurement of the live store is done by the LLM judge in
    [scripts/memory_os_judge_eval.py] (step 0b): it labels each fact
    durable|ephemeral via `sb glm-text` and reports this same noise_rate, validated
    against a small human-anchored gold set before its numbers are trusted.

    Per the 2026-06-16 directive (replace heuristic/manual-recorded parts with LLM
    judgement), this file no longer hand-records any labels: the gold calibration
    claims and the frozen `_shared` snapshot moved to the LLM judge. What stays here
    is ONLY the metric's math, so the judge and any future consumer agree on what
    [noise_rate] means. Tests use synthetic labels — no hand-labelled real claims,
    no recorded baseline number.

    Anti-fake-success is enforced where the judgement actually happens (0b: the judge
    must reproduce the human gold via [judge_accuracy] before its live numbers count),
    not by hand-coding a baseline here. *)

type label =
  | Ephemeral
  | Durable
  | Uncertain (* undecided; excluded from the score's denominator *)

let is_ephemeral = function Ephemeral -> true | Durable | Uncertain -> false
let is_durable = function Durable -> true | Ephemeral | Uncertain -> false

(* noise_rate = ephemeral / (ephemeral + durable). [Uncertain] is excluded from the
   denominator; an empty decided set is 0.0 (no KNOWN noise), never a div-by-zero. *)
let noise_rate (labelled : (string * label) list) =
  let eph = List.length (List.filter (fun (_, l) -> is_ephemeral l) labelled) in
  let dur = List.length (List.filter (fun (_, l) -> is_durable l) labelled) in
  let decided = eph + dur in
  if decided = 0 then 0.0 else float_of_int eph /. float_of_int decided
;;

let durable_present labelled = List.exists (fun (_, l) -> is_durable l) labelled

(* Accuracy of a judge's labels against a gold set, over the gold's decided entries.
   0b applies this against the human-anchored gold over a live model; here it is
   exercised on synthetic inputs to pin the math. *)
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

(* --- tests: the metric's math only, on synthetic labels --- *)

let test_metric_teeth () =
  (* the metric must DISCRIMINATE, else it is vacuous *)
  Alcotest.(check (float 0.001)) "all ephemeral -> 1.0" 1.0
    (noise_rate [ "a", Ephemeral; "b", Ephemeral ]);
  Alcotest.(check (float 0.001)) "all durable -> 0.0" 0.0
    (noise_rate [ "a", Durable; "b", Durable ]);
  Alcotest.(check (float 0.001)) "half/half -> 0.5" 0.5
    (noise_rate [ "a", Ephemeral; "b", Durable ]);
  Alcotest.(check (float 0.001)) "uncertain excluded from denominator" 1.0
    (noise_rate [ "a", Ephemeral; "b", Uncertain ])
;;

let test_non_vacuity () =
  (* the metric can tell a store WITH durable knowledge from one without *)
  Alcotest.(check bool) "durable present detected" true
    (durable_present [ "a", Durable; "b", Ephemeral ]);
  Alcotest.(check bool) "all-ephemeral has no durable" false
    (durable_present [ "a", Ephemeral ])
;;

let test_calibration_gate_math () =
  (* anti-rig gate (math): a faithful judge scores 1.0; a non-discriminating judge
     that labels everything Durable to flatter the score is caught (< 0.6). 0b runs
     this against the HUMAN gold over a live model before trusting it. *)
  let gold = [ "x", Durable; "y", Ephemeral; "z", Ephemeral ] in
  Alcotest.(check (float 0.001)) "faithful judge -> 1.0" 1.0
    (judge_accuracy ~gold ~judged:gold);
  let lazy_all_durable = List.map (fun (c, _) -> c, Durable) gold in
  Alcotest.(check bool) "lazy judge caught (< 0.6)" true
    (judge_accuracy ~gold ~judged:lazy_all_durable < 0.6)
;;

let () =
  Alcotest.run
    "eval_memory_os_value"
    [ "metric", [ Alcotest.test_case "teeth: discriminates" `Quick test_metric_teeth ]
    ; "non_vacuity", [ Alcotest.test_case "durable detection" `Quick test_non_vacuity ]
    ; ( "calibration"
      , [ Alcotest.test_case "anti-rig gate math" `Quick test_calibration_gate_math ] )
    ]
;;
