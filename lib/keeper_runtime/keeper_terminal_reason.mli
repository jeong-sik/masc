(** RFC-0042 PR-4: closed sum for the keeper-side classification of a
    receipt's [terminal_reason_code] string.

    {1 Why a third terminal-reason type}

    Two typed terminal-reason modules already exist:

    - [Keeper_turn_terminal_code] (RFC-0042 PR-1/PR-2.5) is the
      {e producer-side} bridge from [Keeper_registry.failure_reason] /
      [Agent_sdk.Error.sdk_error]. Its [of_wire] returns [None] for the
      SDK-error codes ([api_error_*], [completion_contract_violation:*],
      [turn_livelock:*], the budget prefixes, [internal_error]) because
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
    Pathological overlaps (a contract
    id containing ["auth"], a budget string that also matches a later
    bucket) resolve identically to the pre-typing code. The order is
    load-bearing; see the [.ml] for the ranked list.

    The escape arm [Other] is a {e named} typed escape for genuinely
    unmatched legacy codes, not a permissive default: callers route it
    explicitly to the same generic tool-gate logic the old code's
    fall-through used.

    {1 Wire byte-preservation}

    [terminal_reason_code] is serialised verbatim into receipt JSON and
    read + classified by dashboards. The receipt's JSON emission is
    {b unchanged} — this module is used only inside the keeper-side
    disposition classifier. [of_wire] lowercases internally for
    classification but carries the {e original} (case-preserving) string
    in every payload-bearing variant, so [to_wire (of_wire s) = s] holds
    byte-for-byte. *)

type t =
  | Runtime_exhausted of string
  (** Exact wire ["runtime_exhausted"] (modulo case). Payload is the
          original string, carried only so [to_wire] is a byte-identical
          inverse; the disposition classifier ignores it. *)
  | Capacity_backpressure of string
  (** Exact canonical wire kind
          {!Keeper_internal_error.capacity_backpressure_kind}.  This is a
          typed provider/infrastructure pacing condition, not an opaque
          internal failure.  Payload preserves the original bytes. *)
  | Config_or_auth of string
  (** Wire string contains ["config"] or ["auth"] (case-insensitive).
          Ranked above the provider family so [api_error_auth],
          [provider_error_auth:*], [provider_error_invalid_config:*], and
          [config_error] land here — matching the pre-typing preflight
          branch which was checked before the provider prefixes. Payload is
          the original string. *)
  | Provider_runtime_failure of string
  (** Wire [String.starts_with ~prefix:"api_error_"], exact
          ["provider_error"], or
          [String.starts_with ~prefix:"provider_error_"]. Config/auth-like
          provider codes still land in [Config_or_auth] because that bucket
          is ranked earlier. Payload is the original string. *)
  | Completion_contract_violation of string
  (** Wire [String.starts_with ~prefix:"completion_contract_violation:"],
          including the extended [:called[..]:satisfying[..]] form. Payload
          is the original string. *)
  | Turn_livelock of string
  (** Wire [String.starts_with ~prefix:"turn_livelock:"]. Payload is the
          original string. *)
  | Internal_error of string
  (** Exact wire ["internal_error"] (modulo case). Payload is the original
          string, carried only for [to_wire] round-trip fidelity. *)
  | Turn_budget_exhausted of string
  (** Wire [String.starts_with ~prefix:"turn_budget_exhausted"], emitted from
          [Runtime_agent.TurnBudgetExhausted]. Unlike
          [Auto_recoverable_budget], this is a completed runtime stop reason,
          so the receipt classifier must inspect completion-contract evidence
          before deciding whether it is safe to pass. Payload is the original
          string. *)
  | Auto_recoverable_budget of string
  (** Wire matches one of the turn/time-budget cut-off prefixes
          ([agent_error_max_turns_exceeded] / [agent_error_execution_timeout]
          / [agent_error_idle_timeout]): the turn was cut off before a
          verdict and the supervisor auto-resumes from its checkpoint.
          Payload is the original string. *)
  | Pre_dispatch_success of string
  (** Exact wire ["pre_dispatch_success"] (modulo case): a turn that
          completed without dispatching to a provider. Payload is the
          original string, carried only for [to_wire] round-trip fidelity. *)
  | Other of string
  (** Named typed escape for any wire string none of the above buckets
          matched (e.g. [provider_error_server:500],
          [mcp_error], [registry_phase_missing], [supervisor_stop]). NOT a
          permissive default: the disposition classifier routes it to the
          same generic tool-gate logic the pre-typing fall-through used.
          Payload is the original string. *)

