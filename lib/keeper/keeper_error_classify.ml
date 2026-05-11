(** Keeper_error_classify — Error classification, side-effect safety,
    and retry constants for the unified keeper cycle.

    Pure predicates and classification functions over [Agent_sdk.Error.sdk_error].
    No I/O, no state mutation.

    Extracted from keeper_unified_turn.ml.

    @since 0.122.0 *)

open Keeper_types
open Keeper_exec_context

(* Duplicated from keeper_unified_turn.ml to avoid circular dependency.
   keeper_unified_turn.ml also keeps its own copy for the error-classification
   helpers that remain there (is_server_rejected_parse_error pattern matching). *)
let substring_matches_at ~(needle : string) (haystack : string) start_idx =
  let needle_len = String.length needle in
  if start_idx < 0 || start_idx + needle_len > String.length haystack
  then false
  else
    let rec check i =
      if i >= needle_len then true
      else if String.unsafe_get needle i <> String.unsafe_get haystack (start_idx + i)
      then false
      else check (i + 1)
    in
    check 0

let string_contains_substring ~(needle : string) (haystack : string) : bool =
  if needle = "" then true
  else
    let max_start = String.length haystack - String.length needle in
    let rec try_from i =
      if i > max_start then false
      else if substring_matches_at ~needle haystack i then true
      else try_from (i + 1)
    in
    try_from 0

(** {1 Retry & Side-Effect Safety}

    @boundary-contract
    - MASC owns: side-effect detection (blocking retry after mutating tools),
      cross-provider retry (2 attempts after all OAS per-provider retries
      exhaust), error reclassification for ambiguous outcomes.
    - OAS owns: per-provider retry (3 attempts), HTTP backoff, timeout
      handling, provider failover within a single cascade call.
    - Neither may: retry silently after a mutating tool succeeded (integrity
      over availability); duplicate OAS per-provider retry counts. *)

(** Detect transient network errors that warrant retry with short backoff.
    Uses structured [Agent_sdk.Error.sdk_error] pattern matching instead of
    substring matching on stringified error messages. *)
let is_structural_oas_timeout_message message =
  let lower = String.lowercase_ascii message in
  string_contains_substring ~needle:"(budget=" lower
  || string_contains_substring ~needle:"turn wall-clock budget exhausted" lower

