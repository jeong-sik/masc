(** Structured terminal-reason surface for keeper turn ledgers.

    RFC-0047 PR-3:
    - [code: string] field removed; [disposition] is the SSOT.
    - [severity_of_code / summary_of_code / next_action_of_code]
      substring classifiers deleted; severity / summary / next_action
      are now derived via exhaustive matches on
      [Keeper_turn_disposition.t].
    - [normalize_code] retained as a producer-side string preprocessor
      until producers are themselves typed (out of scope for this RFC). *)

type severity = Keeper_turn_disposition.severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

type t =
  { disposition : Keeper_turn_disposition.t
  ; source : string
  ; severity : severity
  ; summary : string
  ; next_action : string option
  }

let code t = Keeper_turn_disposition.to_wire t.disposition

let severity_to_string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Bad -> "bad"
  | Unknown_bad -> "bad"
;;

let make_from_disposition ?(source = "typed") ?summary ?next_action disposition =
  let summary =
    Option.value ~default:(Keeper_turn_disposition.summary disposition) summary
  in
  let next_action =
    match next_action with
    | Some _ as value -> value
    | None -> Keeper_turn_disposition.next_action disposition
  in
  { disposition
  ; source
  ; severity = Keeper_turn_disposition.severity disposition
  ; summary
  ; next_action
  }
;;

let make ?(source = "typed") ?summary ?next_action code =
  let disposition = Keeper_turn_disposition.of_wire code in
  make_from_disposition ~source ?summary ?next_action disposition
;;

let of_disposition ?source ?summary ?next_action disposition =
  let source = Option.value ~default:"typed" source in
  make_from_disposition ~source ?summary ?next_action disposition
;;

let success () = make ~source:"turn_result" "success"
let contains_ci text needle = String_util.contains_substring_ci text needle

let contract_code_from_error_text raw_error =
  if
    contains_ci raw_error "no ToolUse block"
    || contains_ci raw_error "called no keeper tools"
    || contains_ci raw_error "returned no keeper tool"
  then "required_tool_use_no_tool_call"
  else "required_tool_use_unsatisfied"
;;

let of_legacy_error_text raw_error =
  let trimmed = String.trim raw_error in
  if trimmed = ""
  then make ~source:"legacy_error_text" "unknown_error"
  else if contains_ci trimmed "gh_repo_context_missing_worktree"
  then make ~source:"legacy_error_text" "gh_repo_context_missing_worktree"
  else if contains_ci trimmed "oas_timeout_budget"
  then make ~source:"legacy_error_text" "oas_timeout_budget"
  else if contains_ci trimmed "Turn wall-clock timeout"
  then make ~source:"legacy_error_text" "turn_wall_clock_timeout"
  else if contains_ci trimmed "require_tool_use"
  then make ~source:"legacy_error_text" (contract_code_from_error_text trimmed)
  else make ~source:"legacy_error_text" "unknown_error"
;;

(* The fallback was previously detected via [String.equal fallback.code
   "unknown_error"]. Now we match on the typed disposition: only the
   empty-raw [Unknown { raw_error = "" }] case (produced by
   [of_legacy_error_text ""]) opts into the SDK-error-derived code. Any
   other [of_legacy_error_text] result has classified the error and
   should be returned as-is. *)
