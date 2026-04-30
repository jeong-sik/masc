(** Structured terminal-reason surface for keeper turn ledgers. *)

type severity =
  | Ok
  | Warn
  | Bad

type t =
  { code : string
  ; source : string
  ; severity : severity
  ; summary : string
  ; next_action : string option
  }

let severity_to_string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Bad -> "bad"

let known_severity_of_code = function
  | "success" -> Some Ok
  | "external_cancel"
  | "oas_timeout_budget"
  | "turn_wall_clock_timeout"
  | "gh_repo_context_missing_worktree" -> Some Warn
  | "required_tool_use_no_tool_call"
  | "required_tool_use_unsatisfied"
  | "post_commit_ambiguous"
  | "provider_error"
  | "unknown_error" -> Some Bad
  | _ -> None

let severity_of_code code =
  match known_severity_of_code code with
  | Some severity -> severity
  | None -> Bad

let summary_of_code = function
  | "success" -> "turn completed"
  | "required_tool_use_no_tool_call" ->
      "required keeper tool use was requested, but the model returned no keeper tool call"
  | "required_tool_use_unsatisfied" ->
      "required keeper tool use was requested, but the tool contract was not satisfied"
  | "gh_repo_context_missing_worktree" ->
      "GitHub command blocked because the active task has no linked worktree"
  | "oas_timeout_budget" ->
      "OAS call was skipped or failed because the turn timeout budget was exhausted"
  | "turn_wall_clock_timeout" ->
      "keeper turn hit the wall-clock timeout"
  | "external_cancel" ->
      "keeper turn was cancelled before completion"
  | "post_commit_ambiguous" ->
      "provider failed after a mutating tool may have committed side effects"
  | "provider_error" ->
      "provider or cascade failed"
  | "unknown_error" ->
      "keeper turn failed without a classified terminal reason"
  | code ->
      Printf.sprintf "keeper turn ended with %s" code

let next_action_of_code = function
  | "required_tool_use_no_tool_call"
  | "required_tool_use_unsatisfied" ->
      Some "inspect_provider_tool_contract"
  | "gh_repo_context_missing_worktree" ->
      Some "create_or_link_worktree"
  | "oas_timeout_budget"
  | "turn_wall_clock_timeout" ->
      Some "inspect_timeout_budget"
  | "external_cancel" ->
      Some "rerun_if_still_relevant"
  | "post_commit_ambiguous" ->
      Some "reconcile_partial_commit"
  | "provider_error"
  | "unknown_error" ->
      Some "inspect_latest_error"
  | _ -> None

let normalize_code = function
  | "completed" -> "success"
  | "completion_contract_violation:require_tool_use" ->
      "required_tool_use_unsatisfied"
  | "api_error_timeout" -> "provider_error"
  | code -> code

let make ?(source = "typed") ?summary ?next_action code =
  let code = normalize_code code in
  let summary = Option.value ~default:(summary_of_code code) summary in
  let next_action =
    match next_action with
    | Some _ as value -> value
    | None -> next_action_of_code code
  in
  { code; source; severity = severity_of_code code; summary; next_action }

let success () = make ~source:"turn_result" "success"

let contains_ci text needle =
  String_util.contains_substring_ci text needle

let contract_code_from_error_text raw_error =
  if contains_ci raw_error "no ToolUse block"
     || contains_ci raw_error "called no keeper tools"
     || contains_ci raw_error "returned no keeper tool"
  then "required_tool_use_no_tool_call"
  else "required_tool_use_unsatisfied"

let of_legacy_error_text raw_error =
  let trimmed = String.trim raw_error in
  if trimmed = "" then make ~source:"legacy_error_text" "unknown_error"
  else if contains_ci trimmed "gh_repo_context_missing_worktree" then
    make ~source:"legacy_error_text" "gh_repo_context_missing_worktree"
  else if contains_ci trimmed "oas_timeout_budget" then
    make ~source:"legacy_error_text" "oas_timeout_budget"
  else if contains_ci trimmed "Turn wall-clock timeout" then
    make ~source:"legacy_error_text" "turn_wall_clock_timeout"
  else if contains_ci trimmed "require_tool_use" then
    make ~source:"legacy_error_text" (contract_code_from_error_text trimmed)
  else
    make ~source:"legacy_error_text" "unknown_error"

let of_failure ?(post_commit_ambiguous = false) ?(tool_call_count = 0)
    ~raw_error err =
  if post_commit_ambiguous then
    make ~source:"typed_error" "post_commit_ambiguous"
  else
    match Oas_worker_named.classify_masc_internal_error err with
    | Some (Oas_worker_named.Oas_timeout_budget _) ->
        make ~source:"typed_error" "oas_timeout_budget"
    | Some (Oas_worker_named.Turn_timeout _) ->
        make ~source:"typed_error" "turn_wall_clock_timeout"
    | _ ->
        (match err with
         | Oas.Error.Agent
             (Oas.Error.CompletionContractViolation
                { contract = Oas.Completion_contract_id.Require_tool_use; _ }) ->
             let code =
               if tool_call_count <= 0 then
                 contract_code_from_error_text raw_error
               else
                 "required_tool_use_unsatisfied"
             in
             make ~source:"typed_error" code
         | _ ->
             let fallback = of_legacy_error_text raw_error in
             if String.equal fallback.code "unknown_error" then
               make ~source:"typed_error"
                 (Keeper_agent_error.terminal_reason_code_of_sdk_error err)
             else
               fallback)

let of_code ?source ?summary ?next_action code =
  let source = Option.value ~default:"legacy_code" source in
  make ~source ?summary ?next_action code

let to_json reason =
  `Assoc
    [ ("code", `String reason.code)
    ; ("source", `String reason.source)
    ; ("severity", `String (severity_to_string reason.severity))
    ; ("summary", `String reason.summary)
    ; ( "next_action",
        match reason.next_action with
        | Some action -> `String action
        | None -> `Null )
    ]

let string_member key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None)
  | _ -> None

let of_json json =
  match string_member "code" json with
  | None -> None
  | Some code ->
      let source =
        string_member "source" json |> Option.value ~default:"decision_log"
      in
      let summary = string_member "summary" json in
      let next_action = string_member "next_action" json in
      Some (of_code ~source ?summary ?next_action code)