let is_transient_network_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (NetworkError _) -> true
  | Agent_sdk.Error.Api (Timeout { message }) ->
      not (is_structural_oas_timeout_message message)
  | Agent_sdk.Error.Api (Overloaded _) -> true
  | Agent_sdk.Error.Api (ServerError { status = 503; _ }) -> true
  (* Non-transient API errors. *)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (InvalidRequest _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (ContextOverflow _) -> false
  (* Non-API error families are by definition not transient network errors. *)
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> false

(** Detect server-side request body parse errors (e.g. Ollama yyjson
    rejecting a request with "Value looks like object, but can't find
    closing '}' symbol").  The LLM API never processed the request, so
    committed tool results are not at risk of duplication.

    These errors may recur with the same payload, so they are NOT
    eligible for same-turn retry.  They ARE eligible for auto-recovery
    when all committed tools are reconcile-safe (idempotent/board-like):
    the keeper's next heartbeat cycle will build a fresh prompt. *)
let is_server_rejected_parse_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (InvalidRequest { message }) ->
      let lower = String.lowercase_ascii message in
      (* Compound patterns to avoid false positives on generic messages
         like "Service closing" or "Can't find the specified tool".
         Each pattern targets a specific JSON parser error family. *)
      (string_contains_substring ~needle:"can't find closing" lower
       || string_contains_substring ~needle:"find end of" lower)
      || string_contains_substring ~needle:"unexpected character in json" lower
      || string_contains_substring ~needle:"unterminated" lower
      || string_contains_substring ~needle:"parse error" lower
  (* All other API error variants do not represent server-side parse failures. *)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (Overloaded _)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (ContextOverflow _)
  | Agent_sdk.Error.Api (NetworkError _)
  | Agent_sdk.Error.Api (Timeout _) -> false
  (* Non-API error families. *)
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> false

let is_required_tool_contract_violation (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Agent (Agent_sdk.Error.CompletionContractViolation { contract; _ }) ->
      contract = Agent_sdk.Completion_contract_id.Require_tool_use
  (* Other agent-level errors are not require-tool-use contract violations. *)
  | Agent_sdk.Error.Agent (MaxTurnsExceeded _)
  | Agent_sdk.Error.Agent (TokenBudgetExceeded _)
  | Agent_sdk.Error.Agent (CostBudgetExceeded _)
  | Agent_sdk.Error.Agent (UnrecognizedStopReason _)
  | Agent_sdk.Error.Agent (IdleDetected _)
  | Agent_sdk.Error.Agent (ToolRetryExhausted _)
  | Agent_sdk.Error.Agent (GuardrailViolation _)
  | Agent_sdk.Error.Agent (TripwireViolation _)
  | Agent_sdk.Error.Agent (ExitConditionMet _) -> false
  (* Non-Agent error families. *)
  | Agent_sdk.Error.Api _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> false

let is_auto_recoverable_cascade_exhausted_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some
      (Keeper_turn_driver.Cascade_exhausted
         { reason = Keeper_types.Candidates_filtered_after_cycles; _ }) ->
      true
  | Some
      (Keeper_turn_driver.Cascade_exhausted
         { reason = Keeper_types.Max_turns_exceeded; _ }) ->
      true
  | Some
      (Keeper_turn_driver.Cascade_exhausted
         { reason = Keeper_types.Other_detail detail; _ }) ->
      Keeper_turn_driver.message_looks_like_cli_wrapped_hard_quota detail
      || Keeper_turn_driver.message_looks_like_cli_wrapped_max_turns detail
  | Some (Keeper_turn_driver.Cascade_exhausted _) ->
      false
  | Some (Keeper_turn_driver.No_tool_capable_provider _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Oas_timeout_budget _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _)
  | None ->
      false

let is_resumable_cli_session_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> true
  | Some (Keeper_turn_driver.Cascade_exhausted _)
  | Some (Keeper_turn_driver.No_tool_capable_provider _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Oas_timeout_budget _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _)
  | None ->
      false

let is_auto_recoverable_cascade_fail_open_error
    (err : Agent_sdk.Error.sdk_error) : bool =
  Keeper_turn_driver.sdk_error_is_hard_quota err
  || Keeper_turn_driver.sdk_error_is_max_turns_exceeded err
  || is_resumable_cli_session_error err
  || is_auto_recoverable_cascade_exhausted_error err

(* Classification of why a degraded retry is being attempted.  Closed set
   covering both producer paths: [local_recovery_retry] (7 narrow reasons)
   and [recoverable_cascade_failure_reason] (broader set including raw
   provider API failures).  Wire form is the lowercase string via
   [degraded_retry_reason_to_string]. *)
type degraded_retry_reason =
  | Hard_quota
  | Max_turns
  | Resumable_cli_session
  | Admission_queue_timeout
  | Oas_timeout_budget
  | Turn_timeout
  | Cascade_candidates_filtered
  | Required_tool_contract_violation
  | Cascade_exhausted
  | Rate_limit
  | Server_error
  | Auth_error

let degraded_retry_reason_to_string = function
  | Hard_quota -> "hard_quota"
  | Max_turns -> "max_turns"
  | Resumable_cli_session -> "resumable_cli_session"
  | Admission_queue_timeout -> "admission_queue_timeout"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | Turn_timeout -> "turn_timeout"
  | Cascade_candidates_filtered -> "cascade_candidates_filtered"
  | Required_tool_contract_violation -> "required_tool_contract_violation"
  | Cascade_exhausted -> "cascade_exhausted"
  | Rate_limit -> "rate_limit"
  | Server_error -> "server_error"
  | Auth_error -> "auth_error"

type degraded_retry =
  { next_cascade : string
  ; fallback_reason : degraded_retry_reason
  }

let fallback_cascade_for_unavailable_profile
    ~(base_cascade : string)
    ~(effective_cascade : string) : string option =
  let normalized_base =
    Keeper_cascade_profile.normalize_declared_name base_cascade
  in
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name effective_cascade
  in
  if not (String.equal normalized_effective normalized_base)
  then Some normalized_base
  else if
    String.equal normalized_effective Keeper_config.local_only_cascade_name
    || String.equal normalized_effective (Keeper_config.default_cascade_name ())
  then None
  else Some (Keeper_config.default_cascade_name ())

let degraded_retry_after_recoverable_error
    ~(effective_cascade : string)
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry option =
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name effective_cascade
  in
  let local_recovery_retry fallback_reason =
    Some
      {
        next_cascade = Keeper_config.local_recovery_cascade_name;
        fallback_reason;
      }
  in
  if tool_requirement = Required
     || String.equal normalized_effective Keeper_config.local_only_cascade_name
     || String.equal normalized_effective
          Keeper_config.local_recovery_cascade_name
  then None
  else if Keeper_turn_driver.sdk_error_is_hard_quota err then
    local_recovery_retry Hard_quota
  else if Keeper_turn_driver.sdk_error_is_max_turns_exceeded err then
    local_recovery_retry Max_turns
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Resumable_cli_session _) ->
        local_recovery_retry Resumable_cli_session
    | Some (Keeper_turn_driver.Admission_queue_timeout _) ->
        local_recovery_retry Admission_queue_timeout
    | Some (Keeper_turn_driver.Oas_timeout_budget _) ->
        local_recovery_retry Oas_timeout_budget
    | Some (Keeper_turn_driver.Turn_timeout _) ->
        local_recovery_retry Turn_timeout
    | Some
        (Keeper_turn_driver.Cascade_exhausted
           { reason = Keeper_types.Candidates_filtered_after_cycles; _ }) ->
        local_recovery_retry Cascade_candidates_filtered
    | Some
        (Keeper_turn_driver.Cascade_exhausted
           { reason = Keeper_types.Max_turns_exceeded; _ }) ->
        local_recovery_retry Max_turns
    | Some
        (Keeper_turn_driver.Cascade_exhausted
           { reason = Keeper_types.Other_detail detail; _ })
      when Keeper_turn_driver.message_looks_like_cli_wrapped_hard_quota detail ->
        local_recovery_retry Hard_quota
    | Some (Keeper_turn_driver.Cascade_exhausted _)
    | Some (Keeper_turn_driver.No_tool_capable_provider _)
    | Some (Keeper_turn_driver.Accept_rejected _)
    | Some (Keeper_turn_driver.Admission_queue_rejected _)
    | Some (Keeper_turn_driver.Ambiguous_post_commit _)
    | None ->
        None

let recoverable_cascade_failure_reason (err : Agent_sdk.Error.sdk_error) =
  if is_required_tool_contract_violation err then
    Some Required_tool_contract_violation
  else if Keeper_turn_driver.sdk_error_is_hard_quota err then
    Some Hard_quota
  else if Keeper_turn_driver.sdk_error_is_max_turns_exceeded err then
    Some Max_turns
  else
    match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Resumable_cli_session _) ->
        Some Resumable_cli_session
    | Some (Keeper_turn_driver.Admission_queue_timeout _) ->
        Some Admission_queue_timeout
    | Some (Keeper_turn_driver.Oas_timeout_budget _) ->
        Some Oas_timeout_budget
    | Some (Keeper_turn_driver.Turn_timeout _) ->
        Some Turn_timeout
    | Some
        (Keeper_turn_driver.Cascade_exhausted
           { reason = Keeper_types.Candidates_filtered_after_cycles; _ }) ->
        Some Cascade_candidates_filtered
    | Some
        (Keeper_turn_driver.Cascade_exhausted
           { reason = Keeper_types.Max_turns_exceeded; _ }) ->
        Some Max_turns
    | Some
        (Keeper_turn_driver.Cascade_exhausted
           { reason = Keeper_types.Other_detail detail; _ })
      when Keeper_turn_driver.message_looks_like_cli_wrapped_hard_quota detail ->
        Some Hard_quota
    | Some (Keeper_turn_driver.Cascade_exhausted _) ->
        (* Generic cascade exhaustion: all candidates failed without a more
           specific reason. Treat as recoverable so declarative
           [fallback_cascade] hints declared in cascade.toml actually
           escalate. Receipt-derived data on 2026-04-25 showed 31/39
           silent turns ended with [(null)] fallback_reason because this
           arm previously returned [None]. Other arms below remain
           non-recoverable to keep the surface conservative. *)
        Some Cascade_exhausted
    | Some (Keeper_turn_driver.No_tool_capable_provider _)
    | Some (Keeper_turn_driver.Accept_rejected _)
    | Some (Keeper_turn_driver.Admission_queue_rejected _)
    | Some (Keeper_turn_driver.Ambiguous_post_commit _) ->
        None
    | None ->
        (* Status-code-aware cascade rotation: raw provider API errors that are
           not wrapped in a MASC internal error (e.g. single-provider cascades
           where OAS surfaces the error directly) should still trigger rotation
           when a different cascade may succeed.

           429 rate-limit (non-hard-quota): the current provider is throttled;
           a different cascade/provider may have capacity.

           5xx server errors: the provider is unhealthy or overloaded; a
           different cascade may be healthy.

           401/403 auth errors: the credential for this cascade is invalid; a
           different cascade with different credentials may succeed.

           Hard-quota 429s are already handled above by sdk_error_is_hard_quota,
           so only soft (non-hard-quota) rate limits reach this arm. *)
        (match err with
         | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _) ->
             Some Rate_limit
         | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError { status; _ })
           when status >= 500 ->
             Some Server_error
         | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError _) ->
             Some Auth_error
         (* Sub-500 server errors (4xx already handled above for AuthError /
            RateLimited) are not classified as recoverable cascade failures. *)
         | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.ContextOverflow _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError _)
         | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _) -> None
         (* Non-API error families have no rotation reason here: structured
            MASC internal errors are handled by [classify_masc_internal_error]
            above; agent / mcp / config / etc. are not provider-level rotations. *)
         | Agent_sdk.Error.Agent _
         | Agent_sdk.Error.Mcp _
         | Agent_sdk.Error.Config _
         | Agent_sdk.Error.Serialization _
         | Agent_sdk.Error.Io _
         | Agent_sdk.Error.Orchestration _
         | Agent_sdk.Error.A2a _
         | Agent_sdk.Error.Internal _ -> None)

