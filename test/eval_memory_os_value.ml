(** eval_memory_os_value.ml — RFC-0247 §-1 P-1: memory-os value METRIC (math only).

    The VALUE measurement of the live store is done by an LLM judge. This file
    models only whether a fact has later-turn value ([Useful]) or is noise
    ([Noise]); neither label is persisted and neither authorizes retention or
    expiry.

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
  | Noise
  | Useful
  | Uncertain (* undecided; excluded from the score's denominator *)

let is_noise = function Noise -> true | Useful | Uncertain -> false
let is_useful = function Useful -> true | Noise | Uncertain -> false

(* noise_rate = noise / (noise + useful). [Uncertain] is excluded from the
   denominator; an empty decided set is 0.0 (no KNOWN noise), never a div-by-zero. *)
let noise_rate (labelled : (string * label) list) =
  let noise = List.length (List.filter (fun (_, label) -> is_noise label) labelled) in
  let useful = List.length (List.filter (fun (_, label) -> is_useful label) labelled) in
  let decided = noise + useful in
  if decided = 0 then 0.0 else float_of_int noise /. float_of_int decided
;;

let useful_present labelled = List.exists (fun (_, label) -> is_useful label) labelled

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
  Alcotest.(check (float 0.001)) "all noise -> 1.0" 1.0
    (noise_rate [ "a", Noise; "b", Noise ]);
  Alcotest.(check (float 0.001)) "all useful -> 0.0" 0.0
    (noise_rate [ "a", Useful; "b", Useful ]);
  Alcotest.(check (float 0.001)) "half/half -> 0.5" 0.5
    (noise_rate [ "a", Noise; "b", Useful ]);
  Alcotest.(check (float 0.001)) "uncertain excluded from denominator" 1.0
    (noise_rate [ "a", Noise; "b", Uncertain ])
;;

let test_non_vacuity () =
  (* the metric can tell a store with later-turn value from one without *)
  Alcotest.(check bool) "useful fact present" true
    (useful_present [ "a", Useful; "b", Noise ]);
  Alcotest.(check bool) "all-noise has no useful fact" false
    (useful_present [ "a", Noise ])
;;

let test_calibration_gate_math () =
  (* anti-rig gate (math): a faithful judge scores 1.0; a non-discriminating judge
     that labels everything Useful to flatter the score is caught (< 0.6). 0b runs
     this against the HUMAN gold over a live model before trusting it. *)
  let gold = [ "x", Useful; "y", Noise; "z", Noise ] in
  Alcotest.(check (float 0.001)) "faithful judge -> 1.0" 1.0
    (judge_accuracy ~gold ~judged:gold);
  let lazy_all_useful = List.map (fun (claim, _) -> claim, Useful) gold in
  Alcotest.(check bool) "lazy judge caught (< 0.6)" true
    (judge_accuracy ~gold ~judged:lazy_all_useful < 0.6)
;;

let () =
  Alcotest.run
    "eval_memory_os_value"
    [ "metric", [ Alcotest.test_case "teeth: discriminates" `Quick test_metric_teeth ]
    ; "non_vacuity", [ Alcotest.test_case "useful detection" `Quick test_non_vacuity ]
    ; ( "calibration"
      , [ Alcotest.test_case "anti-rig gate math" `Quick test_calibration_gate_math ] )
    ]
;;
