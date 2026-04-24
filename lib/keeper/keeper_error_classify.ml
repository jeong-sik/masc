(** Keeper_error_classify — Error classification, side-effect safety,
    and retry constants for the unified keeper cycle.

    Pure predicates and classification functions over [Oas.Error.sdk_error].
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
    Uses structured [Oas.Error.sdk_error] pattern matching instead of
    substring matching on stringified error messages. *)
let is_structural_oas_timeout_message message =
  let lower = String.lowercase_ascii message in
  string_contains_substring ~needle:"(budget=" lower
  || string_contains_substring ~needle:"turn wall-clock budget exhausted" lower

let is_transient_network_error (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api (NetworkError _) -> true
  | Oas.Error.Api (Timeout { message }) ->
      not (is_structural_oas_timeout_message message)
  | Oas.Error.Api (Overloaded _) -> true
  | Oas.Error.Api (ServerError { status = 503; _ }) -> true
  | _ -> false

(** Detect server-side request body parse errors (e.g. Ollama yyjson
    rejecting a request with "Value looks like object, but can't find
    closing '}' symbol").  The LLM API never processed the request, so
    committed tool results are not at risk of duplication.

    These errors may recur with the same payload, so they are NOT
    eligible for same-turn retry.  They ARE eligible for auto-recovery
    when all committed tools are reconcile-safe (idempotent/board-like):
    the keeper's next heartbeat cycle will build a fresh prompt. *)
let is_server_rejected_parse_error (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api (InvalidRequest { message }) ->
      let lower = String.lowercase_ascii message in
      (* Compound patterns to avoid false positives on generic messages
         like "Service closing" or "Can't find the specified tool".
         Each pattern targets a specific JSON parser error family. *)
      (string_contains_substring ~needle:"can't find closing" lower
       || string_contains_substring ~needle:"find end of" lower)
      || string_contains_substring ~needle:"unexpected character in json" lower
      || string_contains_substring ~needle:"unterminated" lower
      || string_contains_substring ~needle:"parse error" lower
  | _ -> false

let is_required_tool_contract_violation (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Agent (Oas.Error.CompletionContractViolation { contract; _ }) ->
      contract = Oas.Completion_contract_id.Require_tool_use
  | _ -> false

let is_auto_recoverable_cascade_exhausted_error (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some
      (Oas_worker_named.Cascade_exhausted
         { reason = Keeper_types.Candidates_filtered_after_cycles; _ }) ->
      true
  | Some
      (Oas_worker_named.Cascade_exhausted
         { reason = Keeper_types.Other_detail detail; _ }) ->
      Oas_worker_named.message_looks_like_cli_wrapped_hard_quota detail
  | Some (Oas_worker_named.Cascade_exhausted _) ->
      false
  | Some (Oas_worker_named.No_tool_capable_provider _)
  | Some (Oas_worker_named.Accept_rejected _)
  | Some (Oas_worker_named.Resumable_cli_session _)
  | Some (Oas_worker_named.Admission_queue_rejected _)
  | Some (Oas_worker_named.Admission_queue_timeout _)
  | Some (Oas_worker_named.Turn_timeout _)
  | Some (Oas_worker_named.Oas_timeout_budget _)
  | Some (Oas_worker_named.Ambiguous_post_commit _)
  | None ->
      false

let is_resumable_cli_session_error (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some (Oas_worker_named.Resumable_cli_session _) -> true
  | Some (Oas_worker_named.Cascade_exhausted _)
  | Some (Oas_worker_named.No_tool_capable_provider _)
  | Some (Oas_worker_named.Accept_rejected _)
  | Some (Oas_worker_named.Admission_queue_timeout _)
  | Some (Oas_worker_named.Admission_queue_rejected _)
  | Some (Oas_worker_named.Turn_timeout _)
  | Some (Oas_worker_named.Oas_timeout_budget _)
  | Some (Oas_worker_named.Ambiguous_post_commit _)
  | None ->
      false

let is_auto_recoverable_cascade_fail_open_error
    (err : Oas.Error.sdk_error) : bool =
  Oas_worker_named.sdk_error_is_hard_quota err
  || is_resumable_cli_session_error err
  || is_auto_recoverable_cascade_exhausted_error err

type degraded_retry =
  { next_cascade : string
  ; fallback_reason : string
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
    || String.equal normalized_effective Keeper_config.default_cascade_name
  then None
  else Some Keeper_config.default_cascade_name

let degraded_retry_after_recoverable_error
    ~(effective_cascade : string)
    ~(tool_requirement : string)
    (err : Oas.Error.sdk_error) : degraded_retry option =
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
  if String.equal tool_requirement "required"
     || String.equal normalized_effective Keeper_config.local_only_cascade_name
     || String.equal normalized_effective
          Keeper_config.local_recovery_cascade_name
  then None
  else if Oas_worker_named.sdk_error_is_hard_quota err then
    local_recovery_retry "hard_quota"
  else
    match Oas_worker_named.classify_masc_internal_error err with
    | Some (Oas_worker_named.Resumable_cli_session _) ->
        local_recovery_retry "resumable_cli_session"
    | Some (Oas_worker_named.Admission_queue_timeout _) ->
        local_recovery_retry "admission_queue_timeout"
    | Some (Oas_worker_named.Oas_timeout_budget _) ->
        local_recovery_retry "oas_timeout_budget"
    | Some (Oas_worker_named.Turn_timeout _) ->
        local_recovery_retry "turn_timeout"
    | Some
        (Oas_worker_named.Cascade_exhausted
           { reason = Keeper_types.Candidates_filtered_after_cycles; _ }) ->
        local_recovery_retry "cascade_candidates_filtered"
    | Some
        (Oas_worker_named.Cascade_exhausted
           { reason = Keeper_types.Other_detail detail; _ })
      when Oas_worker_named.message_looks_like_cli_wrapped_hard_quota detail ->
        local_recovery_retry "hard_quota"
    | Some (Oas_worker_named.Cascade_exhausted _)
    | Some (Oas_worker_named.No_tool_capable_provider _)
    | Some (Oas_worker_named.Accept_rejected _)
    | Some (Oas_worker_named.Admission_queue_rejected _)
    | Some (Oas_worker_named.Ambiguous_post_commit _)
    | None ->
        None

let recoverable_cascade_failure_reason (err : Oas.Error.sdk_error) =
  if is_required_tool_contract_violation err then
    Some "required_tool_contract_violation"
  else if Oas_worker_named.sdk_error_is_hard_quota err then
    Some "hard_quota"
  else
    match Oas_worker_named.classify_masc_internal_error err with
    | Some (Oas_worker_named.Resumable_cli_session _) ->
        Some "resumable_cli_session"
    | Some (Oas_worker_named.Admission_queue_timeout _) ->
        Some "admission_queue_timeout"
    | Some (Oas_worker_named.Oas_timeout_budget _) ->
        Some "oas_timeout_budget"
    | Some (Oas_worker_named.Turn_timeout _) ->
        Some "turn_timeout"
    | Some
        (Oas_worker_named.Cascade_exhausted
           { reason = Keeper_types.Candidates_filtered_after_cycles; _ }) ->
        Some "cascade_candidates_filtered"
    | Some
        (Oas_worker_named.Cascade_exhausted
           { reason = Keeper_types.Other_detail detail; _ })
      when Oas_worker_named.message_looks_like_cli_wrapped_hard_quota detail ->
        Some "hard_quota"
    | Some (Oas_worker_named.Cascade_exhausted _)
    | Some (Oas_worker_named.No_tool_capable_provider _)
    | Some (Oas_worker_named.Accept_rejected _)
    | Some (Oas_worker_named.Admission_queue_rejected _)
    | Some (Oas_worker_named.Ambiguous_post_commit _)
    | None ->
        None

let normalized_cascade_name name =
  let trimmed = String.trim name in
  if
    String.equal trimmed Keeper_config.local_only_cascade_name
    || String.equal trimmed Keeper_config.local_recovery_cascade_name
    || String.equal trimmed Keeper_config.tool_use_strict_cascade_name
  then trimmed
  else Keeper_cascade_profile.normalize_declared_name trimmed

let required_tool_rotation_candidate name =
  let normalized = normalized_cascade_name name in
  not
    (String.equal normalized Keeper_config.local_only_cascade_name
     || String.equal normalized Keeper_config.local_recovery_cascade_name)

let degraded_rotation_candidates
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : string) =
  let normalized_base = normalized_cascade_name base_cascade in
  let normalized_effective = normalized_cascade_name effective_cascade in
  let candidates =
    if String.equal tool_requirement "required" then
      [
        Keeper_config.tool_use_strict_cascade_name;
        normalized_base;
        Keeper_config.default_cascade_name;
      ]
    else
      [
        normalized_base;
        Keeper_config.default_cascade_name;
        Keeper_config.local_recovery_cascade_name;
        Keeper_config.tool_use_strict_cascade_name;
      ]
  in
  candidates
  |> List.map normalized_cascade_name
  |> dedupe_keep_order
  |> List.filter (fun candidate ->
         (not (String.equal candidate normalized_effective))
         && (not (String.equal tool_requirement "required")
             || required_tool_rotation_candidate candidate))

let degraded_rotation_after_recoverable_error
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : string)
    ~(attempted_cascades : string list)
    (err : Oas.Error.sdk_error) : degraded_retry option =
  match recoverable_cascade_failure_reason err with
  | None -> None
  | Some fallback_reason ->
      let attempted =
        attempted_cascades
        |> List.map normalized_cascade_name
        |> dedupe_keep_order
      in
      degraded_rotation_candidates
        ~base_cascade ~effective_cascade ~tool_requirement
      |> List.find_opt (fun candidate ->
             not (List.exists (String.equal candidate) attempted))
      |> Option.map (fun next_cascade -> { next_cascade; fallback_reason })

let is_auto_recoverable_turn_error (err : Oas.Error.sdk_error) : bool =
  is_transient_network_error err
  || is_server_rejected_parse_error err
  || is_resumable_cli_session_error err
  || is_auto_recoverable_cascade_exhausted_error err

let ambiguous_side_effect_error_prefix =
  "turn outcome ambiguous after committed mutating tool call(s)"

let committed_mutating_tools tool_names =
  tool_names
  |> dedupe_keep_order
  |> List.filter Keeper_exec_tools.has_mutating_side_effect

let is_ambiguous_side_effect_error (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some (Oas_worker_named.Ambiguous_post_commit _) -> true
  | None -> (
      match err with
      | Oas.Error.Internal msg ->
          string_contains_substring
            ~needle:ambiguous_side_effect_error_prefix msg
      | _ -> false)
  | _ -> false

let reclassify_error_after_side_effect
    ~(tool_names : string list)
    (err : Oas.Error.sdk_error) : Oas.Error.sdk_error =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = [] || is_ambiguous_side_effect_error err then err
  else
    let tools = committed_tools in
    let original = short_preview (Oas.Error.to_string err) in
    let is_timeout = match err with Oas.Error.Api (Timeout _) -> true | _ -> false in
    Oas_worker_named.sdk_error_of_masc_internal_error
      (Oas_worker_named.Ambiguous_post_commit
         { is_timeout; tools; original_error = original })

let post_commit_failure_kind_of_error (err : Oas.Error.sdk_error) =
  match err with
  | Oas.Error.Api (Timeout _) -> Keeper_registry.Post_commit_timeout
  | _ -> Keeper_registry.Post_commit_failure

let summarize_post_commit_failure
    ~(tool_names : string list)
    ~(kind : Keeper_registry.ambiguous_partial_commit_kind)
    (err : Oas.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  let tools = String.concat ", " committed_tools in
  let err_preview = short_preview (Oas.Error.to_string err) in
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
    (err : Oas.Error.sdk_error) =
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
    transiently (e.g. TCP keepalive expiry across all backends). *)
let max_transient_retries = 2

(** Exponential backoff delay for transient retry [attempt] (1-indexed).
    Delays: 1s, 2s — total wait 3s before giving up. *)
let transient_backoff_sec (attempt : int) : float =
  Float.min 4.0 (1.0 *. Float.of_int (1 lsl (attempt - 1)))

(** [true] when a structured error indicates context overflow. *)
let is_context_overflow (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api (ContextOverflow _) -> true
  | Oas.Error.Agent (TokenBudgetExceeded { kind = "Input"; _ }) -> true
  | _ -> false

(** [true] when an error represents terminal cascade exhaustion or a
    final accept-rejected result from the MASC OAS boundary. *)
let is_cascade_exhausted_error (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named.classify_masc_internal_error err with
  | Some (Oas_worker_named.Cascade_exhausted _)
  | Some (Oas_worker_named.Resumable_cli_session _)
  | Some (Oas_worker_named.No_tool_capable_provider _)
  | Some (Oas_worker_named.Accept_rejected _) -> true
  | Some (Oas_worker_named.Admission_queue_timeout _)
  | Some (Oas_worker_named.Admission_queue_rejected _)
  | Some (Oas_worker_named.Oas_timeout_budget _)
  | Some (Oas_worker_named.Turn_timeout _)
  | Some (Oas_worker_named.Ambiguous_post_commit _) -> false
  | None -> false