let normalized_cascade_name ~catalog_names name =
  let trimmed = String.trim name in
  let is_live_catalog_profile =
    List.exists (String.equal trimmed) catalog_names
  in
  (* Fallback candidates are concrete catalog profiles, not keeper-declared
     logical routes.  Preserve live profile names like [local_recovery] so a
     fallback_cascade does not collapse back to routes.phase_recovery. *)
  if
    is_live_catalog_profile
    || String.equal trimmed Keeper_config.local_only_cascade_name
    || String.equal trimmed Keeper_config.local_recovery_cascade_name
    || String.equal trimmed Keeper_config.tool_use_strict_cascade_name
  then trimmed
  else Keeper_cascade_profile.normalize_declared_name trimmed

let required_tool_rotation_candidate ~catalog_names name =
  let normalized = normalized_cascade_name ~catalog_names name in
  let routed_local_only_is_distinct =
    not
      (String.equal
         Keeper_config.local_only_cascade_name
         (Keeper_config.default_cascade_name ()))
  in
  (* Required-tool turns may still use [local_recovery] when the catalog
     declares it as a tool-capable fallback profile.  Keep excluding the
     local-only/buffer lane here: those routes are recovery/control lanes and
     may not satisfy a required keeper-tool contract. *)
  not
    ((routed_local_only_is_distinct
      && String.equal normalized Keeper_config.local_only_cascade_name))

