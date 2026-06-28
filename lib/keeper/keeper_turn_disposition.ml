(* RFC-0047 PR-1: operator-facing disposition closed sum.

   See [.mli] for the public contract. This file holds the type
   definition, the canonical projection from
   [Keeper_turn_terminal_code], and the wire-format serialisation
   chosen to be byte-for-byte compatible with the strings emitted
   today by [Keeper_turn_terminal.t.code]. *)

module Code = Keeper_turn_terminal_code

let chop_prefix ~prefix value =
  let prefix_len = String.length prefix in
  let value_len = String.length value in
  if value_len >= prefix_len && String.sub value 0 prefix_len = prefix
  then Some (String.sub value prefix_len (value_len - prefix_len))
  else None
;;

let chop_suffix ~suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  if value_len >= suffix_len
     && String.sub value (value_len - suffix_len) suffix_len = suffix
  then Some (String.sub value 0 (value_len - suffix_len))
  else None
;;

type t =
  | Success
  | External_cancel
  | Input_required
  | Turn_wall_clock_timeout
  | Runtime_attempts_exhausted
  | Completion_contract_unsatisfied
  | Completion_contract_no_progress
  | Post_commit_ambiguous
  | Turn_budget_exhausted of
      { dimension : [ `Turns | `Wall_clock_seconds | `Idle_turns ]
      ; used : int
      ; limit : int
      ; source : [ `Oas_sdk | `Keeper_runtime | `User_config ]
      }
  | Provider_error of Code.t
  | Unknown of { raw_error : string }

type severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

let severity = function
  | Success -> Ok
  | Input_required -> Ok
  | External_cancel
  | Turn_wall_clock_timeout
  | Runtime_attempts_exhausted -> Warn
  | Completion_contract_unsatisfied
  | Completion_contract_no_progress
  | Post_commit_ambiguous
  | Provider_error _
  | Turn_budget_exhausted _ -> Bad
  | Unknown _ -> Unknown_bad
;;

let summary = function
  | Success -> "turn completed"
  | Input_required -> "agent paused to request human input"
  | External_cancel -> "keeper turn was cancelled before completion"
  | Turn_wall_clock_timeout ->
    "keeper turn hit a stale/no-progress timeout"
  | Runtime_attempts_exhausted ->
    "runtime attempts exhausted; inspect per-attempt root causes"
  | Completion_contract_unsatisfied ->
    "completion contract was not satisfied; review the contract or the runtime"
  | Completion_contract_no_progress ->
    "no progress was made on the contract; operator resume clears the no-progress latch"
  | Post_commit_ambiguous ->
    "provider failed after a mutating tool may have committed side effects"
  | Turn_budget_exhausted { dimension; used; limit; source } ->
    Printf.sprintf
      "%s budget exhausted (%d/%d, source=%s)"
      (match dimension with
       | `Turns -> "turn"
       | `Wall_clock_seconds -> "wall_clock_seconds"
       | `Idle_turns -> "idle_turn")
      used
      limit
      (match source with
       | `Oas_sdk -> "oas_sdk"
       | `Keeper_runtime -> "keeper_runtime"
       | `User_config -> "user_config")
  | Provider_error code -> Printf.sprintf "keeper turn ended with %s" (Code.to_wire code)
  | Unknown { raw_error = "" } ->
    "keeper turn failed without a classified terminal reason"
  | Unknown { raw_error } -> Printf.sprintf "keeper turn ended with %s" raw_error
;;

let next_action = function
  | Success -> None
  | Input_required -> Some "provide_input_or_decline"
  | External_cancel -> Some "rerun_if_still_relevant"
  | Turn_wall_clock_timeout -> Some "inspect_turn_timeout"
  | Runtime_attempts_exhausted -> Some "inspect_runtime_attempts"
  | Completion_contract_unsatisfied -> Some "inspect_completion_contract"
  | Completion_contract_no_progress -> Some "resume_or_inspect_completion_contract"
  | Post_commit_ambiguous -> Some "reconcile_partial_commit"
  | Turn_budget_exhausted _ -> Some "inspect_turn_budget"
  | Provider_error _ | Unknown _ -> Some "inspect_latest_error"
;;

let to_wire = function
  | Success -> "success"
  | Input_required -> "input_required"
  | External_cancel -> "external_cancel"
  | Turn_wall_clock_timeout -> "turn_wall_clock_timeout"
  | Runtime_attempts_exhausted -> "runtime_attempts_exhausted"
  | Completion_contract_unsatisfied -> "completion_contract_unsatisfied"
  | Completion_contract_no_progress -> "completion_contract_no_progress"
  | Post_commit_ambiguous -> "post_commit_ambiguous"
  | Turn_budget_exhausted { dimension; used; limit; source } ->
    Printf.sprintf
      "turn_budget_exhausted(%s:%s:%d/%d)"
      (match dimension with
       | `Turns -> "turns"
       | `Wall_clock_seconds -> "wall_clock_seconds"
       | `Idle_turns -> "idle_turns")
      (match source with
       | `Oas_sdk -> "oas_sdk"
       | `Keeper_runtime -> "keeper_runtime"
       | `User_config -> "user_config")
      used
      limit
  | Provider_error code -> Code.to_wire code
  | Unknown { raw_error = "" } -> "unknown_error"
  | Unknown { raw_error } -> raw_error
;;

(* Projection from runtime layer to operator layer.

   A runtime cause maps directly to a non-[Provider_error] arm only
   when the runtime classification fully determines the operator
   action. Stale_turn_timeout_* are operator-equivalent to the
   stale/no-progress timeout disposition; the Ambiguous_partial_commit_* pair
   both indicate post-commit ambiguity.
   All other runtime causes are wrapped so the typed cause is
   preserved for diagnostics. *)
