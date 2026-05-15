(** Reward_advice_artifact — Structured advisory artifacts from verifiers and benchmarks.

    Bridges verification verdicts and benchmark scores to the reward system
    with evidence-backed advisory hints.  The advisory pattern means callers
    decide whether to apply the recommended [reward_multiplier]; the artifact
    itself is a proposal, not a command.

    @since Task-044 — Advisory Reward Advice Artifacts *)

(** {1 Types} *)

(** Source module that produced this artifact. *)
type advice_source =
  | Post_verifier   (** Heuristic 3-dimension content check. *)
  | Benchmark       (** Tool-call quality benchmark scoring. *)
  | Task_verifier   (** OAS/LLM task action verifier. *)

(** Typed verdict classification.  Downstream consumers receive only valid
    verdicts; [of_yojson] rejects unknown strings instead of mapping them
    to a silent neutral default. *)
type verdict =
  | Pass
  | Warn
  | Fail

(** A structured advisory hint from a verifier or benchmark to the reward system. *)
type reward_advice_artifact = {
  source : advice_source;
  agent_name : string;
  task_id : string option;
  verdict : verdict;
  reward_multiplier : float;   (** Suggested multiplier [0.0, 2.0]; 1.0 = neutral. *)
  advisory_message : string;
  evidence_refs : string list;
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

(** {1 Verdict helpers} *)

let verdict_to_string = function
  | Pass -> "pass"
  | Warn -> "warn"
  | Fail -> "fail"

let verdict_of_string = function
  | "pass" -> Some Pass
  | "warn" -> Some Warn
  | "fail" -> Some Fail
  | _ -> None

(** Derive a suggested reward multiplier from a typed verdict.
    Pattern-match is exhaustive — no wildcard fallback. *)
let multiplier_of_verdict = function
  | Pass -> 1.0
  | Warn -> 0.8
  | Fail -> 0.4

(** {1 Serialization} *)

let clamp ~lo ~hi v = Float.max lo (Float.min hi v)

let to_yojson (a : reward_advice_artifact) : Yojson.Safe.t =
  `Assoc [
    ("source", `String (advice_source_to_string a.source));
    ("agent_name", `String a.agent_name);
    ("task_id", Option.fold ~none:`Null ~some:(fun s -> `String s) a.task_id);
    ("verdict", `String (verdict_to_string a.verdict));
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
      let verdict_str = string_field ~default:"" "verdict" json in
      match verdict_of_string verdict_str with
      | None ->
        Error (Printf.sprintf
          "reward_advice_artifact: unknown verdict %S (expected pass/warn/fail)"
          verdict_str)
      | Some verdict ->
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
          verdict;
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

    - Pass → multiplier 1.0, confidence 1.0
    - Warn → multiplier 0.8, confidence 0.9
    - Fail → multiplier 0.4, confidence 1.0 *)
let of_post_verifier_verdict ~agent_name ?task_id ~verdict ~advisory_message () =
  let confidence = match verdict with Warn -> 0.9 | _ -> 1.0 in
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
    - score >= 0.8 → Pass (multiplier 1.1 bonus)
    - score >= 0.5 → Warn (multiplier 0.9)
    - score <  0.5 → Fail (multiplier 0.5) *)
let of_benchmark_case_score ~agent_name ?task_id
    (score : Tool_call_quality_benchmark_types.case_score) : reward_advice_artifact =
  let cs = score.composite_score in
  let verdict, reward_multiplier =
    if cs >= 0.8 then (Pass, 1.1)
    else if cs >= 0.5 then (Warn, 0.9)
    else (Fail, 0.5)
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