let legacy_degraded_rotation_candidates
    ~catalog_names
    ~(base_cascade : string)
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement) =
  let normalized_base = normalized_cascade_name ~catalog_names base_cascade in
  let default_cascade =
    normalized_cascade_name ~catalog_names (Keeper_config.default_cascade_name ())
  in
  let local_recovery_cascade =
    normalized_cascade_name ~catalog_names
      Keeper_config.local_recovery_cascade_name
  in
  match tool_requirement with
  | Required -> [ normalized_base; default_cascade ]
  | Optional | No_tools ->
    [ normalized_base; default_cascade; local_recovery_cascade ]

let normalize_rotation_candidates ~catalog_names candidates =
  candidates
  |> List.filter_map (fun candidate ->
         let trimmed = String.trim candidate in
         if String.equal trimmed "" then None
         else Some (normalized_cascade_name ~catalog_names trimmed))
  |> dedupe_keep_order

let degraded_rotation_candidates
    ~catalog_names
    ~(rotation_cascades : string list option)
    ~(fallback_hint : string option)
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement) =
  let normalized_effective =
    normalized_cascade_name ~catalog_names effective_cascade
  in
  let raw_candidates =
    match rotation_cascades with
    | None ->
        legacy_degraded_rotation_candidates ~catalog_names ~base_cascade
          ~tool_requirement
    | Some catalog -> normalize_rotation_candidates ~catalog_names catalog
  in
  let candidates =
    match fallback_hint with
    | None -> raw_candidates
    | Some hint ->
        let trimmed = String.trim hint in
        if String.equal trimmed "" then raw_candidates
        else
          normalize_rotation_candidates ~catalog_names (trimmed :: raw_candidates)
  in
  candidates
  |> List.filter (fun candidate ->
         (not (String.equal candidate normalized_effective))
         && (tool_requirement <> Required
             || required_tool_rotation_candidate ~catalog_names candidate))

