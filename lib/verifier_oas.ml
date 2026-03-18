(** Verifier_oas — Adapter bridging MASC verifier to OAS Guardrails and Hooks.

    Maps MASC's verification flow (should_skip, verify, verdict) to OAS
    {!Agent_sdk.Guardrails.Custom} filter and {!Agent_sdk.Hooks.hook} callbacks.

    - [verdict_to_hook_decision]: MASC Pass/Warn/Fail -> OAS Continue/Continue/Skip
    - [make_pre_tool_hook]: wraps MASC verify_action as an OAS PreToolUse hook
    - [guardrails_of_read_only_detection]: wraps MASC should_skip as OAS Custom filter

    Enabled via [MASC_USE_OAS_GUARDRAILS=true] environment variable.

    @since Phase 4 — OAS Guardrails adapter for verifier *)

open Printf

(* ================================================================ *)
(* Feature Flag                                                      *)
(* ================================================================ *)

let use_oas_guardrails () =
  match Sys.getenv_opt "MASC_USE_OAS_GUARDRAILS" with
  | Some v ->
    let v = String.lowercase_ascii (String.trim v) in
    v = "true" || v = "1" || v = "yes"
  | None -> false

(* ================================================================ *)
(* Verdict -> Hook Decision                                          *)
(* ================================================================ *)

(** Map a MASC verdict to an OAS hook decision.

    - Pass -> Continue (action proceeds normally)
    - Warn -> Continue (action proceeds; warning is logged, not blocking)
    - Fail -> Skip (action is blocked)

    Warn reasons are logged to stderr for observability but do not halt
    execution, matching MASC's existing behavior where warnings are
    informational. *)
let verdict_to_hook_decision (v : Verifier.verdict) : Agent_sdk.Hooks.hook_decision =
  match v with
  | Verifier.Pass -> Agent_sdk.Hooks.Continue
  | Verifier.Warn reason ->
    eprintf "[verifier_oas] WARN: %s\n%!" reason;
    Agent_sdk.Hooks.Continue
  | Verifier.Fail reason ->
    eprintf "[verifier_oas] FAIL (skipping tool): %s\n%!" reason;
    Agent_sdk.Hooks.Skip

(* ================================================================ *)
(* PreToolUse Hook                                                   *)
(* ================================================================ *)

(** Create an OAS PreToolUse hook that wraps MASC's verify_action logic.

    On PreToolUse events, builds a {!Verifier.verification_request} from
    the tool name and input JSON, calls {!Verifier.verify} with the given
    model, and maps the verdict to a hook decision.

    For non-PreToolUse events, returns Continue (pass-through).

    @param model The cheap LLM model spec used for verification.
    @param goal The current agent goal (for verification prompt context).
    @param context_summary Brief summary of agent state. *)
let make_pre_tool_hook
    ~(model : Llm_client.model_spec)
    ~(goal : string)
    ~(context_summary : string)
  : Agent_sdk.Hooks.hook =
  fun event ->
    match event with
    | Agent_sdk.Hooks.PreToolUse { tool_name; input } ->
      let action_description = sprintf "tool:%s" tool_name in
      (* Skip read-only tools without calling the LLM *)
      if Verifier.should_skip ~action_description then
        Agent_sdk.Hooks.Continue
      else
        let input_str =
          try Yojson.Safe.to_string input
          with _ -> "{}" in
        let req : Verifier.verification_request = {
          action_description;
          action_result = input_str;
          goal;
          context_summary;
        } in
        let verdict = Verifier.verify ~model req in
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
    ~(model : Llm_client.model_spec)
    ~(goal : string)
    ~(context_summary : string)
  : Agent_sdk.Hooks.hooks =
  { hooks with
    pre_tool_use = Some (make_pre_tool_hook ~model ~goal ~context_summary) }

(* ================================================================ *)
(* Read-Only Detection as OAS Guardrails.Custom                      *)
(* ================================================================ *)

(** Create an OAS Guardrails config that uses MASC's read-only detection
    as a Custom tool filter.

    Tools whose names match {!Verifier.read_only_patterns} (read, grep,
    search, git status, etc.) pass through. Tools that do NOT match are
    also allowed — the filter itself does not block anything. Its purpose
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
    tool name matches MASC's read-only patterns. Can be used in custom
    guardrails pipelines for conditional verification bypass. *)
let read_only_predicate (schema : Agent_sdk.Types.tool_schema) : bool =
  Verifier.should_skip ~action_description:schema.name