let is_unknown_empty (reason : t) =
  (* Enumerate every [Keeper_turn_disposition.t] variant so the
     compiler flags any new disposition added. Only the empty-raw
     [Unknown { raw_error = "" }] case opts into the SDK-error-derived
     code; all other dispositions (Success, External_cancel,
     Turn_wall_clock_timeout, Oas_timeout_budget,
     Gh_repo_context_missing_worktree, Required_tool_use_no_tool_call,
     Required_tool_use_unsatisfied, Post_commit_ambiguous,
     Provider_error, and Unknown with non-empty raw_error) must yield
     [false]. A future disposition variant added to
     [Keeper_turn_disposition.t] would silently inherit [false] under
     the previous [_ -> false] catch-all without a review point on
     whether the new variant should opt into the unknown-empty
     pathway. Same FSM Sparse Match anti-pattern as PRs #14716,
     #14790, #14806, #14810, #14816, #14823. *)
  match reason.disposition with
  | Keeper_turn_disposition.Unknown { raw_error = "" } -> true
  | Keeper_turn_disposition.Unknown { raw_error = _ }
  | Keeper_turn_disposition.Success
  | Keeper_turn_disposition.External_cancel
  | Keeper_turn_disposition.Turn_wall_clock_timeout
  | Keeper_turn_disposition.Oas_timeout_budget
  | Keeper_turn_disposition.Gh_repo_context_missing_worktree
  | Keeper_turn_disposition.Required_tool_use_no_tool_call
  | Keeper_turn_disposition.Required_tool_use_unsatisfied
  | Keeper_turn_disposition.Post_commit_ambiguous
  | Keeper_turn_disposition.Provider_error _ -> false
;;

let of_failure ?(post_commit_ambiguous = false) ?(tool_call_count = 0) ~raw_error err =
  if post_commit_ambiguous
  then make ~source:"typed_error" "post_commit_ambiguous"
  else (
    match Keeper_turn_driver.classify_masc_internal_error err with
    | Some (Keeper_turn_driver.Oas_timeout_budget _) ->
      make ~source:"typed_error" "oas_timeout_budget"
    | Some (Keeper_turn_driver.Turn_timeout _) ->
      make ~source:"typed_error" "turn_wall_clock_timeout"
    | _ ->
      (match err with
       | Agent_sdk.Error.Agent
           (Agent_sdk.Error.CompletionContractViolation
              { contract = Agent_sdk.Completion_contract_id.Require_tool_use; _ }) ->
         let code =
           if tool_call_count <= 0
           then contract_code_from_error_text raw_error
           else "required_tool_use_unsatisfied"
         in
         make ~source:"typed_error" code
       | _ ->
         let fallback = of_legacy_error_text raw_error in
         if is_unknown_empty fallback
         then
           (* RFC-0047 follow-up: emit typed [Provider_error] directly via
              [Keeper_agent_error.terminal_reason_code_of_sdk_error_typed]
              so [registry_failure_reason_of_terminal_reason] can match
              exhaustively on disposition without a substring guard for
              "api_error_*" wires. The typed bridge encapsulates the
              [Sdk_error _] wrapping; the consumer no longer touches a
              raw wire string. *)
           of_disposition
             ~source:"typed_error"
             (Keeper_turn_disposition.Provider_error
                (Keeper_agent_error.terminal_reason_code_of_sdk_error_typed err))
         else fallback))
;;

let of_code ?source ?summary ?next_action code =
  let source = Option.value ~default:"legacy_code" source in
  make ~source ?summary ?next_action code
;;

let to_json reason =
  `Assoc
    [ "code", `String (code reason)
    ; "disposition", `String (Keeper_turn_disposition.to_wire reason.disposition)
    ; "source", `String reason.source
    ; "severity", `String (severity_to_string reason.severity)
    ; "summary", `String reason.summary
    ; ( "next_action"
      , match reason.next_action with
        | Some action -> `String action
        | None -> `Null )
    ]
;;

let string_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) when String.trim value <> "" -> Some value
     | _ -> None)
  | _ -> None
;;

let of_json json =
  let source = string_member "source" json |> Option.value ~default:"decision_log" in
  let summary = string_member "summary" json in
  let next_action = string_member "next_action" json in
  match string_member "disposition" json with
  | Some wire ->
    let disposition = Keeper_turn_disposition.of_wire wire in
    Some (of_disposition ~source ?summary ?next_action disposition)
  | None ->
    (match string_member "code" json with
     | Some code -> Some (of_code ~source ?summary ?next_action code)
     | None -> None)
;;
