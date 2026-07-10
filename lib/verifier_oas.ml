(** Verifier_oas — OAS adapter for verification engine.

    Bridges Verifier_core types to Agent_sdk Hooks/Guardrails.
    Core verification types and parsing live in Verifier_core (no OAS dependency).

    @since Phase 4 (OAS Guardrails adapter)
    @since 2.233.0 (core extracted to verifier_core.ml) *)

open Printf

module Core = Verifier_core

(* ================================================================ *)
(* Verification Prompt                                              *)
(* ================================================================ *)

let build_prompt (req : Core.verification_request) : string =
  let context_truncated =
    String_util.utf8_safe ~max_bytes:303 ~suffix:"..." req.context_summary
    |> String_util.to_string
  in
  let result_truncated =
    String_util.utf8_safe ~max_bytes:503 ~suffix:"..." req.action_result
    |> String_util.to_string
  in
  let vars =
    [ "goal", req.goal
    ; "context", context_truncated
    ; "action_taken", req.action_description
    ; "result", result_truncated
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
      context_truncated
      req.action_description
      result_truncated
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
  (* RFC-0331: skip iff the tool declared itself Read_only; the action
     description text is never classified. *)
  if Effect_class.equal req.effect_class Effect_class.Read_only
  then Ok Core.Pass
  else (
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
    let base_path = Env_config_core.base_path () in
    match
      Keeper_turn_driver_wrappers.run_named_with_masc_tools
        ~runtime_id
        ~base_path
        ~goal:prompt
        ~masc_tools:[ Core.report_verdict_schema ]
        ~dispatch
        
        ~temperature:Runtime_provider_defaults.deterministic_temperature
        ~max_tokens:200
        ~approval:Approval_callbacks.auto_approve
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
            Log.Verifier.warn
              "Verdict parse failed (%s)"
              parse_err;
            Error (sprintf "verdict parse: %s" parse_err)))
    | Error err -> Error (Agent_sdk.Error.to_string err))
;;

(* ================================================================ *)
(* Verdict -> Hook Decision (OAS bridge)                            *)
(* ================================================================ *)

(** Map a verdict to an OAS hook decision.

    - Pass -> Continue (action proceeds normally)
    - Warn -> Continue (action proceeds; warning is logged, not blocking)
    - Fail -> Skip (action is blocked)

    Warn reasons are logged to stderr for observability but do not halt
    execution, matching existing behavior where warnings are
    informational. *)
let verdict_to_hook_decision (v : Core.verdict) : Agent_sdk.Hooks.hook_decision =
  match v with
  | Core.Pass -> Agent_sdk.Hooks.Continue
  | Core.Warn reason ->
    Log.Verifier.warn "%s" reason;
    Agent_sdk.Hooks.Continue
  | Core.Fail reason ->
    Log.Verifier.error "FAIL (skipping tool): %s" reason;
    Agent_sdk.Hooks.Skip
;;

let continue_with_degraded_verifier ~tool_name ~reason =
  Log.Verifier.error
    "verification degraded for %s; allowing tool to continue: %s"
    tool_name
    reason;
  Agent_sdk.Hooks.Continue
;;

let handle_pre_tool_use
      ?(verify_fn = verify)
      ~(goal : string)
      ~(context_summary : string)
      ~(tool_name : string)
      ~(input : Yojson.Safe.t)
      ()
  : Agent_sdk.Hooks.hook_decision
  =
  let action_description = sprintf "tool:%s" tool_name in
  (* RFC-0331: gate on the tool's declared effect class (fail-closed:
     unknown/undeclared tools resolve to Mutating and are verified). *)
  let effect_class =
    Keeper_tool_descriptor_resolution.effect_class_for_tool_name tool_name
  in
  if Effect_class.equal effect_class Effect_class.Read_only
  then Agent_sdk.Hooks.Continue
  else (
    match
      try Ok (Yojson.Safe.to_string input) with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Printexc.to_string exn)
    with
    | Error msg ->
      continue_with_degraded_verifier
        ~tool_name
        ~reason:(Printf.sprintf "input serialization failed: %s" msg)
    | Ok input_str ->
      let req : Core.verification_request =
        { action_description; action_result = input_str; goal; context_summary; effect_class }
      in
      (match verify_fn req with
       | Ok verdict -> verdict_to_hook_decision verdict
       | Error msg ->
         continue_with_degraded_verifier
           ~tool_name
           ~reason:(Printf.sprintf "verifier backend error: %s" msg)))
;;

(* ================================================================ *)
(* PreToolUse Hook                                                   *)
(* ================================================================ *)

(** Create an OAS PreToolUse hook that wraps the verify logic.

    On PreToolUse events, builds a {!Verifier_core.verification_request} from
    the tool name and input JSON, calls {!verify} with the given
    model, and maps the verdict to a hook decision.

    For non-PreToolUse events, returns Continue (pass-through).

    @param goal The current agent goal (for verification prompt context).
    @param context_summary Brief summary of agent state. *)