let of_termination_code (c : Code.t) : t =
  match c with
  | Code.Healthy -> Success
  | Code.Stale_turn_timeout_idle
  | Code.Stale_turn_timeout_in_turn
  | Code.Stale_turn_timeout_no_progress
  | Code.Stale_turn_timeout_noop -> Turn_wall_clock_timeout
  | Code.Ambiguous_partial_commit_post_commit_timeout
  | Code.Ambiguous_partial_commit_post_commit_failure -> Post_commit_ambiguous
  | Code.Heartbeat_failures
  | Code.Turn_failures
  | Code.Stale_termination_storm
  | Code.Stale_fleet_batch
  | Code.Turn_overflow_pause
  | Code.Turn_livelock_pause
  | Code.Provider_runtime_error _
  | Code.Fiber_unresolved
  | Code.Exception_unhandled _
  | Code.Sdk_error _ -> Provider_error c
;;

(* Wire→typed parser for the [Turn_budget_exhausted] record.

   The legacy free-text form is
   ["turn_budget_exhausted(<dim>:<source>:<used>/<limit>)"].
   Unknown dimension/source tags or unparseable integers fall back to
   [Unknown { raw_error = original }] — fail-closed, never permissive.

   Parsing policy mirrors the [Completion_contract_*] constructors:
   the typed schema is the SSOT; wire strings that don't conform are
   carried verbatim for diagnostic surfacing rather than being
   silently collapsed. *)
let of_wire_turn_budget_exhausted wire =
  let parse_dimension = function
    | "turns" -> Some `Turns
    | "wall_clock_seconds" -> Some `Wall_clock_seconds
    | "idle_turns" -> Some `Idle_turns
    | _ -> None
  in
  let parse_source = function
    | "oas_sdk" -> Some `Oas_sdk
    | "keeper_runtime" -> Some `Keeper_runtime
    | "user_config" -> Some `User_config
    | _ -> None
  in
  match chop_prefix ~prefix:"turn_budget_exhausted(" wire with
  | None -> None
  | Some body ->
    (match chop_suffix ~suffix:")" body with
     | None -> None
     | Some body ->
       (match String.split_on_char ':' body with
        | [ dim_str; src_str; counts_str ] ->
          (match
             parse_dimension dim_str, parse_source src_str, String.split_on_char '/' counts_str
           with
           | Some dim, Some src, [ used_str; limit_str ] ->
             (match int_of_string_opt used_str, int_of_string_opt limit_str with
              | Some used, Some limit ->
                Some (Turn_budget_exhausted { dimension = dim; used; limit; source = src })
              | _ -> None)
           | _ -> None)
        | _ -> None))
;;

let of_wire wire =
  match chop_prefix ~prefix:"turn_budget_exhausted" wire with
  | Some _ ->
    (match of_wire_turn_budget_exhausted wire with
     | Some disposition -> disposition
     | None -> Unknown { raw_error = wire })
  | None ->
    (match wire with
     | "success" -> Success
     | "input_required" -> Input_required
     | "external_cancel" -> External_cancel
     | "turn_wall_clock_timeout" -> Turn_wall_clock_timeout
     | "runtime_attempts_exhausted" -> Runtime_attempts_exhausted
     | "completion_contract_unsatisfied" -> Completion_contract_unsatisfied
     | "completion_contract_no_progress" -> Completion_contract_no_progress
     | "post_commit_ambiguous" -> Post_commit_ambiguous
     | "unknown_error" -> Unknown { raw_error = "" }
     | other ->
       (match Code.of_wire other with
        | Some c -> of_termination_code c
        | None -> Unknown { raw_error = other }))
;;

let legacy_simple_turn_budget_exhausted wire =
  match chop_prefix ~prefix:"turn_budget_exhausted:" wire with
  | None -> false
  | Some counts ->
    (match String.split_on_char '/' counts with
     | [ used; limit ] ->
       Option.is_some (int_of_string_opt used)
       && Option.is_some (int_of_string_opt limit)
     | _ -> false)
;;

let is_turn_budget_exhausted_wire wire =
  let wire = String.lowercase_ascii (String.trim wire) in
  match of_wire wire with
  | Turn_budget_exhausted _ -> true
  | _ -> legacy_simple_turn_budget_exhausted wire
;;

let equal a b =
  match a, b with
  | Success, Success
  | Input_required, Input_required
  | External_cancel, External_cancel
  | Turn_wall_clock_timeout, Turn_wall_clock_timeout
  | Runtime_attempts_exhausted, Runtime_attempts_exhausted
  | Completion_contract_unsatisfied, Completion_contract_unsatisfied
  | Completion_contract_no_progress, Completion_contract_no_progress
  | Post_commit_ambiguous, Post_commit_ambiguous -> true
  | Turn_budget_exhausted a, Turn_budget_exhausted b ->
    a.dimension = b.dimension
    && a.used = b.used
    && a.limit = b.limit
    && a.source = b.source
  | Provider_error a, Provider_error b -> String.equal (Code.to_wire a) (Code.to_wire b)
  | Unknown a, Unknown b -> String.equal a.raw_error b.raw_error
  | ( Success
    | Input_required
    | External_cancel
    | Turn_wall_clock_timeout
    | Runtime_attempts_exhausted
    | Completion_contract_unsatisfied
    | Completion_contract_no_progress
    | Post_commit_ambiguous
    | Turn_budget_exhausted _
    | Provider_error _
    | Unknown _ ), _ -> false
;;

let pp fmt t = Format.pp_print_string fmt (to_wire t)
