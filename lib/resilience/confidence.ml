(* Confidence — Cycle 23 / Tier B7.
   See confidence.mli for the design rationale. *)

module C = Shared_types.Confidence

type factor =
  | Artifact of { producer : string; raw_score : float }
  | Verification of {
      verifier : string;
      score : float;
      evidence : string;
    }
  | Degradation of { level : int; penalty : float }
  | Consensus of {
      agree_count : int;
      total_count : int;
      method_ : string;
    }

type recommendation =
  | NoAction
  | RequestVerification of { who : string; why : string }
  | Degrade of { target_level : int; why : string }
  | Handoff of { reason : string }

type report = {
  final : C.t;
  factors : factor list;
  threshold : float;
  below_threshold : bool;
  recommendation : recommendation option;
}

(* ── Convenience constructors ──────────────────────────────────── *)

let artifact ~producer ~score = Artifact { producer; raw_score = score }

let verification ~verifier ~score ~evidence =
  Verification { verifier; score; evidence }

let degradation ~level ~penalty = Degradation { level; penalty }

let consensus ~agree_count ~total_count ~method_ =
  Consensus { agree_count; total_count; method_ }

(* ── Score extraction ──────────────────────────────────────────── *)

let clamp_unit f =
  if Float.is_nan f then 0.0
  else if f < 0.0 then 0.0
  else if f > 1.0 then 1.0
  else f

let weight_score = function
  | Artifact { raw_score; _ } -> Some (clamp_unit raw_score)
  | Verification { score; _ } -> Some (clamp_unit score)
  | Consensus { agree_count; total_count; _ } ->
      if total_count <= 0 then Some 0.0
      else
        Some
          (clamp_unit
             (float_of_int agree_count /. float_of_int total_count))
  | Degradation _ -> None

let degradation_penalty = function
  | Degradation { penalty; _ } -> Some (clamp_unit penalty)
  | _ -> None

let max_degradation_level factors =
  List.fold_left
    (fun acc f ->
      match f with
      | Degradation { level; _ } -> max acc level
      | _ -> acc)
    0 factors

(* ── Composition: geometric mean × penalties ──────────────────── *)

let geometric_mean scores =
  match scores with
  | [] -> 0.0
  | _ ->
      let n = List.length scores in
      let log_sum =
        List.fold_left
          (fun acc s ->
            (* Treat exact 0 as a hard zero of the geometric mean.
               Otherwise log(0) = -inf would propagate; this is the
               desired semantics — any single factor at 0 forces the
               composite to 0. *)
            if s <= 0.0 then Float.neg_infinity
            else acc +. Float.log s)
          0.0 scores
      in
      if Float.is_finite log_sum then
        Float.exp (log_sum /. float_of_int n)
      else 0.0

let compose_score factors =
  let weight_scores = List.filter_map weight_score factors in
  let penalties = List.filter_map degradation_penalty factors in
  let base = geometric_mean weight_scores in
  List.fold_left ( *. ) base penalties

(* ── Recommendation selection ──────────────────────────────────── *)

let select_recommendation
    ~final_float ~threshold ~factors : recommendation option =
  if final_float >= threshold then None
  else
    let very_low = final_float <= threshold *. 0.5 in
    let has_degradation =
      List.exists (function Degradation _ -> true | _ -> false) factors
    in
    if very_low then
      Some
        (Handoff
           {
             reason =
               Printf.sprintf
                 "confidence %.3f far below threshold %.3f"
                 final_float threshold;
           })
    else if has_degradation then
      Some
        (Degrade
           {
             target_level = max_degradation_level factors + 1;
             why =
               Printf.sprintf
                 "composite %.3f under threshold %.3f despite \
                  Degradation factors present"
                 final_float threshold;
           })
    else
      let weakest_verifier =
        List.find_map
          (function
            | Verification { verifier; _ } -> Some verifier
            | _ -> None)
          factors
      in
      Some
        (RequestVerification
           {
             who = Option.value weakest_verifier ~default:"any-verifier";
             why =
               Printf.sprintf
                 "composite %.3f under threshold %.3f; request \
                  additional verification"
                 final_float threshold;
           })

(* ── Public API ────────────────────────────────────────────────── *)

let evaluate ~factors ~threshold =
  let final_float = compose_score factors in
  let final = C.make final_float in
  let below_threshold = final_float < threshold in
  let recommendation =
    select_recommendation ~final_float ~threshold ~factors
  in
  { final; factors; threshold; below_threshold; recommendation }

let is_acceptable r =
  (not r.below_threshold) && r.recommendation = None

let worst_factor r =
  let value_of f =
    match f with
    | Artifact { raw_score; _ } -> Some (clamp_unit raw_score)
    | Verification { score; _ } -> Some (clamp_unit score)
    | Degradation { penalty; _ } -> Some (clamp_unit penalty)
    | Consensus { agree_count; total_count; _ } ->
        if total_count <= 0 then Some 0.0
        else
          Some
            (clamp_unit
               (float_of_int agree_count /. float_of_int total_count))
  in
  match r.factors with
  | [] -> None
  | first :: rest ->
      let init_score =
        Option.value (value_of first) ~default:1.0
      in
      let _, worst =
        List.fold_left
          (fun (best_score, best_f) f ->
            match value_of f with
            | None -> (best_score, best_f)
            | Some s ->
                if s < best_score then (s, f) else (best_score, best_f))
          (init_score, first) rest
      in
      Some worst