let degraded_rotation_after_recoverable_error
    ?rotation_cascades
    ?fallback_hint
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
    ~(attempted_cascades : string list)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry option =
  match recoverable_cascade_failure_reason err with
  | None -> None
  | Some fallback_reason ->
      (* Load the live catalog once at the degraded-rotation boundary and pass
         the snapshot through normalization/filter helpers.  This preserves
         concrete profile names without adding per-candidate catalog I/O. *)
      let catalog_names = Keeper_cascade_profile.catalog_names () in
      let attempted =
        attempted_cascades
        |> List.map (normalized_cascade_name ~catalog_names)
        |> dedupe_keep_order
      in
      degraded_rotation_candidates
        ~catalog_names
        ~rotation_cascades
        ~fallback_hint
        ~base_cascade ~effective_cascade ~tool_requirement
      |> List.find_opt (fun candidate ->
             not (List.exists (String.equal candidate) attempted))
      |> Option.map (fun next_cascade -> { next_cascade; fallback_reason })

let is_auto_recoverable_turn_error (err : Agent_sdk.Error.sdk_error) : bool =
  is_transient_network_error err
  || is_server_rejected_parse_error err
  || Keeper_turn_driver.sdk_error_is_max_turns_exceeded err
  || is_resumable_cli_session_error err
  || is_auto_recoverable_cascade_exhausted_error err

let ambiguous_side_effect_error_prefix =
  "turn outcome ambiguous after committed mutating tool call(s)"

let committed_mutating_tools tool_names =
  tool_names
  |> dedupe_keep_order
  |> List.filter Keeper_exec_tools.has_mutating_side_effect

