(** Test harness framework for agent verification.

    Provides pluggable verification layers inspired by:
    - Claude Agent SDK Workshop: "rule-based verification"
    - Agent Harness Principles: "Harness > Model", "Swiss Cheese Model"

    Each harness type implements the HARNESS module type with specific
    input/expectation/observation types. Harnesses compose via the
    Swiss Cheese combinator for multi-layer independent verification. *)

open Types

(* ── Common types ────────────────────────────────────────────── *)

(** Verdict from a harness evaluation. *)
type verdict =
  { passed : bool
  ; score : float option (** 0.0-1.0, for graded harnesses *)
  ; evidence : string list (** Machine-readable evidence strings *)
  ; detail : string option (** Human-readable explanation *)
  }

(** A single layer in a Swiss Cheese stack. *)
type 'obs layer =
  { name : string
  ; check : 'obs -> bool
  ; evidence : 'obs -> string
  }

(** Result of evaluating all layers in a Swiss Cheese stack. *)
type 'obs layer_result =
  { layer_name : string
  ; layer_passed : bool
  ; layer_evidence : string
  }

type 'obs swiss_verdict =
  { all_passed : bool
  ; layer_results : 'obs layer_result list
  ; coverage : float (** fraction of layers that passed *)
  }

(* ── Behavioral harness ──────────────────────────────────────── *)