(** Parse a [terminal_reason_code] wire string into the typed
    classification. Priority-ranked partition (see module doc); returns
    the first matching bucket. Total — every string maps to exactly one
    variant, with [Other] as the explicit escape. The argument is the
    raw (case-preserving) wire string; classification is case-insensitive
    but the original bytes are retained in payload-bearing variants. *)
val of_wire : string -> t

(** Reconstruct the exact wire string [of_wire] parsed. Byte-identical
    inverse: [to_wire (of_wire s) = s] for every [s]. *)
val to_wire : t -> string

(** {1 Turn/time-budget cut-off prefixes (SSOT)}

    Wire prefixes for OAS agent-execution errors that exhaust a turn/time
    budget before the turn completes. The encoder
    [Keeper_agent_error.agent_error_terminal_reason_code] builds the wire
    strings from these constants, and the classifier matches on them via
    the [Auto_recoverable_budget] bucket. Owned here so the typed parser
    and the producer share one source. [Keeper_execution_receipt]
    re-exports these for backward compatibility. *)
val terminal_prefix_max_turns_exceeded : string

val terminal_prefix_execution_timeout : string
val terminal_prefix_idle_timeout : string
val terminal_prefix_turn_budget_exhausted : string
(** Wire prefix emitted for [Runtime_agent.TurnBudgetExhausted]. This is not
    part of [is_auto_recoverable_turn_budget_terminal]: it is a completed
    runtime stop reason, so receipt classification must inspect completion
    contract evidence before deciding pass vs attention. *)

(** {1 Transient provider-runtime wire codes (SSOT)}

    Retry-recoverable transient wire codes inside the
    [Provider_runtime_failure] family: a plain (non-structural)
    [Api.Timeout], [Api.NetworkError], and provider-level timeout markers
    such as ["provider_error_timeout:http_operation"]. These mirror the
    [Agent_sdk.Error] variants
    [Keeper_error_classify.is_transient_network_error] reports as transient.
    The encoder [Keeper_agent_error.api_error_terminal_reason_code]
    references these so producer and consumer cannot drift.

    The structural OAS budget timeout is a distinct producer code
    ([api_error_oas_agent_execution_timeout]) and is deliberately excluded —
    it is non-transient and must still page a human. *)
val wire_api_error_timeout : string

val wire_api_error_network : string

(** [true] when [t] is a [Provider_runtime_failure] carrying one of the
    transient wire codes ([wire_api_error_timeout] / [wire_api_error_network])
    or a provider timeout marker. The API timeout matches remain exact, so
    [api_error_oas_agent_execution_timeout] and every other [api_error_*] code
    return [false]. Every non-[Provider_runtime_failure] variant is [false].
    The disposition classifier routes a [true] result to a runtime-advance
    disposition instead of [Disp_pause_human]. *)
val is_transient_provider_runtime_failure : t -> bool

(** [true] when [terminal_reason] (assumed already lowercased by the
    caller, as [operator_disposition] does) is a turn/time-budget cut-off:
    auto-recoverable, the keeper resumes from its checkpoint, so it must
    NOT be classified as a completion-contract failure. Equivalent to
    [of_wire s] returning [Auto_recoverable_budget _]. *)
val is_auto_recoverable_turn_budget_terminal : string -> bool
