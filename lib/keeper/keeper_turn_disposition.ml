(* RFC-0047 PR-1: operator-facing disposition closed sum.

   See [.mli] for the public contract. This file holds the type
   definition, the canonical projection from
   [Keeper_turn_terminal_code], and the wire-format serialisation
   chosen to be byte-for-byte compatible with the strings emitted
   today by [Keeper_turn_terminal.t.code]. *)

module Code = Keeper_turn_terminal_code

type t =
  | Success
  | External_cancel
  | Turn_wall_clock_timeout
  | Oas_timeout_budget
  | Gh_repo_context_missing_worktree
  | Required_tool_use_no_tool_call
  | Required_tool_use_unsatisfied
  | Post_commit_ambiguous
  | Provider_error of Code.t
  | Unknown of { raw_error : string }

type severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

let severity = function
  | Success -> Ok
  | External_cancel
  | Turn_wall_clock_timeout
  | Oas_timeout_budget
  | Gh_repo_context_missing_worktree -> Warn
  | Required_tool_use_no_tool_call
  | Required_tool_use_unsatisfied
  | Post_commit_ambiguous
  | Provider_error _ -> Bad
  | Unknown _ -> Unknown_bad
;;

let summary = function
  | Success -> "turn completed"
  | External_cancel -> "keeper turn was cancelled before completion"
  | Turn_wall_clock_timeout -> "keeper turn hit the wall-clock timeout"
  | Oas_timeout_budget ->
    "OAS call was skipped or failed because the turn timeout budget was exhausted"
  | Gh_repo_context_missing_worktree ->
    "GitHub command blocked because the active task has no linked worktree"
  | Required_tool_use_no_tool_call ->
    "required keeper tool use was requested, but the model returned no keeper tool call"
  | Required_tool_use_unsatisfied ->
    "required keeper tool use was requested, but the tool contract was not satisfied"
  | Post_commit_ambiguous ->
    "provider failed after a mutating tool may have committed side effects"
  | Provider_error (Code.Provider_runtime_error "provider_error") ->
    (* Legacy producer alias: pre-RFC [normalize_code "api_error_timeout"]
       collapsed to the literal string "provider_error", which got the
       specific summary below. PR-2/PR-3 retire that producer-side
       normalize; this arm preserves byte-compat until then. *)
    "provider or cascade failed"
  | Provider_error code -> Printf.sprintf "keeper turn ended with %s" (Code.to_wire code)
  | Unknown { raw_error = "" } ->
    "keeper turn failed without a classified terminal reason"
  | Unknown { raw_error } -> Printf.sprintf "keeper turn ended with %s" raw_error
;;

let next_action = function
  | Success -> None
  | External_cancel -> Some "rerun_if_still_relevant"
  | Turn_wall_clock_timeout | Oas_timeout_budget -> Some "inspect_timeout_budget"
  | Gh_repo_context_missing_worktree -> Some "create_or_link_worktree"
  | Required_tool_use_no_tool_call | Required_tool_use_unsatisfied ->
    Some "inspect_provider_tool_contract"
  | Post_commit_ambiguous -> Some "reconcile_partial_commit"
  | Provider_error _ | Unknown _ -> Some "inspect_latest_error"
;;

let to_wire = function
  | Success -> "success"
  | External_cancel -> "external_cancel"
  | Turn_wall_clock_timeout -> "turn_wall_clock_timeout"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | Gh_repo_context_missing_worktree -> "gh_repo_context_missing_worktree"
  | Required_tool_use_no_tool_call -> "required_tool_use_no_tool_call"
  | Required_tool_use_unsatisfied -> "required_tool_use_unsatisfied"
  | Post_commit_ambiguous -> "post_commit_ambiguous"
  | Provider_error code -> Code.to_wire code
  | Unknown { raw_error = "" } -> "unknown_error"
  | Unknown { raw_error } -> raw_error
;;

(* Projection from runtime layer to operator layer.

   A runtime cause maps directly to a non-[Provider_error] arm only
   when the runtime classification fully determines the operator
   action. Stale_turn_timeout_* are operator-equivalent to the
   "wall-clock timeout" disposition; Tool_required_unsatisfied is
   operator-equivalent to "required tool use unsatisfied"; the
   Ambiguous_partial_commit_* pair both indicate post-commit ambiguity.
   All other runtime causes are wrapped so the typed cause is
   preserved for diagnostics. *)
let of_termination_code (c : Code.t) : t =
  match c with
  | Code.Healthy -> Success
  | Code.Stale_turn_timeout_idle
  | Code.Stale_turn_timeout_in_turn
  | Code.Stale_turn_timeout_noop -> Turn_wall_clock_timeout
  | Code.Oas_timeout_budget -> Oas_timeout_budget
  | Code.Tool_required_unsatisfied _ -> Required_tool_use_unsatisfied
  | Code.Ambiguous_partial_commit_post_commit_timeout
  | Code.Ambiguous_partial_commit_post_commit_failure -> Post_commit_ambiguous
  | Code.Heartbeat_failures
  | Code.Turn_failures
  | Code.Stale_termination_storm
  | Code.Stale_fleet_batch
  | Code.Provider_runtime_error _
  | Code.Fiber_unresolved
  | Code.Exception_unhandled _
  | Code.Sdk_error _ -> Provider_error c
;;

let of_wire = function
  | "success" -> Success
  | "external_cancel" -> External_cancel
  | "turn_wall_clock_timeout" -> Turn_wall_clock_timeout
  | "oas_timeout_budget" -> Oas_timeout_budget
  | "gh_repo_context_missing_worktree" -> Gh_repo_context_missing_worktree
  | "required_tool_use_no_tool_call" -> Required_tool_use_no_tool_call
  | "required_tool_use_unsatisfied" -> Required_tool_use_unsatisfied
  | "post_commit_ambiguous" -> Post_commit_ambiguous
  | "unknown_error" -> Unknown { raw_error = "" }
  | other ->
    (match Code.of_wire other with
     | Some c -> of_termination_code c
     | None -> Unknown { raw_error = other })
;;

let equal a b =
  match a, b with
  | Success, Success
  | External_cancel, External_cancel
  | Turn_wall_clock_timeout, Turn_wall_clock_timeout
  | Oas_timeout_budget, Oas_timeout_budget
  | Gh_repo_context_missing_worktree, Gh_repo_context_missing_worktree
  | Required_tool_use_no_tool_call, Required_tool_use_no_tool_call
  | Required_tool_use_unsatisfied, Required_tool_use_unsatisfied
  | Post_commit_ambiguous, Post_commit_ambiguous -> true
  | Provider_error a, Provider_error b -> String.equal (Code.to_wire a) (Code.to_wire b)
  | Unknown a, Unknown b -> String.equal a.raw_error b.raw_error
  | Success, _
  | External_cancel, _
  | Turn_wall_clock_timeout, _
  | Oas_timeout_budget, _
  | Gh_repo_context_missing_worktree, _
  | Required_tool_use_no_tool_call, _
  | Required_tool_use_unsatisfied, _
  | Post_commit_ambiguous, _
  | Provider_error _, _
  | Unknown _, _ -> false
;;

let pp fmt t = Format.pp_print_string fmt (to_wire t)
