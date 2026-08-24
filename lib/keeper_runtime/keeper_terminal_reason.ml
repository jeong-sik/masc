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

(* SSOT for the two retry-recoverable transient wire codes inside the
   [api_error_*] / [Provider_runtime_failure] family. These are the wire
   forms of exactly the [Agent_core.Error] variants that
   [Keeper_error_classify.is_transient_network_error] reports as transient:
   a plain (non-structural) [Api.Timeout] and an [Api.NetworkError]. The
   producer [Keeper_agent_error.api_error_terminal_reason_code] builds the
   same strings; it references these constants so encoder and the
   consumer-side classifier cannot drift.

   Agent execution observations never enter this API-error wire family. *)
let wire_api_error_timeout = "api_error_timeout"
let wire_api_error_network = "api_error_network"

(* The [provider_error_*] family. Producer and classifier used to spell these
   at fifteen call sites across three modules with nothing tying them
   together, so a renamed code changed what the classifier saw without
   changing what it matched (#26584). Only the codes both sides name are here;
   the producer-only ones reach the classifier through
   [wire_provider_error_prefix] and do not drift individually.

   The frozen copies in test_keeper_terminal_reason_typed are deliberate: they
   are the pre-typing reference the typed classifier is checked against, so
   they must stay independent of these constants. *)
let wire_provider_error_prefix = "provider_error_"
let wire_provider_error_auth = "provider_error_auth"
let wire_provider_error_authorization = "provider_error_authorization"
let wire_provider_error_invalid_config_prefix = "provider_error_invalid_config:"
let wire_provider_error_timeout = "provider_error_timeout"
let wire_provider_error_timeout_prefix = "provider_error_timeout:"
let wire_provider_error_network_timeout = "provider_error_network:timeout"
let wire_provider_error_network_timeout_prefix = "provider_error_network:timeout:"

type t =
  | Runtime_exhausted of string
  | Capacity_backpressure of string
  | Config_or_auth of string
  | Provider_runtime_failure of string
  | Transcript_corruption of string
  | Provider_attempt_effect_fenced of string
  | Tool_correction_lost of string
  | Accept_rejected of string
  | Terminal_effect_failed of string
  | Internal_error of string
  | Pre_dispatch_success of string
  | Unknown of string

let is_config_or_auth_wire wire =
  match wire with
  | "config_error" | "api_error_auth" | "api_error_authorization" -> true
  | _ ->
    String.equal wire wire_provider_error_auth
    || String.equal wire wire_provider_error_authorization
    || String.starts_with ~prefix:wire_provider_error_invalid_config_prefix wire
;;

(* The keeper's own internal-error family, classified from the producer's
   typed enumeration instead of from its printed form. Previously five of
   these thirteen were recognised by [String.equal] against four exported
   constants and the rest fell to [Unknown], which is how a keeper's named
   failure reached the operator as "unmapped runtime state" (#29929).

   Three kinds get no policy here on purpose. [Resumable_cli_session],
   [Receipt_persistence_failed] and [Gate_replay_repair_required] have never
   been observed — zero rows across 189 receipt files and every August log —
   so there is no trace to classify them from, and naming a disposition from
   the constructor name alone would be a guess dressed as a decision. They
   stay [Unknown], which is what they do today; the difference is that the
   match now names them, so the next author sees the open question instead of
   an absent arm. *)
let of_masc_internal_kind wire = function
  | Keeper_internal_error.Wire_runtime_exhausted -> Runtime_exhausted wire
  | Keeper_internal_error.Wire_capacity_backpressure -> Capacity_backpressure wire
  | Keeper_internal_error.Wire_incomplete_tool_transcript -> Transcript_corruption wire
  | Keeper_internal_error.Wire_provider_attempt_effect_fenced ->
    Provider_attempt_effect_fenced wire
  | Keeper_internal_error.Wire_tool_correction_lost -> Tool_correction_lost wire
  | Keeper_internal_error.Wire_accept_rejected -> Accept_rejected wire
  | Keeper_internal_error.Wire_terminal_effect_failed -> Terminal_effect_failed wire
  | Keeper_internal_error.Wire_internal_unhandled_exception
  | Keeper_internal_error.Wire_internal_bridge_exception
  | Keeper_internal_error.Wire_internal_contract_rejected ->
    (* One route, so one bucket. [Keeper_runtime_failure_route] answers
       [Internal_opaque] / [Exhausted_visible_alive] for all three, the same
       answer it gives the bare ["internal_error"] wire that an internal
       error without an envelope produces. The wire string stays verbatim in
       the receipt, so counting them apart never needed separate variants. *)
    Internal_error wire
  | Keeper_internal_error.Wire_resumable_cli_session
  | Keeper_internal_error.Wire_receipt_persistence_failed
  | Keeper_internal_error.Wire_gate_replay_repair_required -> Unknown wire
;;

(* Two stages. The keeper's own internal-error kinds are looked up in the
   producer's enumeration first; whatever that does not claim falls to the
   prefix tests for the agent-core and provider wire families, which are
   priority-ranked and return the FIRST match, replicating the [if/else]
   order of the pre-typing [operator_disposition] string predicates.

   Putting the exact lookup first is not a reordering: no internal-error kind
   equals or prefixes any config/auth or provider wire, so both stages see
   the same inputs they saw before. Casing variants of a kind still miss the
   lookup and stay opaque rather than inheriting its policy. The original
   [wire] is carried in every payload-bearing variant so [to_wire] reproduces
   it byte-for-byte; classification reads a canonical byte sequence only.
   Spellings neither stage claims stay typed [Unknown] and take the generic
   disposition route. *)
let of_wire wire =
  match Keeper_internal_error.wire_kind_of_string wire with
  | Some kind -> of_masc_internal_kind wire kind
  | None ->
    if is_config_or_auth_wire wire
    then Config_or_auth wire
    else if
      String.starts_with ~prefix:"api_error_" wire
      || String.equal wire "provider_error"
      || String.starts_with ~prefix:wire_provider_error_prefix wire
    then Provider_runtime_failure wire
    else if String.equal wire "internal_error"
    then Internal_error wire
    else if String.equal wire "pre_dispatch_success"
    then Pre_dispatch_success wire
    else Unknown wire
;;

(* Byte-identical inverse: every variant carries the original wire string,
   so [to_wire (of_wire s) = s] holds for every [s] including mixed-case
   inputs. The exact-match variants carry a payload only for this
   round-trip fidelity; [operator_disposition] ignores it. *)
let to_wire = function
  | Runtime_exhausted wire -> wire
  | Capacity_backpressure wire -> wire
  | Config_or_auth wire -> wire
  | Provider_runtime_failure wire -> wire
  | Transcript_corruption wire -> wire
  | Provider_attempt_effect_fenced wire -> wire
  | Tool_correction_lost wire -> wire
  | Accept_rejected wire -> wire
  | Terminal_effect_failed wire -> wire
  | Internal_error wire -> wire
  | Pre_dispatch_success wire -> wire
  | Unknown wire -> wire
;;

(* A [Provider_runtime_failure] whose underlying error is a retry-recoverable
   transient (idle-chunk liveness kill wrapped as [Api.Timeout], or a
   transient [Api.NetworkError]). The keeper's in-turn retry typically
   self-heals these on the next attempt, so the disposition classifier must
   advance to the next runtime/model rather than page a human.

   Matched by exact equality against the two transient wire constants. This
   excludes every other [api_error_*] code (rate_limited, overloaded, server:*,
   context_overflow, …), all of which remain generic provider failures.
   Only [Provider_runtime_failure] is inspected; all other variants are
   [false]. *)
let is_transient_provider_runtime_failure = function
  | Provider_runtime_failure wire ->
    String.equal wire wire_api_error_timeout
    || String.equal wire wire_api_error_network
    || String.equal wire wire_provider_error_timeout
    || String.starts_with ~prefix:wire_provider_error_timeout_prefix wire
    || String.equal wire wire_provider_error_network_timeout
    || String.starts_with ~prefix:wire_provider_error_network_timeout_prefix wire
  | Runtime_exhausted _
  | Capacity_backpressure _
  | Config_or_auth _
  | Transcript_corruption _
  | Provider_attempt_effect_fenced _
  | Tool_correction_lost _
  | Accept_rejected _
  | Terminal_effect_failed _
  | Internal_error _
  | Pre_dispatch_success _
  | Unknown _ -> false
;;