let make_pre_tool_hook ?(verify_fn = verify) ~(goal : string) ~(context_summary : string)
  : Agent_sdk.Hooks.hook
  =
  fun event ->
  match event with
  | Agent_sdk.Hooks.PreToolUse { tool_name; input; _ } ->
    handle_pre_tool_use ~verify_fn ~goal ~context_summary ~tool_name ~input ()
  | Agent_sdk.Hooks.BeforeTurn _
  | Agent_sdk.Hooks.BeforeTurnParams _
  | Agent_sdk.Hooks.AfterTurn _
  | Agent_sdk.Hooks.PostToolUse _
  | Agent_sdk.Hooks.PostToolUseFailure _
  | Agent_sdk.Hooks.OnStop _
  | Agent_sdk.Hooks.OnIdle _
  | Agent_sdk.Hooks.OnIdleEscalated _
  | Agent_sdk.Hooks.OnError _
  | Agent_sdk.Hooks.OnToolError _
  | Agent_sdk.Hooks.PreCompact _
  | Agent_sdk.Hooks.PostCompact _
  | Agent_sdk.Hooks.OnContextCompacted _ -> Agent_sdk.Hooks.Continue
;;

(** Install the verifier hook into an existing OAS hooks record.

    Replaces the [pre_tool_use] slot. If a hook was already installed,
    it is replaced (not chained). The caller is responsible for composing
    hooks if needed.

    @param hooks The base hooks record (typically {!Agent_sdk.Hooks.empty}).
    @param model The verification model spec.
    @param goal The agent goal.
    @param context_summary The agent context summary.
    @return Updated hooks record with the verifier installed in pre_tool_use. *)
let install_hook
      ~(hooks : Agent_sdk.Hooks.hooks)
      ~(goal : string)
      ~(context_summary : string)
  : Agent_sdk.Hooks.hooks
  =
  { hooks with pre_tool_use = Some (make_pre_tool_hook ~goal ~context_summary) }
;;

(* ================================================================ *)
(* Read-Only Detection as OAS Guardrails.Custom                      *)
(* ================================================================ *)

(** Create an OAS Guardrails config that uses read-only detection
    as a Custom tool filter.

    Tools whose declared {!Effect_class.t} is [Read_only] pass through.
    Tools that are not are also allowed -- the filter itself does not block
    anything. Its purpose is to tag tools for downstream hooks that may skip
    verification for read-only operations.

    For actual filtering (blocking non-read-only tools), combine with a
    DenyList or use {!make_pre_tool_hook} which applies skip logic
    internally.

    This function wraps the read-only signal as a Guardrails.Custom
    predicate. Since all tools should remain visible to the MODEL, it
    always returns [true]. The predicate is provided for integration
    with custom pipelines that want to inspect read-only status. *)
let guardrails_with_read_only_tag ?(max_tool_calls_per_turn : int option) ()
  : Agent_sdk.Guardrails.t
  =
  { tool_filter = Agent_sdk.Guardrails.AllowAll; max_tool_calls_per_turn }
;;

(** Create an OAS Guardrails.Custom filter that identifies read-only tools.

    Returns a predicate [tool_schema -> bool] that returns true when the
    tool name matches read-only patterns. Can be used in custom
    guardrails pipelines for conditional verification bypass. *)
let read_only_predicate (schema : Agent_sdk.Types.tool_schema) : bool =
  (* RFC-0331: read-only iff the tool declares itself so at registration,
     not by matching read-ish words in its name. *)
  Effect_class.equal
    (Keeper_tool_descriptor_resolution.effect_class_for_tool_name schema.name)
    Effect_class.Read_only
;;

(* ================================================================ *)
(* Eval_gate -> OAS Guardrails bridge                               *)
(* ================================================================ *)

(** Convert Eval_gate.gate_config to OAS Guardrails.t.

    Maps the static tool-filtering portion of the gate config:
    - [allowlist_enabled] + [allowed_tools] -> AllowList
    - [denied_tools] only -> DenyList
    - Both enabled -> AllowList (stricter; deny is redundant)
    - Neither -> AllowAll

    Dynamic runtime checks (cost telemetry, entropy, destructive patterns)
    remain in Eval_gate. OAS Guardrails handles static pre-filtering;
    Eval_gate handles stateful per-call checks. Together they form
    defense-in-depth.

    @since Phase 6 — OAS Guardrails bridge *)
let eval_gate_to_oas_guardrails (gate : Eval_gate.gate_config) : Agent_sdk.Guardrails.t =
  let tool_filter =
    match gate.allowlist_enabled, gate.allowed_tools, gate.denied_tools with
    | true, (_ :: _ as allowed), _ ->
      (* AllowList is the stricter filter; deny is handled at runtime *)
      Agent_sdk.Guardrails.AllowList allowed
    | true, [], _ ->
      (* Allowlist enabled but empty = deny all tools *)
      Agent_sdk.Guardrails.AllowList []
    | false, _, (_ :: _ as denied) -> Agent_sdk.Guardrails.DenyList denied
    | false, _, [] -> Agent_sdk.Guardrails.AllowAll
  in
  { Agent_sdk.Guardrails.tool_filter
  ; max_tool_calls_per_turn = Some gate.max_tool_calls_per_turn
  }
;;