module Behavioral = struct
  (** What we expect from the agent. *)
  type expectation =
    | ToolSelected of string list (** These tools must be called *)
    | ContainsText of string (** Final response contains this text *)
    | All of expectation list (** All must pass *)

  (** What we observe from the agent run. *)
  type observation =
    { tools_called : string list
    ; turn_count : int
    ; final_response : string
    ; messages : message list
    }

  (** Extract observation from an agent after a run. *)
  let observe (agent : Agent.t) (result : (api_response, Error.sdk_error) result)
    : observation
    =
    let final_response =
      match result with
      | Ok resp ->
        List.filter_map
          (function
            | Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat "\n"
      | Error _ -> ""
    in
    let tools_called =
      List.concat_map
        (fun (msg : message) ->
           List.filter_map
             (function
               | ToolUse { name; _ } -> Some name
               | _ -> None)
             msg.content)
        (Agent.state agent).messages
    in
    { tools_called
    ; turn_count = (Agent.state agent).turn_count
    ; final_response
    ; messages = (Agent.state agent).messages
    }
  ;;

  (** Evaluate an observation against an expectation. *)
  let rec evaluate obs exp : verdict =
    match exp with
    | ToolSelected expected_tools ->
      let all_found =
        List.for_all (fun t -> List.mem t obs.tools_called) expected_tools
      in
      { passed = all_found
      ; score = None
      ; evidence =
          [ Printf.sprintf "expected_tools=%s" (String.concat "," expected_tools)
          ; Printf.sprintf "actual_tools=%s" (String.concat "," obs.tools_called)
          ]
      ; detail =
          (if all_found
           then None
           else
             Some
               (Printf.sprintf
                  "Missing tools: %s"
                  (String.concat
                     ", "
                     (List.filter
                        (fun t -> not (List.mem t obs.tools_called))
                        expected_tools))))
      }
    | ContainsText needle ->
      let found =
        try
          let _ = Str.search_forward (Str.regexp_string needle) obs.final_response 0 in
          true
        with
        | Not_found -> false
      in
      { passed = found
      ; score = None
      ; evidence =
          [ Printf.sprintf "needle=%s" needle
          ; Printf.sprintf "response_len=%d" (String.length obs.final_response)
          ]
      ; detail =
          (if found
           then None
           else Some (Printf.sprintf "Text '%s' not found in response" needle))
      }
    | All expectations ->
      let verdicts = List.map (evaluate obs) expectations in
      let all_passed = List.for_all (fun (v : verdict) -> v.passed) verdicts in
      let scores = List.filter_map (fun (v : verdict) -> v.score) verdicts in
      let avg_score =
        match scores with
        | [] -> None
        | ss -> Some (List.fold_left ( +. ) 0.0 ss /. Float.of_int (List.length ss))
      in
      { passed = all_passed
      ; score = avg_score
      ; evidence = List.concat_map (fun (v : verdict) -> v.evidence) verdicts
      ; detail =
          (if all_passed
           then None
           else (
             let failures = List.filter (fun (v : verdict) -> not v.passed) verdicts in
             Some
               (Printf.sprintf
                  "%d/%d checks failed"
                  (List.length failures)
                  (List.length verdicts))))
      }
  ;;
end

(* ── Adversarial harness ─────────────────────────────────────── *)

module Adversarial = struct
  (** Types of adversarial input. *)
  type adversarial_input =
    | MalformedJson of string
    | PromptInjection of string
    | ToolError of
        { tool_name : string
        ; error : string
        }
    | OversizedInput of { size : int }

  (** What we expect under adversarial conditions. *)
  type expectation =
    | GracefulError
    | NoToolExecution
    | ErrorContains of string

  type observation =
    { result : (api_response, Error.sdk_error) result
    ; tools_executed : string list
    ; error_message : string option
    }

  let evaluate obs exp : verdict =
    match exp with
    | GracefulError ->
      let passed =
        match obs.result with
        | Error _ -> true
        | Ok _ -> false
      in
      { passed
      ; score = None
      ; evidence = [ Printf.sprintf "got_error=%b" (Result.is_error obs.result) ]
      ; detail = (if passed then None else Some "Expected error but got success")
      }
    | NoToolExecution ->
      let passed = obs.tools_executed = [] in
      { passed
      ; score = None
      ; evidence =
          [ Printf.sprintf "tools_executed=%s" (String.concat "," obs.tools_executed) ]
      ; detail =
          (if passed
           then None
           else
             Some
               (Printf.sprintf
                  "Tools were executed: %s"
                  (String.concat ", " obs.tools_executed)))
      }
    | ErrorContains needle ->
      let passed =
        match obs.error_message with
        | Some msg -> Util.regex_match (Str.regexp_string needle) msg
        | None -> false
      in
      { passed
      ; score = None
      ; evidence =
          [ Printf.sprintf "needle=%s" needle
          ; Printf.sprintf "error=%s" (Option.value ~default:"<none>" obs.error_message)
          ]
      ; detail =
          (if passed
           then None
           else Some (Printf.sprintf "Error message does not contain '%s'" needle))
      }
  ;;
end

(* ── Performance harness ─────────────────────────────────────── *)

module Performance = struct
  type observation =
    { latencies_ms : float list
    ; total_tokens : int
    ; total_cost_usd : float
    ; turn_count : int
    }

  type expectation = { max_p95_latency_ms : float option }

  let default_expectation = { max_p95_latency_ms = None }

  (** Calculate p95 from a sorted list of latencies. *)
  let p95 latencies =
    let sorted = List.sort Float.compare latencies in
    let n = List.length sorted in
    if n = 0
    then 0.0
    else (
      let idx = Float.to_int (Float.of_int (n - 1) *. 0.95) in
      List.nth sorted idx)
  ;;

  let evaluate obs exp : verdict =
    let checks =
      [ (match exp.max_p95_latency_ms with
         | Some limit ->
           let actual = p95 obs.latencies_ms in
           Some (actual <= limit, Printf.sprintf "p95_ms=%.1f limit=%.1f" actual limit)
         | None -> None)
      ]
    in
    let active = List.filter_map Fun.id checks in
    let all_passed = List.for_all fst active in
    { passed = all_passed
    ; score = None
    ; evidence = List.map snd active
    ; detail =
        (if all_passed
         then None
         else (
           let failures = List.filter (fun (p, _) -> not p) active in
           Some (String.concat "; " (List.map snd failures))))
    }
  ;;
end

(* ── Regression harness (golden file) ────────────────────────── *)

module Regression = struct
  type match_mode =
    | ExactMatch
    | StructuralMatch of (Yojson.Safe.t -> Yojson.Safe.t -> bool)
    | FuzzyMatch of { threshold : float }

  type observation =
    { output_json : Yojson.Safe.t
    ; output_text : string
    }

  (** Compare observation against a golden value. *)
  let evaluate ~mode obs golden : verdict =
    let passed, detail =
      match mode with
      | ExactMatch -> obs.output_text = golden, None
      | StructuralMatch cmp ->
        (match
           try Ok (Yojson.Safe.from_string golden) with
           | Yojson.Json_error msg -> Error msg
         with
         | Ok golden_json -> cmp obs.output_json golden_json, None
         | Error msg -> false, Some (Printf.sprintf "Invalid golden JSON: %s" msg))
      | FuzzyMatch { threshold } ->
        (* Simple character-level similarity.
           RFC-OAS-015 PR-B: replaced the imperative `for` loop with an
           external `ref common` counter by a tail-recursive accumulator.
           Same arithmetic, identical traversal order. *)
        let len1 = String.length obs.output_text in
        let len2 = String.length golden in
        let max_len = max len1 len2 in
        let passed =
          if max_len = 0
          then true
          else (
            let min_len = min len1 len2 in
            let rec count_matches i acc =
              if i >= min_len
              then acc
              else if obs.output_text.[i] = golden.[i]
              then count_matches (i + 1) (acc + 1)
              else count_matches (i + 1) acc
            in
            let common = count_matches 0 0 in
            Float.of_int common /. Float.of_int max_len >= threshold)
        in
        passed, None
    in
    { passed
    ; score = None
    ; evidence =
        [ Printf.sprintf "output_len=%d" (String.length obs.output_text)
        ; Printf.sprintf "golden_len=%d" (String.length golden)
        ]
    ; detail =
        (if passed
         then None
         else (
           match detail with
           | Some _ -> detail
           | None -> Some "Output does not match golden file"))
    }
  ;;
end

(* ── Swiss Cheese combinator ─────────────────────────────────── *)

module Swiss_cheese = struct
  (** Run all layers and produce a combined verdict. *)
  let evaluate_layers layers obs : 'obs swiss_verdict =
    let results =
      List.map
        (fun (layer : 'obs layer) ->
           { layer_name = layer.name
           ; layer_passed = layer.check obs
           ; layer_evidence = layer.evidence obs
           })
        layers
    in
    let passed_count = List.length (List.filter (fun r -> r.layer_passed) results) in
    let total = List.length results in
    { all_passed = passed_count = total
    ; layer_results = results
    ; coverage =
        (if total = 0 then 1.0 else Float.of_int passed_count /. Float.of_int total)
    }
  ;;

  (** Require all layers to pass. *)
  let require_all layers obs : verdict =
    let sv = evaluate_layers layers obs in
    { passed = sv.all_passed
    ; score = Some sv.coverage
    ; evidence =
        List.map
          (fun r ->
             Printf.sprintf
               "%s:%s"
               r.layer_name
               (if r.layer_passed then "PASS" else "FAIL"))
          sv.layer_results
    ; detail =
        (if sv.all_passed
         then None
         else (
           let failures = List.filter (fun r -> not r.layer_passed) sv.layer_results in
           Some
             (Printf.sprintf
                "%d layer(s) failed: %s"
                (List.length failures)
                (String.concat
                   ", "
                   (List.map
                      (fun r -> Printf.sprintf "%s(%s)" r.layer_name r.layer_evidence)
                      failures)))))
    }
  ;;

  (** Require at least [n] layers to pass. *)
  let require_n n layers obs : verdict =
    let sv = evaluate_layers layers obs in
    let passed_count =
      List.length (List.filter (fun r -> r.layer_passed) sv.layer_results)
    in
    let passed = passed_count >= n in
    { passed
    ; score = Some sv.coverage
    ; evidence =
        List.map
          (fun r ->
             Printf.sprintf
               "%s:%s"
               r.layer_name
               (if r.layer_passed then "PASS" else "FAIL"))
          sv.layer_results
    ; detail =
        (if passed
         then None
         else
           Some
             (Printf.sprintf
                "Only %d/%d layers passed (need %d)"
                passed_count
                (List.length sv.layer_results)
                n))
    }
  ;;
end

(* ── Composability harness ───────────────────────────────────── *)

module Composability = struct
  type scenario =
    | SingleAgent
    | Handoff of
        { parent : string
        ; targets : string list
        }
    | Orchestrated of { agents : string list }
    | Pipeline of { stages : string list }

  type expectation =
    | HandoffOccurred of string
    | AllAgentsCompleted
    | ContextPropagated of string

  type observation =
    { agents_involved : string list
    ; handoffs_observed : (string * string) list (** (from, to) *)
    ; all_completed : bool
    ; context_keys : string list
    ; total_turns : int
    }

  let evaluate obs exp : verdict =
    match exp with
    | HandoffOccurred target ->
      let found = List.exists (fun (_, t) -> t = target) obs.handoffs_observed in
      { passed = found
      ; score = None
      ; evidence =
          [ Printf.sprintf "target=%s" target
          ; Printf.sprintf
              "handoffs=%s"
              (String.concat
                 ","
                 (List.map (fun (f, t) -> f ^ "->" ^ t) obs.handoffs_observed))
          ]
      ; detail =
          (if found
           then None
           else Some (Printf.sprintf "No handoff to '%s' observed" target))
      }
    | AllAgentsCompleted ->
      { passed = obs.all_completed
      ; score = None
      ; evidence =
          [ Printf.sprintf "agents=%s" (String.concat "," obs.agents_involved)
          ; Printf.sprintf "all_completed=%b" obs.all_completed
          ]
      ; detail = (if obs.all_completed then None else Some "Not all agents completed")
      }
    | ContextPropagated key ->
      let found = List.mem key obs.context_keys in
      { passed = found
      ; score = None
      ; evidence =
          [ Printf.sprintf "key=%s" key
          ; Printf.sprintf "context_keys=%s" (String.concat "," obs.context_keys)
          ]
      ; detail =
          (if found
           then None
           else Some (Printf.sprintf "Context key '%s' not propagated" key))
      }
  ;;
end

(* ── Model grader ──────────────────────────────────────────── *)

module Model_grader = struct
  (** Configuration for LLM-based evaluation. *)
  type config =
    { prompt_template : string (** Must contain {goal} and {result} placeholders *)
    ; rubric : string (** Evaluation criteria *)
    ; weight : float (** 0.0-1.0 weight for this grader *)
    }

  (** Grade a result using an LLM.
      [complete_fn] is a dependency-injected completion function.
      Returns a verdict with score extracted from the LLM response.

      The prompt is constructed by replacing \{goal\} and \{result\}
      in the template, appending the rubric. The LLM response is
      parsed for a numeric score (first float found). *)
  let grade ~complete_fn (config : config) ~goal ~result : verdict =
    let prompt =
      config.prompt_template
      |> Str.global_replace (Str.regexp_string "{goal}") goal
      |> Str.global_replace (Str.regexp_string "{result}") result
    in
    let full_prompt =
      Printf.sprintf
        "%s\n\n\
         Rubric:\n\
         %s\n\n\
         Respond with a score from 0.0 to 1.0 on the first line, then explanation."
        prompt
        config.rubric
    in
    match complete_fn full_prompt with
    | Error msg ->
      { passed = false
      ; score = None
      ; evidence = [ Printf.sprintf "grader_error=%s" msg ]
      ; detail = Some (Printf.sprintf "Model grader failed: %s" msg)
      }
    | Ok response ->
      (* Extract first float from response *)
      let score =
        try
          let _ = Str.search_forward (Str.regexp {|[0-9]+\.[0-9]+|}) response 0 in
          Some (float_of_string (Str.matched_string response))
        with
        | Not_found | Failure _ -> None
      in
      let score = Option.map (fun s -> Float.min 1.0 (Float.max 0.0 s)) score in
      let passed =
        match score with
        | Some s -> s >= 0.5 *. config.weight
        | None -> false
      in
      { passed
      ; score
      ; evidence =
          [ Printf.sprintf "weight=%.2f" config.weight
          ; Printf.sprintf "response_len=%d" (String.length response)
          ]
      ; detail =
          (match score with
           | Some s -> Some (Printf.sprintf "Score: %.2f (weight: %.2f)" s config.weight)
           | None -> Some "Could not extract score from model response")
      }
  ;;
end

(* ── JSON serialization (Swiss Verdict Schema v1) ──────────── *)

let verdict_to_json (v : verdict) : Yojson.Safe.t =
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
    ]
;;

let swiss_verdict_to_json (sv : _ swiss_verdict) : Yojson.Safe.t =
  let layer_result_to_json (lr : _ layer_result) : Yojson.Safe.t =
    `Assoc
      [ "layer_name", `String lr.layer_name
      ; "passed", `Bool lr.layer_passed
      ; "score", `Null
      ; "evidence", `List [ `String lr.layer_evidence ]
      ; "detail", `Null
      ]
  in
  `Assoc
    [ "schema_version", `Int 1
    ; "all_passed", `Bool sv.all_passed
    ; "coverage", `Float sv.coverage
    ; "layer_results", `List (List.map layer_result_to_json sv.layer_results)
    ]
;;
