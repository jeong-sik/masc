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
   forms of exactly the [Agent_sdk.Error] variants that
   [Keeper_error_classify.is_transient_network_error] reports as transient:
   a plain (non-structural) [Api.Timeout] and an [Api.NetworkError]. The
   producer [Keeper_agent_error.api_error_terminal_reason_code] builds the
   same strings; it references these constants so encoder and the
   consumer-side classifier cannot drift.

   Agent execution observations never enter this API-error wire family. *)
let wire_api_error_timeout = "api_error_timeout"
let wire_api_error_network = "api_error_network"

type t =
  | Runtime_exhausted of string
  | Capacity_backpressure of string
  | Config_or_auth of string
  | Provider_runtime_failure of string
  | Internal_error of string
  | Pre_dispatch_success of string
  | Unknown of string

let is_config_or_auth_wire = function
  | "config_error"
  | "api_error_auth"
  | "api_error_authorization"
  | "provider_error_auth"
  | "provider_error_authorization" -> true
  | wire -> String.starts_with ~prefix:"provider_error_invalid_config:" wire
;;

(* Priority-ranked partition. The bucket order replicates the [if/else]
   order of the pre-typing [operator_disposition] string predicates, with the
   exact canonical [Capacity_backpressure] policy bucket inserted before the
   opaque internal-error fall-through;
   [of_wire] returns the FIRST matching bucket. Capacity backpressure is an
   exact producer-owned wire kind; casing variants remain opaque rather than
   inheriting its non-pageable policy. The original
   [wire] is carried in payload-bearing variants so
   [to_wire] reproduces it byte-for-byte; classification is done on a
   canonical wire byte sequence only. Unknown or non-canonical spellings stay typed
   [Unknown] and take the generic disposition route. *)
let of_wire wire =
  if String.equal wire "runtime_exhausted"
  then Runtime_exhausted wire
  else if String.equal wire Keeper_internal_error.capacity_backpressure_kind
  then Capacity_backpressure wire
  else if is_config_or_auth_wire wire
  then Config_or_auth wire
  else if
    String.starts_with ~prefix:"api_error_" wire
    || String.equal wire "provider_error"
    || String.starts_with ~prefix:"provider_error_" wire
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
    || String.equal wire "provider_error_timeout"
    || String.starts_with ~prefix:"provider_error_timeout:" wire
    || String.equal wire "provider_error_network:timeout"
    || String.starts_with ~prefix:"provider_error_network:timeout:" wire
  | Runtime_exhausted _
  | Capacity_backpressure _
  | Config_or_auth _
  | Internal_error _
  | Pre_dispatch_success _
  | Unknown _ -> false
;;