let is_ambiguous_side_effect_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Ambiguous_post_commit _) -> true
  | None -> (
      match err with
      | Agent_sdk.Error.Internal msg ->
          string_contains_substring
            ~needle:ambiguous_side_effect_error_prefix msg
      (* Non-Internal sdk_error variants do not encode the legacy
         ambiguous-side-effect string prefix; the structured
         [Ambiguous_post_commit] arm above covers the new path. *)
      | Agent_sdk.Error.Api _
      | Agent_sdk.Error.Agent _
      | Agent_sdk.Error.Mcp _
      | Agent_sdk.Error.Config _
      | Agent_sdk.Error.Serialization _
      | Agent_sdk.Error.Io _
      | Agent_sdk.Error.Orchestration _
      | Agent_sdk.Error.A2a _ -> false)
  (* All other MASC-internal classifications are unambiguous failures. *)
  | Some (Keeper_turn_driver.Cascade_exhausted _)
  | Some (Keeper_turn_driver.No_tool_capable_provider _)
  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Oas_timeout_budget _) -> false

let reclassify_error_after_side_effect
    ~(tool_names : string list)
    (err : Agent_sdk.Error.sdk_error) : Agent_sdk.Error.sdk_error =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = [] || is_ambiguous_side_effect_error err then err
  else
    let tools = committed_tools in
    let original = short_preview (Agent_sdk.Error.to_string err) in
    let is_timeout =
      match err with
      | Agent_sdk.Error.Api (Timeout _) -> true
      | Agent_sdk.Error.Api (RateLimited _)
      | Agent_sdk.Error.Api (Overloaded _)
      | Agent_sdk.Error.Api (ServerError _)
      | Agent_sdk.Error.Api (AuthError _)
      | Agent_sdk.Error.Api (InvalidRequest _)
      | Agent_sdk.Error.Api (NotFound _)
      | Agent_sdk.Error.Api (ContextOverflow _)
      | Agent_sdk.Error.Api (NetworkError _) -> false
      | Agent_sdk.Error.Agent _
      | Agent_sdk.Error.Mcp _
      | Agent_sdk.Error.Config _
      | Agent_sdk.Error.Serialization _
      | Agent_sdk.Error.Io _
      | Agent_sdk.Error.Orchestration _
      | Agent_sdk.Error.A2a _
      | Agent_sdk.Error.Internal _ -> false
    in
    Keeper_turn_driver.sdk_error_of_masc_internal_error
      (Keeper_turn_driver.Ambiguous_post_commit
         { is_timeout; tools; original_error = original })

