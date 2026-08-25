(** Evaluation Framework — quantitative agent run assessment.

    Collects metrics from agent runs, compares baselines vs candidates,
    and checks thresholds for regression detection.

    Design:
    - [metric_value] is a closed variant for type-safe comparisons.
    - [collector] is mutable during a run, finalized into immutable [run_metrics].
    - [compare] detects regressions and improvements between two runs.
    - [check_thresholds] produces a {!Harness.verdict} for CI integration. *)

(* ── Metric value ─────────────────────────────────────────────── *)

type metric_value =
  | Int_val of int
  | Float_val of float
  | Bool_val of bool
  | String_val of string

let metric_value_to_yojson = function
  | Int_val i -> `Int i
  | Float_val f -> `Float f
  | Bool_val b -> `Bool b
  | String_val s -> `String s
;;

let metric_value_of_yojson = function
  | `Int i -> Ok (Int_val i)
  | `Float f -> Ok (Float_val f)
  | `Bool b -> Ok (Bool_val b)
  | `String s -> Ok (String_val s)
  | `Assoc _ | `List _ | `Null | `Intlit _ -> Error "expected int, float, bool, or string"
;;

let show_metric_value = function
  | Int_val i -> string_of_int i
  | Float_val f -> Printf.sprintf "%.4f" f
  | Bool_val b -> string_of_bool b
  | String_val s -> s
;;

let pp_metric_value fmt v = Format.fprintf fmt "%s" (show_metric_value v)

let metric_value_to_float = function
  | Int_val i -> Some (float_of_int i)
  | Float_val f -> Some f
  | Bool_val b -> Some (if b then 1.0 else 0.0)
  | String_val _ -> None
;;

