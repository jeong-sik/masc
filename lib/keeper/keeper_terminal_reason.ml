(* RFC-0042 PR-4: consumer-side closed sum for the keeper disposition
   classifier's view of [receipt.terminal_reason_code]. See the [.mli]
   for why this is a third terminal-reason type and how it relates to
   [Keeper_turn_terminal_code] (producer side) and
   [Keeper_turn_disposition] (operator-facing side).

   The whole point is to parse the wire string ONCE here and let
   [Keeper_execution_receipt.operator_disposition] exhaustive-match,
   replacing its chain of [String.starts_with] / [string_contains]
   tests. Wire bytes are preserved: payload-bearing variants carry the
   original string and [to_wire] returns it verbatim. *)

(* SSOT for the turn/time-budget cut-off prefixes. These were previously
   defined in [Keeper_execution_receipt]; moved down here so the typed
   classifier owns them and [Keeper_execution_receipt] re-exports for
   backward compatibility (the encoder [Keeper_agent_error] still reads
   them through [Keeper_execution_receipt]). A turn cut off by the
   per-call turn cap ([MaxTurnsExceeded]), the wall-clock ceiling
   ([AgentExecutionTimeout]), or the progress-aware idle watchdog
   ([AgentExecutionIdleTimeout]) did NOT violate the tool contract — it
   never reached a verdict; the supervisor auto-resumes from the
   checkpoint. *)
let terminal_prefix_max_turns_exceeded = "agent_error_max_turns_exceeded"
let terminal_prefix_execution_timeout = "agent_error_execution_timeout"
let terminal_prefix_idle_timeout = "agent_error_idle_timeout"

let is_auto_recoverable_turn_budget_terminal terminal_reason =
  String.starts_with ~prefix:terminal_prefix_max_turns_exceeded terminal_reason
  || String.starts_with ~prefix:terminal_prefix_execution_timeout terminal_reason
  || String.starts_with ~prefix:terminal_prefix_idle_timeout terminal_reason
;;

type t =
  | Runtime_exhausted of string
  | Config_or_auth of string
  | Provider_runtime_failure of string
  | Completion_contract_violation of string
  | Turn_livelock of string
  | Internal_error of string
  | Auto_recoverable_budget of string
  | Pre_dispatch_success of string
  | Other of string

let contains_config_or_auth lowered =
  String_util.contains_substring lowered "config"
  || String_util.contains_substring lowered "auth"
;;

(* Priority-ranked partition. The bucket order replicates the [if/else]
   order of the pre-typing [operator_disposition] string predicates;
   [of_wire] returns the FIRST matching bucket. The original
   (case-preserving) [wire] is carried in payload-bearing variants so
   [to_wire] reproduces it byte-for-byte; classification is done on a
   lowercased copy to match [operator_disposition], which lowercased
   [terminal_reason_code] before testing. *)
let of_wire wire =
  let lowered = String.lowercase_ascii wire in
  if String.equal lowered "runtime_exhausted"
  then Runtime_exhausted wire
  else if contains_config_or_auth lowered
  then Config_or_auth wire
  else if
    String.starts_with ~prefix:"api_error_" lowered
    || String.equal lowered "provider_error"
  then Provider_runtime_failure wire
  else if String.starts_with ~prefix:"completion_contract_violation:" lowered
  then Completion_contract_violation wire
  else if String.starts_with ~prefix:"turn_livelock:" lowered
  then Turn_livelock wire
  else if String.equal lowered "internal_error"
  then Internal_error wire
  else if is_auto_recoverable_turn_budget_terminal lowered
  then Auto_recoverable_budget wire
  else if String.equal lowered "pre_dispatch_success"
  then Pre_dispatch_success wire
  else Other wire
;;

(* Byte-identical inverse: every variant carries the original wire string,
   so [to_wire (of_wire s) = s] holds for every [s] including mixed-case
   inputs. The exact-match variants carry a payload only for this
   round-trip fidelity; [operator_disposition] ignores it. *)
let to_wire = function
  | Runtime_exhausted wire -> wire
  | Config_or_auth wire -> wire
  | Provider_runtime_failure wire -> wire
  | Completion_contract_violation wire -> wire
  | Turn_livelock wire -> wire
  | Internal_error wire -> wire
  | Auto_recoverable_budget wire -> wire
  | Pre_dispatch_success wire -> wire
  | Other wire -> wire
;;
