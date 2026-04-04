(** Verifier_oas — Action verification engine with OAS Guardrails/Hooks bridge.

    Cheap-model action verification for feedback loops.
    Each action is sent to a cheap model with a [report_verdict] tool.
    The model calls the tool with a typed verdict (PASS/WARN/FAIL + reason).
    If the model responds with text instead of a tool call, a lenient
    text parser serves as fallback (Samchon Rank 1: lenient parsing).

    Budget: max 200 output tokens per verification (~0.01 cents).
    Skip: read-only actions (file reads, glob, grep, searches).

    OAS integration:
    - [verdict_to_hook_decision]: Pass/Warn/Fail -> OAS Continue/Continue/Skip
    - [make_pre_tool_hook]: wraps verify as an OAS PreToolUse hook
    - [guardrails_with_read_only_tag]: wraps should_skip as OAS Custom filter

    ADR D3: verdict extraction uses structured tool output (deterministic)
    instead of regex/prefix matching on free text (nondeterministic).

    @since 2.61.0 (verifier core)
    @since Phase 4 (OAS Guardrails adapter)
    @since 2.223.0 (structured verdict via report_verdict tool) *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type verification_request = {
  action_description : string;
  action_result : string;
  goal : string;
  context_summary : string;
}

type verdict =
  | Pass
  | Warn of string
  | Fail of string

(* ================================================================ *)
(* Read-Only Detection                                              *)
(* ================================================================ *)

(** Actions that are safe and need no verification. *)
let read_only_patterns = [
  "read"; "glob"; "grep";
  "search"; "find"; "list"; "ls"; "cat"; "head"; "tail";
  "git status"; "git log"; "git diff";
  "status"; "view"; "get"; "fetch"; "query";
]

let is_word_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let has_pattern_with_word_boundary ~text ~pat =
  let tlen = String.length text in
  let plen = String.length pat in
  if plen = 0 || tlen < plen then false
  else
    let rec loop i =
      if i > tlen - plen then false
      else if String.sub text i plen = pat then
        let before_ok = i = 0 || not (is_word_char text.[i - 1]) in
        let after_idx = i + plen in
        let after_ok = after_idx >= tlen || not (is_word_char text.[after_idx]) in
        if before_ok && after_ok then true else loop (i + 1)
      else
        loop (i + 1)
    in
    loop 0

let should_skip ~action_description =
  let text = String.lowercase_ascii action_description in
  List.exists (fun pat ->
    has_pattern_with_word_boundary ~text ~pat
  ) read_only_patterns

(* ================================================================ *)
(* Verdict Parsing                                                  *)
(* ================================================================ *)

let verdict_to_string = function
  | Pass -> "PASS"
  | Warn reason -> sprintf "WARN: %s" reason
  | Fail reason -> sprintf "FAIL: %s" reason

(** Check if keyword at position 0..len is followed by a word boundary.
    A boundary is defined as end of string or a following non-word character.
    Prevents "PASSING" matching as PASS while allowing "PASS." / "PASS\t...". *)
let has_keyword_boundary upper len =
  let tlen = String.length upper in
  len >= tlen || not (is_word_char upper.[len])

(** Extract reason text after keyword+separator, stripping leading colon/dash. *)
let extract_reason trimmed keyword_len default_reason =
  let reason =
    if String.length trimmed > keyword_len + 1 then
      String.trim (String.sub trimmed (keyword_len + 1) (String.length trimmed - keyword_len - 1))
    else default_reason
  in
  if String.length reason > 0 && (reason.[0] = ':' || reason.[0] = '-') then
    String.trim (String.sub reason 1 (String.length reason - 1))
  else reason

(** Parse "PASS", "WARN: reason", "FAIL: reason" from model output.
    Returns Error on unrecognized format instead of silent degrade (ADR D3).
    Requires word boundary after keyword to prevent "PASSING"/"WARNING" false matches. *)
let parse_verdict (text : string) : (verdict, string) result =
  let trimmed = String.trim text in
  let upper = String.uppercase_ascii trimmed in
  let len = String.length upper in
  if len >= 4 && String.sub upper 0 4 = "PASS" && has_keyword_boundary upper 4 then
    Ok Pass
  else if len >= 4 && String.sub upper 0 4 = "WARN" && has_keyword_boundary upper 4 then
    Ok (Warn (extract_reason trimmed 4 "unspecified concern"))
  else if len >= 4 && String.sub upper 0 4 = "FAIL" && has_keyword_boundary upper 4 then
    Ok (Fail (extract_reason trimmed 4 "action did not achieve goal"))
  else if len = 0 then
    Error "empty verifier output"
  else
    Error (sprintf "unrecognized verdict format: %s"
      (if len > 80 then String.sub trimmed 0 80 ^ "..." else trimmed))

(* ================================================================ *)
(* Structured Verdict: Tool Schema + JSON Parsing (ADR D3)          *)
(* ================================================================ *)

(** JSON schema for the report_verdict tool.
    Forces the LLM to call a tool with typed parameters instead of
    producing free-text output.

    Schema constrains verdict to exactly PASS/WARN/FAIL via enum,
    making invalid values structurally impossible (Samchon: "constraint
    through absence"). *)
let report_verdict_schema : Types.tool_schema =
  { name = "report_verdict";
    description =
      "Report your verification verdict. You MUST call this tool \
       with your assessment. verdict must be exactly PASS, WARN, or FAIL.";
    input_schema = `Assoc [
      "type", `String "object";
      "properties", `Assoc [
        "verdict", `Assoc [
          "type", `String "string";
          "enum", `List [`String "PASS"; `String "WARN"; `String "FAIL"];
          "description", `String "PASS if correct, WARN if acceptable with concerns, FAIL if wrong or harmful";
        ];
        "reason", `Assoc [
          "type", `String "string";
          "description", `String "Brief explanation for the verdict (required for WARN and FAIL)";
        ];
      ];
      "required", `List [`String "verdict"];
    ];
  }

(** Parse verdict from tool call JSON arguments (deterministic path).
    The JSON is produced by the LLM calling report_verdict, so the
    "verdict" field is constrained by the schema enum.

    Handles Samchon absorption points:
    - Type coercion: accepts both quoted and unquoted values
    - Case insensitivity: "pass", "Pass", "PASS" all accepted
    - Missing reason: defaults to descriptive string *)
let parse_verdict_from_json (args : Yojson.Safe.t) : (verdict, string) result =
  let open Yojson.Safe.Util in
  try
    let verdict_str =
      args |> member "verdict" |> to_string |> String.uppercase_ascii
    in
    let reason =
      try args |> member "reason" |> to_string
      with Type_error _ -> ""
    in
    match verdict_str with
    | "PASS" -> Ok Pass
    | "WARN" ->
      let r = if reason = "" then "unspecified concern" else reason in
      Ok (Warn r)
    | "FAIL" ->
      let r = if reason = "" then "action did not achieve goal" else reason in
      Ok (Fail r)
    | other ->
      Error (sprintf "unexpected verdict value: %s" other)
  with
  | Type_error (msg, _) ->
    Error (sprintf "verdict JSON type error: %s" msg)
  | exn ->
    Error (sprintf "verdict JSON parse error: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* Verification Prompt                                              *)
(* ================================================================ *)

let build_prompt (req : verification_request) : string =
  sprintf
{|You are a verification agent. Evaluate whether this action was correct.

Goal: %s

Context: %s

Action taken: %s

Result: %s

Respond with exactly one of:
PASS - if the action is correct and moves toward the goal
WARN: <reason> - if the action is acceptable but has concerns
FAIL: <reason> - if the action is wrong or harmful

One line only.|}
    req.goal
    (if String.length req.context_summary > 300
     then String.sub req.context_summary 0 300 ^ "..."
     else req.context_summary)
    req.action_description
    (if String.length req.action_result > 500
     then String.sub req.action_result 0 500 ^ "..."
     else req.action_result)

(* ================================================================ *)
(* Core: verify                                                     *)
(* ================================================================ *)

(** Verify an action using structured tool output (ADR D3 compliant).

    Primary path: LLM calls [report_verdict] tool with typed verdict.
    Fallback path: if LLM responds with text, [parse_verdict] extracts
    the verdict from free text (Samchon Rank 1: lenient fallback).

    The structured path is deterministic (JSON schema constrains output).
    The fallback path is nondeterministic but returns Error on failure
    instead of silently degrading. *)
let verify (req : verification_request) : (verdict, string) result =
  if should_skip ~action_description:req.action_description then
    Ok Pass
  else
    let prompt = build_prompt req in
    let verdict_ref = ref None in
    let dispatch ~name:_ ~args =
      match parse_verdict_from_json args with
      | Ok v ->
        verdict_ref := Some v;
        (false, sprintf "Verdict recorded: %s" (verdict_to_string v))
      | Error msg ->
        Log.Verifier.warn "Structured verdict parse failed: %s" msg;
        (false, sprintf "Invalid verdict format: %s" msg)
    in
    match
      Oas_worker_named.run_named_with_masc_tools
        ~cascade_name:"verifier"
        ~goal:prompt
        ~masc_tools:[report_verdict_schema]
        ~dispatch
        ~max_turns:1
        ~temperature:0.0
        ~max_tokens:200
        ()
    with
    | Ok result ->
      (match !verdict_ref with
       | Some v ->
         Log.Verifier.debug "verdict via structured tool call";
         Ok v
       | None ->
         (* LLM responded with text instead of tool call — lenient fallback *)
         let text = Oas_response.text_of_response result.response in
         Log.Verifier.info "verdict via text fallback (model did not call report_verdict)";
         (match parse_verdict text with
          | Ok verdict -> Ok verdict
          | Error parse_err ->
            Log.Verifier.warn "Verdict parse failed (%s); raw=%s"
              parse_err (String.sub text 0 (min 80 (String.length text)));
            Error (sprintf "verdict parse: %s" parse_err)))
    | Error message ->
      Error message

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
let verdict_to_hook_decision (v : verdict) : Agent_sdk.Hooks.hook_decision =
  match v with
  | Pass -> Agent_sdk.Hooks.Continue
  | Warn reason ->
    Log.Verifier.warn "%s" reason;
    Agent_sdk.Hooks.Continue
  | Fail reason ->
    Log.Verifier.error "FAIL (skipping tool): %s" reason;
    Agent_sdk.Hooks.Skip

let handle_pre_tool_use
    ?(verify_fn = verify)
    ~(goal : string)
    ~(context_summary : string)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ()
  : Agent_sdk.Hooks.hook_decision =
  let action_description = sprintf "tool:%s" tool_name in
  if should_skip ~action_description then
    Agent_sdk.Hooks.Continue
  else
    (match
       try Ok (Yojson.Safe.to_string input)
       with Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Error (Printexc.to_string exn)
     with
     | Error msg ->
         Log.Verifier.error "Failed to serialize input for verifier: %s" msg;
         Agent_sdk.Hooks.Skip
     | Ok input_str ->
         let req : verification_request = {
           action_description;
           action_result = input_str;
           goal;
           context_summary;
         } in
         begin match verify_fn req with
         | Ok verdict -> verdict_to_hook_decision verdict
         | Error msg ->
             Log.Verifier.error "OAS run failed; skipping tool: %s" msg;
             Agent_sdk.Hooks.Skip
         end)

(* ================================================================ *)
(* PreToolUse Hook                                                   *)
(* ================================================================ *)

(** Create an OAS PreToolUse hook that wraps the verify logic.

    On PreToolUse events, builds a {!verification_request} from
    the tool name and input JSON, calls {!verify} with the given
    model, and maps the verdict to a hook decision.

    For non-PreToolUse events, returns Continue (pass-through).

    @param goal The current agent goal (for verification prompt context).
    @param context_summary Brief summary of agent state. *)
let make_pre_tool_hook
    ?(verify_fn = verify)
    ~(goal : string)
    ~(context_summary : string)
  : Agent_sdk.Hooks.hook =
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
    | Agent_sdk.Hooks.OnError _
    | Agent_sdk.Hooks.OnToolError _
    | Agent_sdk.Hooks.PreCompact _ -> Agent_sdk.Hooks.Continue

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
  : Agent_sdk.Hooks.hooks =
  { hooks with
    pre_tool_use = Some (make_pre_tool_hook ~goal ~context_summary) }

(* ================================================================ *)
(* Read-Only Detection as OAS Guardrails.Custom                      *)
(* ================================================================ *)

(** Create an OAS Guardrails config that uses read-only detection
    as a Custom tool filter.

    Tools whose names match {!read_only_patterns} (read, grep,
    search, git status, etc.) pass through. Tools that do NOT match are
    also allowed -- the filter itself does not block anything. Its purpose
    is to tag tools for downstream hooks that may skip verification for
    read-only operations.

    For actual filtering (blocking non-read-only tools), combine with a
    DenyList or use {!make_pre_tool_hook} which applies skip logic
    internally.

    This function wraps the read-only signal as a Guardrails.Custom
    predicate. Since all tools should remain visible to the MODEL, it
    always returns [true]. The predicate is provided for integration
    with custom pipelines that want to inspect read-only status. *)
let guardrails_with_read_only_tag
    ?(max_tool_calls_per_turn : int option)
    ()
  : Agent_sdk.Guardrails.t =
  {
    tool_filter = Agent_sdk.Guardrails.AllowAll;
    max_tool_calls_per_turn;
  }

(** Create an OAS Guardrails.Custom filter that identifies read-only tools.

    Returns a predicate [tool_schema -> bool] that returns true when the
    tool name matches read-only patterns. Can be used in custom
    guardrails pipelines for conditional verification bypass. *)
let read_only_predicate (schema : Agent_sdk.Types.tool_schema) : bool =
  should_skip ~action_description:schema.name

(* ================================================================ *)
(* Eval_gate -> OAS Guardrails bridge                               *)
(* ================================================================ *)

(** Convert Eval_gate.gate_config to OAS Guardrails.t.

    Maps the static tool-filtering portion of the gate config:
    - [allowlist_enabled] + [allowed_tools] -> AllowList
    - [denied_tools] only -> DenyList
    - Both enabled -> AllowList (stricter; deny is redundant)
    - Neither -> AllowAll

    Dynamic runtime checks (cost budget, entropy, destructive patterns)
    remain in Eval_gate. OAS Guardrails handles static pre-filtering;
    Eval_gate handles stateful per-call checks. Together they form
    defense-in-depth.

    @since Phase 6 — OAS Guardrails bridge *)
let eval_gate_to_oas_guardrails (gate : Eval_gate.gate_config) :
    Agent_sdk.Guardrails.t =
  let tool_filter =
    match (gate.allowlist_enabled, gate.allowed_tools, gate.denied_tools) with
    | true, (_ :: _ as allowed), _ ->
        (* AllowList is the stricter filter; deny is handled at runtime *)
        Agent_sdk.Guardrails.AllowList allowed
    | true, [], _ ->
        (* Allowlist enabled but empty = deny all tools *)
        Agent_sdk.Guardrails.AllowList []
    | false, _, (_ :: _ as denied) ->
        Agent_sdk.Guardrails.DenyList denied
    | false, _, [] ->
        Agent_sdk.Guardrails.AllowAll
  in
  {
    Agent_sdk.Guardrails.tool_filter;
    max_tool_calls_per_turn = Some gate.max_tool_calls_per_turn;
  }