let post_commit_failure_kind_of_error (err : Agent_sdk.Error.sdk_error) =
  match err with
  | Agent_sdk.Error.Api (Timeout _) -> Keeper_registry.Post_commit_timeout
  (* All non-Timeout failures classify as generic post-commit failure. *)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (Overloaded _)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (InvalidRequest _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (ContextOverflow _)
  | Agent_sdk.Error.Api (NetworkError _)
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> Keeper_registry.Post_commit_failure

let summarize_post_commit_failure
    ~(tool_names : string list)
    ~(kind : Keeper_registry.ambiguous_partial_commit_kind)
    (err : Agent_sdk.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  let tools = String.concat ", " committed_tools in
  let err_preview = short_preview (Agent_sdk.Error.to_string err) in
  (* Manual reconcile blocker removed — no "required/not required" branching.
     Evidence is recorded via Keeper_registry; the next turn's observation
     signals the failure for autonomous or operator-driven recovery. *)
  match kind with
  | Keeper_registry.Post_commit_timeout ->
      Printf.sprintf
        "Mutating tools [%s] committed before the turn timed out; evidence \
         recorded (error: %s)"
        tools err_preview
  | Keeper_registry.Post_commit_failure ->
      Printf.sprintf
        "Mutating tools [%s] committed before the turn failed; evidence \
         recorded (error: %s)"
        tools err_preview

let classify_post_commit_failure
    ~(tool_names : string list)
    ?kind
    (err : Agent_sdk.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = []
  then None
  else
    let resolved_kind =
      Option.value ~default:(post_commit_failure_kind_of_error err) kind
    in
    let reclassified =
      reclassify_error_after_side_effect ~tool_names:committed_tools err
    in
    let detail =
      summarize_post_commit_failure
        ~tool_names:committed_tools
        ~kind:resolved_kind
        err
    in
    Some
      ( reclassified,
        Keeper_registry.Ambiguous_partial_commit
          { kind = resolved_kind; detail } )

(** Max transient retries (excluding the initial attempt).  Total attempts
    = 1 initial + max_transient_retries.  OAS internal retry is 3 per
    provider; this outer retry covers cases where all providers fail
    transiently (e.g. TCP keepalive expiry across all backends).

    Runtime-configurable via [Env_config_keeper.KeeperRetryBackoff]. *)
let max_transient_retries () =
  Env_config_keeper.KeeperRetryBackoff.max_transient_retries ()

(** Exponential backoff delay for transient retry [attempt] (1-indexed).
    Delegates to [Env_config_keeper.KeeperRetryBackoff]. *)
let transient_backoff_sec (attempt : int) : float =
  Env_config_keeper.KeeperRetryBackoff.transient_backoff_sec attempt

(** [true] when a structured error indicates context overflow. *)
let is_context_overflow (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (ContextOverflow _) -> true
  | Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Input"; _ }) -> true
  (* Output / non-input token budget exceeded does not represent prompt overflow. *)
  | Agent_sdk.Error.Agent (TokenBudgetExceeded _) -> false
  (* Other API error variants do not indicate context overflow. *)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (Overloaded _)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (InvalidRequest _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (NetworkError _)
  | Agent_sdk.Error.Api (Timeout _) -> false
  (* Other agent error variants. *)
  | Agent_sdk.Error.Agent (MaxTurnsExceeded _)
  | Agent_sdk.Error.Agent (CostBudgetExceeded _)
  | Agent_sdk.Error.Agent (UnrecognizedStopReason _)
  | Agent_sdk.Error.Agent (IdleDetected _)
  | Agent_sdk.Error.Agent (ToolRetryExhausted _)
  | Agent_sdk.Error.Agent (CompletionContractViolation _)
  | Agent_sdk.Error.Agent (GuardrailViolation _)
  | Agent_sdk.Error.Agent (TripwireViolation _)
  | Agent_sdk.Error.Agent (ExitConditionMet _) -> false
  (* Non-API / non-Agent error families. *)
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> false

(** [true] when an error represents terminal cascade exhaustion or a
    final accept-rejected result from the MASC OAS boundary. *)
let is_cascade_exhausted_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Cascade_exhausted _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.No_tool_capable_provider _)
  | Some (Keeper_turn_driver.Accept_rejected _) -> true
  | Some (Keeper_turn_driver.Admission_queue_timeout _)
  | Some (Keeper_turn_driver.Admission_queue_rejected _)
  | Some (Keeper_turn_driver.Oas_timeout_budget _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Ambiguous_post_commit _) -> false
  | None -> false

(** [true] when the rotation-cap fast-fail should fire for a
    [required_tool_contract_violation] error.  The cap prevents runaway
    rotation chains where the LLM calls no keeper tools: we allow at most one
    rotation (so [attempted_cascades] must have at least 2 entries before the
    cap fires), unless a fresh fallback cascade is still available
    ([fallback_not_yet_tried = true]).

    The list is seeded with the initial cascade name before the first turn
    attempt, so:
    - length = 1  ⇒ no rotation has been attempted yet → do not cap
    - length ≥ 2  ⇒ at least one rotation was tried → cap (unless fallback available) *)
let should_cap_rotation_for_contract_violation
    ~(attempted_cascades : string list)
    ~(fallback_not_yet_tried : bool)
    (err : Agent_sdk.Error.sdk_error) : bool =
  is_required_tool_contract_violation err
  && List.length attempted_cascades >= 2
  && not fallback_not_yet_tried
