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
   ([AgentExecutionIdleTimeout]) did NOT violate the completion contract — it
   never reached a verdict; the supervisor auto-resumes from the
   checkpoint. *)
let terminal_prefix_max_turns_exceeded = "agent_error_max_turns_exceeded"
let terminal_prefix_execution_timeout = "agent_error_execution_timeout"
let terminal_prefix_idle_timeout = "agent_error_idle_timeout"
let terminal_prefix_turn_budget_exhausted = "turn_budget_exhausted"

(* SSOT for the two retry-recoverable transient wire codes inside the
   [api_error_*] / [Provider_runtime_failure] family. These are the wire
   forms of exactly the [Agent_sdk.Error] variants that
   [Keeper_error_classify.is_transient_network_error] reports as transient:
   a plain (non-structural) [Api.Timeout] and an [Api.NetworkError]. The
   producer [Keeper_agent_error.api_error_terminal_reason_code] builds the
   same strings; it references these constants so encoder and the
   consumer-side classifier cannot drift.

   NOTE the structural OAS budget timeout is a DISTINCT producer wire code
   ([api_error_oas_agent_execution_timeout]) and is intentionally NOT in
   this set — it carries the [(budget=...)] message that
   [is_transient_network_error] treats as non-transient, so it must still
   page a human. *)
let wire_api_error_timeout = "api_error_timeout"
let wire_api_error_network = "api_error_network"

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
  | Turn_budget_exhausted of string
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
    || String.starts_with ~prefix:"provider_error_" lowered
  then Provider_runtime_failure wire
  else if String.starts_with ~prefix:"completion_contract_violation:" lowered
  then Completion_contract_violation wire
  else if String.starts_with ~prefix:"turn_livelock:" lowered
  then Turn_livelock wire
  else if String.equal lowered "internal_error"
  then Internal_error wire
  else if String.starts_with ~prefix:terminal_prefix_turn_budget_exhausted lowered
  then Turn_budget_exhausted wire
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
  | Turn_budget_exhausted wire -> wire
  | Auto_recoverable_budget wire -> wire
  | Pre_dispatch_success wire -> wire
  | Other wire -> wire
;;

(* A [Provider_runtime_failure] whose underlying error is a retry-recoverable
   transient (idle-chunk liveness kill wrapped as [Api.Timeout], or a
   transient [Api.NetworkError]). The keeper's in-turn retry typically
   self-heals these on the next attempt, so the disposition classifier must
   advance to the next runtime/model rather than page a human.

   Matched by EXACT equality against the two transient wire constants (on a
   lowercased copy, mirroring [of_wire]). Exact — not prefix — equality is
   load-bearing: it excludes the structural OAS budget timeout
   [api_error_oas_agent_execution_timeout] (also [Provider_runtime_failure],
   but non-transient) and every other [api_error_*] code (rate_limited,
   overloaded, server:*, context_overflow, …), all of which must still pause.
   Only [Provider_runtime_failure] is inspected; all other variants are
   [false]. *)
let is_transient_provider_runtime_failure = function
  | Provider_runtime_failure wire ->
    let lowered = String.lowercase_ascii wire in
    String.equal lowered wire_api_error_timeout
    || String.equal lowered wire_api_error_network
    || String.equal lowered "provider_error_timeout"
    || String.starts_with ~prefix:"provider_error_timeout:" lowered
    || String.equal lowered "provider_error_network:timeout"
    || String.starts_with ~prefix:"provider_error_network:timeout:" lowered
  | Runtime_exhausted _
  | Config_or_auth _
  | Completion_contract_violation _
  | Turn_livelock _
  | Internal_error _
  | Turn_budget_exhausted _
  | Auto_recoverable_budget _
  | Pre_dispatch_success _
  | Other _ -> false
;;
