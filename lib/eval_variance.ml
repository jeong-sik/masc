(* Eval_variance — run-variance measurement spine (task-628 / roadmap M1).
   See eval_variance.mli for the contract. Statistics are stdlib-only; the
   JSON serializer uses yojson (a leaf dep, no masc_mcp-internal coupling). *)

type variance_band = {
  mean : float;
  std : float;
  n : int;
  stderr : float;
  ci_low : float;
  ci_high : float;
  ci_width : float;
  confidence : float;
}

(* Acklam's inverse normal CDF (probit). Returns z such that Phi(z) = p,
   for p in (0,1). Max relative error ~1.15e-9 over the central region.
   Reference: P.J. Acklam, "An algorithm for computing the inverse normal
   cumulative distribution function". *)
let probit p =
  let a0 = -3.969683028665376e+01 and a1 = 2.209460984245205e+02
  and a2 = -2.759285104469687e+02 and a3 = 1.383577518672690e+02
  and a4 = -3.066479806614716e+01 and a5 = 2.506628277459239e+00 in
  let b0 = -5.447609879822406e+01 and b1 = 1.615858368580409e+02
  and b2 = -1.556989798598866e+02 and b3 = 6.680131188771972e+01
  and b4 = -1.328068155288572e+01 in
  let c0 = -7.784894002430293e-03 and c1 = -3.223964580411365e-01
  and c2 = -2.400758277161838e+00 and c3 = -2.549732539343734e+00
  and c4 = 4.374664141464968e+00 and c5 = 2.938163982698783e+00 in
  let d0 = 7.784695709041462e-03 and d1 = 3.224671290700398e-01
  and d2 = 2.445134137142996e+00 and d3 = 3.754408661907416e+00 in
  let p_low = 0.02425 in
  let p_high = 1.0 -. p_low in
  if p <= 0.0 then neg_infinity
  else if p >= 1.0 then infinity
  else if p < p_low then
    let q = sqrt (-2.0 *. log p) in
    (((((c0 *. q +. c1) *. q +. c2) *. q +. c3) *. q +. c4) *. q +. c5)
    /. ((((d0 *. q +. d1) *. q +. d2) *. q +. d3) *. q +. 1.0)
  else if p <= p_high then
    let q = p -. 0.5 in
    let r = q *. q in
    (((((a0 *. r +. a1) *. r +. a2) *. r +. a3) *. r +. a4) *. r +. a5) *. q
    /. (((((b0 *. r +. b1) *. r +. b2) *. r +. b3) *. r +. b4) *. r +. 1.0)
  else
    let q = sqrt (-2.0 *. log (1.0 -. p)) in
    -.((((( c0 *. q +. c1) *. q +. c2) *. q +. c3) *. q +. c4) *. q +. c5)
    /. ((((d0 *. q +. d1) *. q +. d2) *. q +. d3) *. q +. 1.0)

(* Keep a confidence level strictly inside (0,1) so probit is finite. *)
let clamp_confidence c =
  let eps = 1e-9 in
  match classify_float c with
  | FP_nan -> 0.95
  | FP_infinite -> if c < 0.0 then eps else 1.0 -. eps
  | FP_normal | FP_subnormal | FP_zero ->
      if c < eps then eps else if c > 1.0 -. eps then 1.0 -. eps else c

let z_for_confidence c =
  let c = clamp_confidence c in
  probit ((1.0 +. c) /. 2.0)

let band_of_scores ?(confidence = 0.95) (scores : float list) :
    variance_band option =
  match scores with
  | [] | [ _ ] -> None
  | _ ->
      let n = List.length scores in
      let nf = float_of_int n in
      let mean = List.fold_left ( +. ) 0.0 scores /. nf in
      let ss =
        List.fold_left
          (fun acc s ->
            let d = s -. mean in
            acc +. (d *. d))
          0.0 scores
      in
      (* sample variance: n-1 denominator (unbiased) *)
      let variance = ss /. (nf -. 1.0) in
      let std = sqrt variance in
      let stderr = std /. sqrt nf in
      let z = z_for_confidence confidence in
      let half = z *. stderr in
      Some
        {
          mean;
          std;
          n;
          stderr;
          ci_low = mean -. half;
          ci_high = mean +. half;
          ci_width = 2.0 *. half;
          confidence = clamp_confidence confidence;
        }

let band_of_proportion ?(confidence = 0.95) ~(trials : int)
    ~(successes : int) () : variance_band option =
  if trials < 1 || successes < 0 || successes > trials then None
  else
    let t = float_of_int trials in
    let p = float_of_int successes /. t in
    let z = z_for_confidence confidence in
    let z2 = z *. z in
    (* Wilson score interval — correct near p=0/1 where the normal
       approximation breaks down. *)
    let denom = 1.0 +. (z2 /. t) in
    let center = (p +. (z2 /. (2.0 *. t))) /. denom in
    let margin =
      z /. denom *. sqrt ((p *. (1.0 -. p) /. t) +. (z2 /. (4.0 *. t *. t)))
    in
    let ci_low = Float.max 0.0 (center -. margin) in
    let ci_high = Float.min 1.0 (center +. margin) in
    let std = sqrt (p *. (1.0 -. p)) in
    let stderr = sqrt (p *. (1.0 -. p) /. t) in
    Some
      {
        mean = p;
        std;
        n = trials;
        stderr;
        ci_low;
        ci_high;
        ci_width = ci_high -. ci_low;
        confidence = clamp_confidence confidence;
      }

type verdict = Improvement | Regression | Inconclusive

type difference = {
  delta : float;
  se : float;
  ci_low : float;
  ci_high : float;
  confidence : float;
  verdict : verdict;
}

let difference ?(confidence = 0.95) ~(baseline : variance_band)
    ~(candidate : variance_band) () : difference =
  let delta = candidate.mean -. baseline.mean in
  let se = sqrt ((baseline.stderr ** 2.0) +. (candidate.stderr ** 2.0)) in
  let z = z_for_confidence confidence in
  (* z *. 0.0 = 0.0, so the se=0 case (identical constant runs) needs no
     special branch: the CI collapses to [delta, delta] and the verdict
     stays exact. *)
  let ci_low = delta -. (z *. se) in
  let ci_high = delta +. (z *. se) in
  let verdict =
    (* the difference CI must EXCLUDE 0 to act on the delta *)
    if ci_low > 0.0 then Improvement
    else if ci_high < 0.0 then Regression
    else Inconclusive
  in
  {
    delta;
    se;
    ci_low;
    ci_high;
    confidence = clamp_confidence confidence;
    verdict;
  }

let compare ?(confidence = 0.95) ~(baseline : variance_band)
    ~(candidate : variance_band) () : verdict =
  (difference ~confidence ~baseline ~candidate ()).verdict

let verdict_to_string = function
  | Improvement -> "improvement"
  | Regression -> "regression"
  | Inconclusive -> "inconclusive"

type gate = { min_runs : int; max_ci_width : float }

let default_gate = { min_runs = 5; max_ci_width = 0.20 }

type gate_result =
  | Gate_ok
  | Too_few_runs of { got : int; need : int }
  | Ci_too_wide of { got : float; max : float }

let check_gate (g : gate) (b : variance_band) : gate_result =
  if b.n < g.min_runs then Too_few_runs { got = b.n; need = g.min_runs }
  else if b.ci_width > g.max_ci_width then
    Ci_too_wide { got = b.ci_width; max = g.max_ci_width }
  else Gate_ok

let variance_band_to_json (b : variance_band) : Yojson.Safe.t =
  `Assoc
    [
      ("mean", `Float b.mean);
      ("std", `Float b.std);
      ("n", `Int b.n);
      ("stderr", `Float b.stderr);
      ("ci_low", `Float b.ci_low);
      ("ci_high", `Float b.ci_high);
      ("ci_width", `Float b.ci_width);
      ("confidence", `Float b.confidence);
    ]

let difference_to_json (d : difference) : Yojson.Safe.t =
  `Assoc
    [
      ("delta", `Float d.delta);
      ("se", `Float d.se);
      ("ci_low", `Float d.ci_low);
      ("ci_high", `Float d.ci_high);
      ("confidence", `Float d.confidence);
      ("verdict", `String (verdict_to_string d.verdict));
    ]
