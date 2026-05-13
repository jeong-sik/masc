(** See [Autoresearch_result_bridge.mli]. *)

(* --- Score orientation + normalization ---
   An autoresearch loop has [lower_is_better] for things like
   val_bpb / loss where a smaller raw score is a better outcome.
   Verification.Partial expects a score in [0.0, 1.0] where higher is
   better. Normalize accordingly against [target_score] if set, else
   fall back to unit range so at least improvement against baseline
   registers above 0.5. *)

let normalize_score ~baseline ~target ~lower_is_better score =
  let range_from_baseline =
    match target with
    | Some t -> Float.abs (t -. baseline)
    | None -> 1.0
  in
  let range_from_baseline =
    if range_from_baseline < 1e-9 then 1.0 else range_from_baseline
  in
  let signed_progress =
    if lower_is_better then baseline -. score
    else score -. baseline
  in
  let progress_ratio = signed_progress /. range_from_baseline in
  (* Map centered at 0.5 (no progress) with ±0.5 for full range. *)
  Float.min 1.0 (Float.max 0.0 (0.5 +. (progress_ratio /. 2.0)))

let target_met ~target ~lower_is_better score =
  match target with
  | None -> false
  | Some t ->
    if lower_is_better then score <= t else score >= t

let rationale_of_cycle (state : Autoresearch.loop_state)
    (record : Autoresearch.cycle_record) =
  let dir = if state.lower_is_better then "lower" else "higher" in
  Printf.sprintf
    "cycle %d, hypothesis %S: %.6f → %.6f (Δ=%+.6f, %s is better)"
    record.cycle record.hypothesis record.score_before record.score_after
    record.delta dir

(* --- Verification verdict mapping --- *)

let verdict_of_cycle (state : Autoresearch.loop_state)
    (record : Autoresearch.cycle_record) : Verification.verdict =
  let rationale = rationale_of_cycle state record in
  match record.decision with
  | Autoresearch.Discard ->
    Verification.Fail
      (Printf.sprintf "autoresearch Discard — %s" rationale)
  | Autoresearch.Keep ->
    if target_met ~target:state.target_score
         ~lower_is_better:state.lower_is_better record.score_after
    then Verification.Pass
    else
      let score =
        normalize_score ~baseline:state.baseline
          ~target:state.target_score
          ~lower_is_better:state.lower_is_better record.score_after
      in
      Verification.Partial (score, rationale)

(* --- Attribution envelope --- *)

let evidence_of_cycle (state : Autoresearch.loop_state)
    (record : Autoresearch.cycle_record) : Yojson.Safe.t =
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("cycle", `Int record.cycle);
      ("hypothesis", `String record.hypothesis);
      ("score_before", `Float record.score_before);
      ("score_after", `Float record.score_after);
      ("delta", `Float record.delta);
      ("model_used", `Null);
      ("elapsed_ms", `Int record.elapsed_ms);
      ("lower_is_better", `Bool state.lower_is_better);
      ( "target_score",
        match state.target_score with
        | Some t -> `Float t
        | None -> `Null );
    ]

let attribution_of_cycle (state : Autoresearch.loop_state)
    (record : Autoresearch.cycle_record) : Attribution.t =
  let evidence = evidence_of_cycle state record in
  let rationale = rationale_of_cycle state record in
  (* Fold rationale into evidence so NonDet origin carries the model's
     explanation through the erased Attribution.t (mirrors the
     Attribution_tagged.nondet_* shape which will replace this once
     #7782 lands). *)
  let evidence_with_rationale =
    match evidence with
    | `Assoc fields ->
      `Assoc (fields @ [ ("rationale", `String rationale) ])
    | other -> other
  in
  match record.decision with
  | Autoresearch.Discard ->
    Attribution.policy_failed ~origin:NonDet ~gate:"autoresearch"
      ~evidence:evidence_with_rationale
      ~reason:
        (Printf.sprintf "autoresearch Discard (loop %s cycle %d)"
           state.loop_id record.cycle)
  | Autoresearch.Keep ->
    if target_met ~target:state.target_score
         ~lower_is_better:state.lower_is_better record.score_after
    then
      Attribution.passed ~origin:NonDet ~gate:"autoresearch"
        ~evidence:evidence_with_rationale
    else
      let score =
        normalize_score ~baseline:state.baseline
          ~target:state.target_score
          ~lower_is_better:state.lower_is_better record.score_after
      in
      Attribution.partial_pass ~origin:NonDet ~gate:"autoresearch"
        ~evidence ~score ~rationale
