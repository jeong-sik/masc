(** Reward_advice_artifact — Structured advisory artifacts from verifiers and benchmarks.

    Bridges verification verdicts and benchmark scores to the reward system
    with evidence-backed advisory hints.  Follows the same advisory-over-verdict
    principle as Anti_rationalization gate 2: these hints guide reward
    adjustments rather than enforcing them unconditionally.

    The advisory pattern means callers decide whether to apply the recommended
    [reward_multiplier]; the artifact itself is a proposal, not a command.

    @since Task-044 — Advisory Reward Advice Artifacts *)

(** {1 Types} *)

(** Source module that produced this artifact. *)
type advice_source =
  | Post_verifier   (** Heuristic 3-dimension content check. *)
  | Benchmark       (** Tool-call quality benchmark scoring. *)
  | Task_verifier   (** OAS/LLM task action verifier. *)

(** A structured advisory hint from a verifier or benchmark to the reward system. *)
type reward_advice_artifact = {
  source : advice_source;
  agent_name : string;
  task_id : string option;
  verdict : string;            (** "pass", "warn", or "fail" *)
  reward_multiplier : float;   (** Suggested multiplier [0.0, 2.0]; 1.0 = neutral. *)
  advisory_message : string;   (** Human/LLM-readable guidance for the reward system. *)
  evidence_refs : string list; (** References to supporting evidence (tool call ids, etc.). *)
  confidence : float;          (** Confidence in the advice [0.0, 1.0]. *)
  timestamp : float;           (** Unix timestamp of artifact creation. *)
}

(** {1 Source helpers} *)

let advice_source_to_string = function
  | Post_verifier -> "post_verifier"
  | Benchmark -> "benchmark"
  | Task_verifier -> "task_verifier"

let advice_source_of_string = function
  | "post_verifier" -> Some Post_verifier
  | "benchmark" -> Some Benchmark
  | "task_verifier" -> Some Task_verifier
  | _ -> None

(** {1 Reward multiplier helpers} *)

(** Clamp a float to [[lo, hi]]. *)
let clamp ~lo ~hi v = Float.max lo (Float.min hi v)

(** Derive a suggested reward multiplier from a verdict string.

    - "pass" → 1.0 (neutral; may be combined with a bonus from context)
    - "warn" → 0.8 (small penalty; advisory only)
    - "fail" → 0.4 (significant penalty; advisory only)
    - other  → 1.0 (unknown; no adjustment) *)
let multiplier_of_verdict = function
  | "pass" -> 1.0
  | "warn" -> 0.8
  | "fail" -> 0.4
  | _ -> 1.0

(** {1 Serialization} *)

let to_yojson (a : reward_advice_artifact) : Yojson.Safe.t =
  `Assoc [
    ("source", `String (advice_source_to_string a.source));
    ("agent_name", `String a.agent_name);
    ("task_id", Option.fold ~none:`Null ~some:(fun s -> `String s) a.task_id);
    ("verdict", `String a.verdict);
    ("reward_multiplier", `Float a.reward_multiplier);
    ("advisory_message", `String a.advisory_message);
    ("evidence_refs", `List (List.map (fun s -> `String s) a.evidence_refs));
    ("confidence", `Float a.confidence);
    ("timestamp", `Float a.timestamp);
  ]

let string_field ~default key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> s
     | _ -> default)
  | _ -> default

let float_field ~default key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Float f) -> f
     | Some (`Int i) -> float_of_int i
     | _ -> default)
  | _ -> default

let string_list_field key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List items) ->
       List.filter_map (function `String s -> Some s | _ -> None) items
     | _ -> [])
  | _ -> []

let of_yojson (json : Yojson.Safe.t) : (reward_advice_artifact, string) result =
  let source_str = string_field ~default:"" "source" json in
  match advice_source_of_string source_str with
  | None -> Error (Printf.sprintf "reward_advice_artifact: unknown source %S" source_str)
  | Some source ->
    let agent_name = string_field ~default:"" "agent_name" json in
    if agent_name = "" then Error "reward_advice_artifact: agent_name missing"
    else
      let task_id =
        match json with
        | `Assoc fields ->
          (match List.assoc_opt "task_id" fields with
           | Some (`String s) when s <> "" -> Some s
           | _ -> None)
        | _ -> None
      in
      Ok {
        source;
        agent_name;
        task_id;
        verdict = string_field ~default:"pass" "verdict" json;
        reward_multiplier =
          float_field ~default:1.0 "reward_multiplier" json
          |> clamp ~lo:0.0 ~hi:2.0;
        advisory_message = string_field ~default:"" "advisory_message" json;
        evidence_refs = string_list_field "evidence_refs" json;
        confidence = float_field ~default:1.0 "confidence" json |> clamp ~lo:0.0 ~hi:1.0;
        timestamp = float_field ~default:0.0 "timestamp" json;
      }

(** {1 Factory: Post_verifier} *)

(** Build a reward advice artifact from post-verifier verdict components.

    Called by [Post_verifier.to_reward_advice] to avoid a circular dependency.
    The caller is responsible for translating the verdict type to a string.

    - "pass" → multiplier 1.0, confidence 1.0
    - "warn" → multiplier 0.8, confidence 0.9
    - "fail" → multiplier 0.4, confidence 1.0 *)
let of_post_verifier_verdict ~agent_name ?task_id ~verdict ~advisory_message () =
  let confidence =
    match verdict with
    | "warn" -> 0.9   (* heuristic — slightly less certain *)
    | _ -> 1.0
  in
  {
    source = Post_verifier;
    agent_name;
    task_id;
    verdict;
    reward_multiplier = multiplier_of_verdict verdict;
    advisory_message;
    evidence_refs = [];
    confidence;
    timestamp = Time_compat.now ();
  }

(** {1 Factory: Benchmark} *)

(** Build a reward advice artifact from a {!Tool_call_quality_benchmark_types.case_score}.

    Maps [composite_score] → [reward_multiplier] with:
    - score >= 0.8 → pass (multiplier 1.1 bonus)
    - score >= 0.5 → warn (multiplier 0.9)
    - score <  0.5 → fail (multiplier 0.5) *)
let of_benchmark_case_score ~agent_name ?task_id
    (score : Tool_call_quality_benchmark_types.case_score) : reward_advice_artifact =
  let cs = score.composite_score in
  let verdict =
    if cs >= 0.8 then "pass"
    else if cs >= 0.5 then "warn"
    else "fail"
  in
  let reward_multiplier =
    if cs >= 0.8 then 1.1    (* bonus for high-quality tool usage *)
    else if cs >= 0.5 then 0.9
    else 0.5
  in
  let advisory_message =
    Printf.sprintf
      "Benchmark case %s: composite_score=%.3f (task_pass=%.2f, \
       tool_selection=%.2f, arg_validity=%.2f, efficiency=%.2f). \
       Suggested reward multiplier: %.2f. \
       This is an advisory; apply only when benchmark evidence is trusted."
      score.case_id cs
      score.task_pass score.tool_selection score.arg_validity score.efficiency
      reward_multiplier
  in
  let evidence_refs =
    match score.prompt_fingerprint with
    | Some fp -> [ "benchmark:" ^ score.case_id; "fingerprint:" ^ fp ]
    | None -> [ "benchmark:" ^ score.case_id ]
  in
  {
    source = Benchmark;
    agent_name;
    task_id;
    verdict;
    reward_multiplier;
    advisory_message;
    evidence_refs;
    confidence = clamp ~lo:0.0 ~hi:1.0 cs;
    timestamp = Time_compat.now ();
  }
