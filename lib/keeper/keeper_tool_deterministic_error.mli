(** Keeper_tool_deterministic_error — classify a keeper tool's failure
    payload as deterministic (replaying with the same arguments will
    fail the same way) versus unclassified (transient errors and shell
    exit-nonzero results stay outside this surface).

    Use in [Keeper_tools_oas] failure branch to short-circuit the
    per-tool consecutive-failure counter at the first attempt. Counters
    still exist for transient errors; only deterministic policy/shape
    blocks bypass the 1/3 -> 2/3 -> 3/3 emit cycle.

    Background — MASC/OAS Error-Warn Reduction Goal 2026-05-18, P2
    reducer ("Stop retry loops for blocked command shapes"). Three
    Execute invocations with identical args and identical error payloads
    were generating duplicate ERROR log lines at 1/3, 2/3 and 3/3. The
    retry itself is driven by the LLM re-issuing the same tool call after
    seeing an error — the dedicated retry envelope
    (Agent_sdk.Tool_retry_policy) is configured with
    retry_on_recoverable_tool_error=false, so this module covers the
    LLM-driven retry loop specifically. *)

(** Closed enumeration of deterministic error reasons. Adding a new
    variant requires updating both [classify] (input -> variant) and
    [to_string] (variant -> stable telemetry label). Exhaustive match
    is enforced by [-strict-sequence] in the [dune] config. *)
type deterministic_reason =
  | Command_blocked
      (** Execute/search policy block with a structured recovery_plan. *)
  | Command_shape_blocked
      (** Execute policy block: pipes, redirects, chaining, substitution,
          repo-wide scans, gh pr checks. *)
  | Task_state_probe_blocked
      (** raw shell attempted to inspect task state files or guessed task APIs. *)
  | Destructive_operation_blocked
      (** force push / rm -rf / push to main detected. *)
  | Path_outside_sandbox
      (** path argument resolves outside the keeper's allowed roots. *)
  | Cwd_not_directory
      (** cwd argument resolves but is not a directory. *)
  | Policy_blocked
      (** governance / candidate policy rejected the call. *)
  | Write_operation_gated
      (** write-capable Execute is required before retrying the same operation. *)
  | Completion_contract_violation
      (** keeper completion contract failed. *)
  | Structured_tool_payload
      (** Raw shell rejected because a structured allowed tool/native workflow should carry the payload. *)
  | Workflow_rejection_blocked
      (** typed workflow_rejection failure class — handled by a
          separate counter in [Keeper_tools_oas]. It is considered
          deterministic only when the payload explicitly carries
          [error_class="deterministic"] and [recoverable=false]. *)
  | Path_not_found
      (** A typed Execute path argument does not exist on the local
          filesystem. Emitted by pre-dispatch validation for [Safe]
          risk commands (ls, cat, find, rg, etc.) where path
          non-existence is a predictable pre-condition failure.
          The LLM should probe the parent directory before retrying. *)

type classification_source =
  | Deterministic_retry_marker
      (** Producer emitted the explicit [deterministic_retry] contract. *)
  | Workflow_rejection_marker
      (** Workflow rejection carried deterministic/unrecoverable typed fields. *)
  | Path_check_marker
      (** Path-check surface carried a closed typed reason. *)

type classification =
  { reason : deterministic_reason
  ; source : classification_source
  }

type raw_payload_parse_error = Raw_payload_malformed_json of string

(** Classify a raw tool-result JSON payload (as returned by
    [Keeper_tool_dispatch_runtime]) into a [deterministic_reason] only when the
    payload carries an explicit typed marker: [deterministic_retry],
    deterministic workflow-rejection fields, a typed path-check
    reason. Returns
    [None] for transient errors, shell exit-nonzero, retryability-only
    payloads, plain [error] strings, network/timeout failures, and
    any payload that fails to parse.

    There is no [error] string fallback and no [_ ->] catch-all that
    admits new prefixes silently. Producers that know same-argument
    retry cannot succeed must emit [deterministic_retry_fields]. Plain
    git process failures intentionally stay outside this deterministic
    surface so sandbox/worktree recovery can adapt with different refs,
    paths, or branch names. *)
val classify : Yojson.Safe.t -> deterministic_reason option

val classify_with_source : Yojson.Safe.t -> classification option

(** Structured marker for tool producers that already know the same
    arguments cannot succeed. The classifier only accepts this marker
    when [retry_same_args=false] is present, so producers must state
    the retry boundary explicitly. Prefer this over adding more
    [error] string fallbacks. *)
val deterministic_retry_fields : deterministic_reason -> (string * Yojson.Safe.t) list

(** Parse [raw] as JSON then [classify], preserving malformed JSON as a typed
    parse error instead of conflating it with an unclassified valid payload. *)
val classify_raw_result :
  string -> (deterministic_reason option, raw_payload_parse_error) result

val classify_raw_with_source_result :
  string -> (classification option, raw_payload_parse_error) result

(** Compatibility wrapper around {!classify_raw_result}. Returns [None] for
    both malformed JSON and valid-but-unclassified payloads. New code that needs
    to distinguish those cases should use {!classify_raw_result}. *)
val classify_raw : string -> deterministic_reason option

val classify_raw_with_source : string -> classification option

val raw_payload_parse_error_to_string : raw_payload_parse_error -> string

(** Stable lowercase identifier used for telemetry / log labels.
    Format: [deterministic_error_<reason>]. *)
val to_telemetry_key : deterministic_reason -> string

val classification_source_to_string : classification_source -> string

(** Human-readable summary suitable for short error log lines. *)
val to_string : deterministic_reason -> string