let tags_of_json = function
  | `Assoc kvs -> List.map (fun (k, v) -> k, Yojson.Safe.Util.to_string v) kvs
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> []
;;

let numeric_threshold_violated ~compare value threshold =
  match metric_value_to_float value, metric_value_to_float threshold with
  | Some v, Some limit -> compare v limit
  | None, _ | _, None -> false
;;

(* ── Metric ───────────────────────────────────────────────────── *)

type metric =
  { name : string
  ; value : metric_value
  ; unit_ : string option
  ; tags : (string * string) list
  }

let metric_to_yojson m =
  let base = [ "name", `String m.name; "value", metric_value_to_yojson m.value ] in
  let unit_part =
    match m.unit_ with
    | Some u -> [ "unit", `String u ]
    | None -> []
  in
  let tags_part =
    match m.tags with
    | [] -> []
    | tags -> [ "tags", Util.json_of_string_pairs tags ]
  in
  `Assoc (base @ unit_part @ tags_part)
;;

let metric_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let name = json |> member "name" |> to_string in
    let value_json = json |> member "value" in
    match metric_value_of_yojson value_json with
    | Error e -> Error e
    | Ok value ->
      let unit_ = json |> member "unit" |> to_string_option in
      let tags = json |> member "tags" |> tags_of_json in
      Ok { name; value; unit_; tags }
  with
  | Type_error (msg, _) -> Error msg
;;

let show_metric m = Printf.sprintf "%s=%s" m.name (show_metric_value m.value)
let pp_metric fmt m = Format.fprintf fmt "%s" (show_metric m)

(* ── Metric comparison policy ─────────────────────────────────── *)

type metric_goal =
  | Higher
  | Lower
  | Exact

type metric_spec =
  { name : string
  ; goal : metric_goal
  ; tolerance_pct : float
  }

type comparison_error =
  | Duplicate_metric_spec of string
  | Duplicate_baseline_metric of string
  | Duplicate_candidate_metric of string
  | Missing_baseline_metric of string
  | Missing_candidate_metric of string
  | Invalid_tolerance_pct of
      { metric_name : string
      ; tolerance_pct : float
      }

(* ── Run metrics ──────────────────────────────────────────────── *)

type run_metrics =
  { run_id : string
  ; agent_name : string
  ; timestamp : float
  ; metrics : metric list
  ; harness_verdicts : Harness.verdict list
  }

let run_metrics_to_yojson rm =
  let verdicts_json =
    `List
      (List.map
         (fun (v : Harness.verdict) ->
            `Assoc
              [ "passed", `Bool v.passed
              ; ( "score"
                , match v.score with
                  | Some s -> `Float s
                  | None -> `Null )
              ; "evidence", Util.json_of_string_list v.evidence
              ; ( "detail"
                , match v.detail with
                  | Some d -> `String d
                  | None -> `Null )
              ])
         rm.harness_verdicts)
  in
  `Assoc
    [ "run_id", `String rm.run_id
    ; "agent_name", `String rm.agent_name
    ; "timestamp", `Float rm.timestamp
    ; "metrics", `List (List.map metric_to_yojson rm.metrics)
    ; "harness_verdicts", verdicts_json
    ]
;;

let run_metrics_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let run_id = json |> member "run_id" |> to_string in
    let agent_name = json |> member "agent_name" |> to_string in
    let timestamp = json |> member "timestamp" |> to_float in
    let metrics_json = json |> member "metrics" |> to_list in
    let metrics_result =
      List.fold_left
        (fun acc j ->
           match acc with
           | Error _ as e -> e
           | Ok ms ->
             (match metric_of_yojson j with
              | Ok m -> Ok (m :: ms)
              | Error e -> Error e))
        (Ok [])
        metrics_json
    in
    match metrics_result with
    | Error e -> Error e
    | Ok metrics ->
      let metrics = List.rev metrics in
      Ok { run_id; agent_name; timestamp; metrics; harness_verdicts = [] }
  with
  | Type_error (msg, _) -> Error msg
;;

let show_run_metrics rm =
  Printf.sprintf
    "run=%s agent=%s metrics=[%s]"
    rm.run_id
    rm.agent_name
    (String.concat "; " (List.map show_metric rm.metrics))
;;

let pp_run_metrics fmt rm = Format.fprintf fmt "%s" (show_run_metrics rm)

(* ── Collector ────────────────────────────────────────────────── *)

type collector =
  { agent_name : string
  ; run_id : string
  ; mutable metrics : metric list
  ; mutable harness_verdicts : Harness.verdict list
  }

let create_collector ~agent_name ~run_id =
  { agent_name; run_id; metrics = []; harness_verdicts = [] }
;;

let record collector metric = collector.metrics <- metric :: collector.metrics

let add_verdict collector verdict =
  collector.harness_verdicts <- verdict :: collector.harness_verdicts
;;

let finalize collector =
  { run_id = collector.run_id
  ; agent_name = collector.agent_name
  ; timestamp = Unix.gettimeofday ()
  ; metrics = List.rev collector.metrics
  ; harness_verdicts = List.rev collector.harness_verdicts
  }
;;

(* ── Comparison ───────────────────────────────────────────────── *)

type change_direction =
  | Regression
  | Improvement
  | Unchanged

let no_numeric_delta _baseline _candidate = Unchanged, None

type metric_delta =
  { metric_name : string
  ; baseline_value : metric_value
  ; candidate_value : metric_value
  ; direction : change_direction
  ; delta_pct : float option
  }

type comparison =
  { baseline : run_metrics
  ; candidate : run_metrics
  ; regressions : metric_delta list
  ; improvements : metric_delta list
  ; unchanged : metric_delta list
  }

(** Threshold percentage for classifying a delta as regression/improvement.
    Default 5.0%: changes within +/-5% are classified as Unchanged. *)
let default_delta_threshold_pct = 5.0

let compute_delta
      ?(threshold_pct = default_delta_threshold_pct)
      ~baseline_val
      ~candidate_val
      ()
  =
  match metric_value_to_float baseline_val, metric_value_to_float candidate_val with
  | Some bv, Some cv when bv <> 0.0 ->
    let pct = (cv -. bv) /. Float.abs bv *. 100.0 in
    let direction =
      if pct > threshold_pct
      then Regression
      else if pct < -.threshold_pct
      then Improvement
      else Unchanged
    in
    direction, Some pct
  | Some bv, Some cv ->
    let direction =
      if cv > bv then Regression else if cv < bv then Improvement else Unchanged
    in
    direction, None
  | None, _ | _, None -> no_numeric_delta baseline_val candidate_val
;;

let compute_delta_for_goal
      ?(threshold_pct = default_delta_threshold_pct)
      ~goal
      ~baseline_val
      ~candidate_val
      ()
  =
  match goal with
  | Lower -> compute_delta ~threshold_pct ~baseline_val ~candidate_val ()
  | Higher ->
    let direction, pct =
      compute_delta
        ~threshold_pct
        ~baseline_val:candidate_val
        ~candidate_val:baseline_val
        ()
    in
    let pct = Option.map ( ~-. ) pct in
    direction, pct
  | Exact ->
    (match metric_value_to_float baseline_val, metric_value_to_float candidate_val with
     | Some bv, Some cv ->
       let diff = Float.abs (cv -. bv) in
       let pct =
         if Float.abs bv < 1e-10 then None else Some (diff /. Float.abs bv *. 100.0)
       in
       let direction =
         match pct with
         | Some v when v > threshold_pct -> Regression
         | None when diff > 0.0 -> Regression
         | Some _ | None -> Unchanged
       in
       direction, pct
     | None, _ | _, None ->
       if baseline_val = candidate_val then Unchanged, None else Regression, None)
;;

let compare_with_specs ~specs ~(baseline : run_metrics) ~(candidate : run_metrics) =
  let find_unique_metric ~duplicate_error ~missing_error name metrics =
    match
      List.filter (fun (metric : metric) -> String.equal metric.name name) metrics
    with
    | [] -> Error (missing_error name)
    | [ metric ] -> Ok metric
    | _ -> Error (duplicate_error name)
  in
  let rec collect seen deltas = function
    | [] -> Ok (List.rev deltas)
    | (spec : metric_spec) :: rest ->
      if List.exists (String.equal spec.name) seen
      then Error (Duplicate_metric_spec spec.name)
      else if spec.tolerance_pct < 0.0 || not (Float.is_finite spec.tolerance_pct)
      then
        Error
          (Invalid_tolerance_pct
             { metric_name = spec.name; tolerance_pct = spec.tolerance_pct })
      else (
        let ( let* ) = Result.bind in
        let* baseline_metric =
          find_unique_metric
            ~duplicate_error:(fun name -> Duplicate_baseline_metric name)
            ~missing_error:(fun name -> Missing_baseline_metric name)
            spec.name
            baseline.metrics
        in
        let* candidate_metric =
          find_unique_metric
            ~duplicate_error:(fun name -> Duplicate_candidate_metric name)
            ~missing_error:(fun name -> Missing_candidate_metric name)
            spec.name
            candidate.metrics
        in
        let direction, delta_pct =
          compute_delta_for_goal
            ~threshold_pct:spec.tolerance_pct
            ~goal:spec.goal
            ~baseline_val:baseline_metric.value
            ~candidate_val:candidate_metric.value
            ()
        in
        let delta =
          { metric_name = spec.name
          ; baseline_value = baseline_metric.value
          ; candidate_value = candidate_metric.value
          ; direction
          ; delta_pct
          }
        in
        collect (spec.name :: seen) (delta :: deltas) rest)
  in
  let ( let* ) = Result.bind in
  let* deltas = collect [] [] specs in
  let regressions = List.filter (fun d -> d.direction = Regression) deltas in
  let improvements = List.filter (fun d -> d.direction = Improvement) deltas in
  let unchanged = List.filter (fun d -> d.direction = Unchanged) deltas in
  Ok { baseline; candidate; regressions; improvements; unchanged }
;;

(* ── Threshold checking ───────────────────────────────────────── *)

type threshold =
  { metric_name : string
  ; max_value : metric_value option
  ; min_value : metric_value option
  }

let check_thresholds (rm : run_metrics) (thresholds : threshold list) : Harness.verdict =
  let violations =
    List.filter_map
      (fun th ->
         match List.find_opt (fun (m : metric) -> m.name = th.metric_name) rm.metrics with
         | None -> None
         | Some m ->
           (* Build each violation message where the threshold value is in
              scope (parse, don't validate): the [Some v when violated]
              guard carries [v] directly, eliminating the [Option.get] that
              previously re-extracted it from [th.max_value]/[th.min_value]
              under the invariant that the bool guard implied [Some]. Max
              takes priority over min, as before. *)
           let max_violation =
             match th.max_value with
             | Some max_v when numeric_threshold_violated ~compare:( > ) m.value max_v ->
               Some
                 (Printf.sprintf
                    "%s=%s exceeds max %s"
                    th.metric_name
                    (show_metric_value m.value)
                    (show_metric_value max_v))
             | _ -> None
           in
           let min_violation =
             match th.min_value with
             | Some min_v when numeric_threshold_violated ~compare:( < ) m.value min_v ->
               Some
                 (Printf.sprintf
                    "%s=%s below min %s"
                    th.metric_name
                    (show_metric_value m.value)
                    (show_metric_value min_v))
             | _ -> None
           in
           (match max_violation with
            | Some _ -> max_violation
            | None -> min_violation))
      thresholds
  in
  let passed = violations = [] in
  { passed
  ; score = Some (if passed then 1.0 else 0.0)
  ; evidence = violations
  ; detail =
      (if passed
       then Some "all thresholds met"
       else Some (Printf.sprintf "%d threshold violation(s)" (List.length violations)))
  }
;;

(* ── Metric lookup ────────────────────────────────────────────── *)

let find_metric (rm : run_metrics) name =
  List.find_opt (fun (m : metric) -> m.name = name) rm.metrics
;;

let find_metric_value rm name =
  Option.map (fun (m : metric) -> m.value) (find_metric rm name)
;;
