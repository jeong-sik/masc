(** Verifier_oas — OAS adapter for verification engine.

    Bridges Verifier_core types to the OAS agent runtime. Core verification
    types and parsing live in Verifier_core (no OAS dependency).

    @since Phase 4 (OAS adapter)
    @since 2.233.0 (core extracted to verifier_core.ml) *)

open Printf

module Core = Verifier_core

(* ================================================================ *)
(* Verification Prompt                                              *)
(* ================================================================ *)

let build_prompt (req : Core.verification_request) : string =
  let vars =
    [ "goal", req.goal
    ; "context", req.context_summary
    ; "action_taken", req.action_description
    ; "result", req.action_result
    ]
  in
  match Prompt_registry.render_prompt_template "verification.action_verifier" vars with
  | Ok p -> p
  | Error msg ->
    Log.Verifier.warn "verification action prompt render failed, using fallback: %s" msg;
    sprintf
      {|You are a verification agent. Evaluate whether this action was correct.

Goal: %s

Context: %s

Action taken: %s

Result: %s

Call report_verdict exactly once:
- verdict: PASS if the action is correct and moves toward the goal.
- verdict: WARN if the action is acceptable but has concerns.
- verdict: FAIL if the action is wrong or harmful.
- reason: null for PASS, otherwise a concise explanation.
- evidence: an empty array unless you have concrete evidence references.

If you cannot call the tool, return only the same JSON object with fields
`verdict`, `reason`, and `evidence`.|}
      req.goal
      req.context_summary
      req.action_description
      req.action_result
;;

let apply_report_verdict_output_schema provider_cfg =
  let schema = Keeper_structured_output_schema.verification_verdict_output_schema in
  Ok
    (Keeper_structured_output_schema.apply_schema_or_prompt_tier
       ~log_label:"verifier output contract"
       schema
       provider_cfg)
;;

let parse_verdict_from_response_text text =
  match Yojson.Safe.from_string (String.trim text) with
  | json -> Core.parse_verdict_from_json json
  | exception Yojson.Json_error msg ->
      Error (sprintf "verifier response must be strict JSON: %s" msg)
;;

let parse_verdict_from_response response =
  match
    Agent_sdk_response.structured_json_of_response
      ~schema_name:"verification_report_verdict"
      response
  with
  | Ok json -> Core.parse_verdict_from_json json
  | Error msg ->
    Error (sprintf "verifier response must be structured JSON: %s" msg)
;;

module For_testing = struct
  let parse_verdict_from_response_text = parse_verdict_from_response_text
end

(* ================================================================ *)
(* Core: verify                                                     *)
(* ================================================================ *)

(** Verify an action using structured tool output (ADR D3 compliant).

    Primary path: LLM calls [report_verdict] tool with typed verdict.
    Fallback path: if LLM responds with text, parse provider-native JSON only.

    The structured path is deterministic (JSON schema constrains output).
    The fallback path is strict JSON and returns Error on failure instead of
    extracting a verdict from prose. *)
let verify (req : Core.verification_request) : (Core.verdict, string) result =
  let prompt = build_prompt req in
  let verdict_ref = ref None in
  let dispatch ~name ~args =
    let start_time = Time_compat.now () in
    match Core.parse_verdict_from_json args with
    | Ok v ->
      verdict_ref := Some v;
      Tool_result.error
        ~tool_name:name
        ~start_time
        (sprintf "Verdict recorded: %s" (Core.verdict_to_string v))
    | Error msg ->
      Log.Verifier.warn "Structured verdict parse failed: %s" msg;
      Tool_result.error
        ~tool_name:name
        ~start_time
        (sprintf "Invalid verdict format: %s" msg)
  in
  let runtime_id = Runtime.runtime_id_for_structured_judge () in
  match
    Keeper_turn_driver_wrappers.run_named_with_masc_tools
      ~runtime_id
      ~goal:prompt
      ~masc_tools:[ Core.report_verdict_schema ]
      ~dispatch
      ~temperature:Runtime_provider_defaults.deterministic_temperature
      ~provider_config_transform:apply_report_verdict_output_schema
      ()
  with
  | Ok result ->
    (match !verdict_ref with
     | Some v ->
       Log.Verifier.debug "verdict via structured tool call";
       Ok v
     | None ->
       (* LLM responded with text instead of tool call. The provider-native
          schema contract still requires a strict JSON verdict object here. *)
       Log.Verifier.info
         "verdict via strict JSON response fallback (model did not call report_verdict)";
       (match parse_verdict_from_response result.response with
        | Ok verdict -> Ok verdict
        | Error parse_err ->
          Log.Verifier.warn "Verdict parse failed (%s)" parse_err;
          Error (sprintf "verdict parse: %s" parse_err)))
  | Error err -> Error (Agent_sdk.Error.to_string err)
;;
