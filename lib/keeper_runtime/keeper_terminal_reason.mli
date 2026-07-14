(** RFC-0042 PR-4: closed sum for the keeper-side classification of a
    receipt's [terminal_reason_code] string.

    {1 Why a third terminal-reason type}

    Two typed terminal-reason modules already exist:

    - [Keeper_turn_terminal_code] (RFC-0042 PR-1/PR-2.5) is the
      {e producer-side} bridge from [Keeper_registry.failure_reason] /
      [Agent_sdk.Error.sdk_error]. Its [of_wire] returns [None] for the
      SDK-error codes ([api_error_*], agent observation wires, [internal_error]) because
      they are all collapsed into its [Sdk_error of string] blob — the
      sub-sum RFC-0042 §5.2 explicitly defers. Matching on [Sdk_error s]
      would force the substring re-parse back into the open, so it cannot
      be the consumer's parse target.
    - [Keeper_turn_disposition] (RFC-0047) is the operator-facing layer;
      its [of_termination_code] routes through the same producer collapse
      and produces a different output type.

    This module is the missing {e consumer-side} parse target that
    RFC-0042 PR-4 calls for: it parses [receipt.terminal_reason_code]
    {e once} into the exact distinctions [Keeper_execution_receipt.operator_disposition]
    branches on, so that classifier becomes an exhaustive [match] instead
    of a chain of [String.starts_with] / [string_contains] tests.

    {1 Partition discipline}

    [of_wire] is a {e priority-ranked partition}: it tests the buckets in
    the same order the old [operator_disposition] [if/else] chain tested
    its string predicates, plus the exact canonical
    [Capacity_backpressure] policy bucket, and returns the first match.
    Only canonical producer wire forms select specialized buckets. The order
    remains load-bearing for canonical overlaps; see the [.ml] for the ranked
    list.

    The escape arm [Unknown] is a {e named} typed escape for unmatched or
    non-canonical codes. Callers route it explicitly to the generic path.

    {1 Wire byte-preservation}

    [terminal_reason_code] is serialised verbatim into receipt JSON and
    read + classified by dashboards. The receipt's JSON emission is
    {b unchanged} — this module is used only inside the keeper-side
    disposition classifier. [of_wire] carries the original string in every
    variant, so [to_wire (of_wire s) = s] holds byte-for-byte. *)

type t =
  | Runtime_exhausted of string
  (** Exact wire ["runtime_exhausted"]. Payload is the
          original string, carried only so [to_wire] is a byte-identical
          inverse; the disposition classifier ignores it. *)
  | Capacity_backpressure of string
  (** Exact canonical wire kind
          {!Keeper_internal_error.capacity_backpressure_kind}.  This is a
          typed provider/infrastructure retry observation, not an opaque
          internal failure.  Payload preserves the original bytes. *)
  | Config_or_auth of string
  (** Canonical configuration/authentication wires emitted by the typed SDK
          error encoder. Arbitrary strings containing ["config"] or ["auth"]
          are not classified here. Payload is the original string. *)
  | Provider_runtime_failure of string
  (** Wire [String.starts_with ~prefix:"api_error_"], exact
          ["provider_error"], or
          [String.starts_with ~prefix:"provider_error_"]. Config/auth-like
          provider codes still land in [Config_or_auth] because that bucket
          is ranked earlier. Payload is the original string. *)
  | Internal_error of string
  (** Exact wire ["internal_error"]. Payload is the original
          string, carried only for [to_wire] round-trip fidelity. *)
  | Pre_dispatch_success of string
  (** Exact wire ["pre_dispatch_success"]: a turn that
          completed without dispatching to a provider. Payload is the
          original string, carried only for [to_wire] round-trip fidelity. *)
  | Unknown of string
  (** Named typed escape for any wire string none of the canonical buckets
          matched. The disposition classifier routes it through the generic
          unknown path; its prose never selects a specialized route. Payload
          is the original string. *)

(** Parse a [terminal_reason_code] wire string into the typed
    classification. Priority-ranked partition (see module doc); returns
    the first matching bucket. Total — every string maps to exactly one
    variant, with [Unknown] as the explicit escape. The argument is the
    raw wire string. Classification accepts canonical producer bytes only;
    non-canonical casing remains [Unknown]. *)
val of_wire : string -> t

(** Reconstruct the exact wire string [of_wire] parsed. Byte-identical
    inverse: [to_wire (of_wire s) = s] for every [s]. *)
val to_wire : t -> string

(** {1 Transient provider-runtime wire codes (SSOT)}

    Retry-recoverable transient wire codes inside the
    [Provider_runtime_failure] family: a plain (non-structural)
    [Api.Timeout], [Api.NetworkError], and provider-level timeout markers
    such as ["provider_error_timeout:http_operation"]. These mirror the
    [Agent_sdk.Error] variants
    [Keeper_error_classify.is_transient_network_error] reports as transient.
    The encoder [Keeper_agent_error.api_error_terminal_reason_code]
    references these so producer and consumer cannot drift.

    Agent execution observations do not enter this API/provider wire family. *)
val wire_api_error_timeout : string

val wire_api_error_network : string

(** [true] when [t] is a [Provider_runtime_failure] carrying one of the
    transient wire codes ([wire_api_error_timeout] / [wire_api_error_network])
    or a provider timeout marker. The API timeout matches remain exact, so
    every other [api_error_*] code returns [false]. Every
    non-[Provider_runtime_failure] variant is [false].
    The disposition classifier routes a [true] result to a runtime-advance
    disposition instead of [Disp_pause_human]. *)
val is_transient_provider_runtime_failure : t -> bool
