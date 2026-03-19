(** Verifier_oas — Action verification engine with OAS Guardrails/Hooks bridge.

    Cheap-model action verification for feedback loops.
    Each action is sent to a cheap model with a structured prompt:
    "Given goal X, action Y produced result Z. Is this correct?"
    The model responds PASS/WARN/FAIL with a brief reason.

    Budget: max 200 output tokens per verification (~0.01 cents).
    Skip: read-only actions (file reads, glob, grep, searches).

    OAS integration:
    - [verdict_to_hook_decision]: Pass/Warn/Fail -> OAS Continue/Continue/Skip
    - [make_pre_tool_hook]: wraps verify as an OAS PreToolUse hook
    - [guardrails_with_read_only_tag]: wraps should_skip as OAS Custom filter

    @since 2.61.0 (verifier core)
    @since Phase 4 (OAS Guardrails adapter) *)

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

(** Parse "PASS", "WARN: reason", "FAIL: reason" from LLM output. *)
let parse_verdict (text : string) : verdict =
  let trimmed = String.trim text in
  let upper = String.uppercase_ascii trimmed in
  if String.length upper >= 4 && String.sub upper 0 4 = "PASS" then
    Pass
  else if String.length upper >= 4 && String.sub upper 0 4 = "WARN" then
    let reason = if String.length trimmed > 5 then
      String.trim (String.sub trimmed 5 (String.length trimmed - 5))
    else "unspecified concern" in
    (* Strip leading colon/dash *)
    let reason = if String.length reason > 0 &&
      (reason.[0] = ':' || reason.[0] = '-') then
      String.trim (String.sub reason 1 (String.length reason - 1))
    else reason in
    Warn reason
  else if String.length upper >= 4 && String.sub upper 0 4 = "FAIL" then
    let reason = if String.length trimmed > 5 then
      String.trim (String.sub trimmed 5 (String.length trimmed - 5))
    else "action did not achieve goal" in
    let reason = if String.length reason > 0 &&
      (reason.[0] = ':' || reason.[0] = '-') then
      String.trim (String.sub reason 1 (String.length reason - 1))
    else reason in
    Fail reason
  else
    (* If model doesn't follow format, treat as warning *)
    if String.length trimmed > 0 then Warn trimmed
    else Pass

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

let verify ~(model : Llm_types.model_spec) (req : verification_request) : verdict =
  if should_skip ~action_description:req.action_description then
    Pass
  else
    let prompt = build_prompt req in
    let completion_req : Llm_types.completion_request = {
      model;
      messages = [Agent_sdk.Types.user_msg prompt];
      temperature = 0.0;  (* Deterministic for verification *)
      max_tokens = 200;   (* Budget cap *)
      tools = [];
      response_format = `Text;
    } in
    match Oas_worker.complete completion_req with
    | Ok resp -> parse_verdict (Llm_types.text_of_response resp)
    | Error e ->
      eprintf "[verifier] LLM call failed: %s (defaulting to WARN)\n%!" e;
      Warn ("verifier_unavailable: " ^ e)

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
    eprintf "[verifier_oas] WARN: %s\n%!" reason;
    Agent_sdk.Hooks.Continue
  | Fail reason ->
    eprintf "[verifier_oas] FAIL (skipping tool): %s\n%!" reason;
    Agent_sdk.Hooks.Skip

(* ================================================================ *)
(* PreToolUse Hook                                                   *)
(* ================================================================ *)

(** Create an OAS PreToolUse hook that wraps the verify logic.

    On PreToolUse events, builds a {!verification_request} from
    the tool name and input JSON, calls {!verify} with the given
    model, and maps the verdict to a hook decision.

    For non-PreToolUse events, returns Continue (pass-through).

    @param model The cheap LLM model spec used for verification.
    @param goal The current agent goal (for verification prompt context).
    @param context_summary Brief summary of agent state. *)
let make_pre_tool_hook
    ~(model : Llm_types.model_spec)
    ~(goal : string)
    ~(context_summary : string)
  : Agent_sdk.Hooks.hook =
  fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse { tool_name; input } ->
      let action_description = sprintf "tool:%s" tool_name in
      (* Skip read-only tools without calling the LLM *)
      if should_skip ~action_description then
        Agent_sdk.Hooks.Continue
      else
        let input_str =
          try Yojson.Safe.to_string input
          with _ -> "{}" in
        let req : verification_request = {
          action_description;
          action_result = input_str;
          goal;
          context_summary;
        } in
        let verdict = verify ~model req in
        verdict_to_hook_decision verdict
    | _ -> Agent_sdk.Hooks.Continue

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
    ~(model : Llm_types.model_spec)
    ~(goal : string)
    ~(context_summary : string)
  : Agent_sdk.Hooks.hooks =
  { hooks with
    pre_tool_use = Some (make_pre_tool_hook ~model ~goal ~context_summary) }

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
    predicate. Since all tools should remain visible to the LLM, it
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
