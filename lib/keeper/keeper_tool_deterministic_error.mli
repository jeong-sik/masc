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
    keeper_bash invocations with identical args and identical error
    payloads were generating duplicate ERROR log lines at 1/3, 2/3 and
    3/3. The retry itself is driven by the LLM re-issuing the same
    tool call after seeing an error — the dedicated retry envelope
    (Agent_sdk.Tool_retry_policy) is configured with
    retry_on_recoverable_tool_error=false, so this module covers the
    LLM-driven retry loop specifically. *)

(** Closed enumeration of deterministic error reasons. Adding a new
    variant requires updating both [classify] (input -> variant) and
    [to_string] (variant -> stable telemetry label). Exhaustive match
    is enforced by [-strict-sequence] in the [dune] config. *)
type deterministic_reason =
  | Command_blocked
      (** keeper_bash/keeper_shell policy block with a structured
          recovery_plan. *)
  | Command_shape_blocked
      (** keeper_bash policy block: pipes, redirects, chaining,
          substitution, repo-wide scans, gh pr checks. *)
  | Task_state_probe_blocked
      (** raw shell attempted to inspect task state files or guessed task APIs. *)
  | Destructive_operation_blocked
      (** force push / rm -rf / push to main detected. *)
  | Path_syntax_blocked
      (** path argument fails syntax check before execution. *)
  | Path_outside_sandbox
      (** path argument resolves outside the keeper's allowed roots. *)
  | Cwd_not_directory
      (** cwd argument resolves but is not a directory. *)
  | Policy_blocked
      (** governance / preset policy rejected the call. *)
  | Completion_contract_violation
      (** keeper completion contract (e.g. require_tool_use) failed. *)
  | Keeper_shell_op_required
      (** raw keeper_bash rejected; caller must use keeper_shell op=*. *)
  | Workflow_rejection_blocked
      (** typed workflow_rejection failure class — handled by a
          separate counter in [Keeper_tools_oas], but still considered
          deterministic so retry-skipped telemetry can be emitted. *)

(** Classify a raw tool-result JSON payload (as returned by
    [Keeper_exec_tools]) into a [deterministic_reason] when the
    error field matches a known closed set of policy/shape block
    codes. Returns [None] for transient errors, shell exit-nonzero,
    network/timeout failures, and any payload that fails to parse.

    Inputs are validated against a typed allow-list of [error] field
    values plus the orthogonal [failure_class:"workflow_rejection"]
    marker — no substring matching, no [_ ->] catch-all that admits
    new prefixes silently. *)
val classify : Yojson.Safe.t -> deterministic_reason option

(** Convenience wrapper: parse [raw] as JSON then [classify]. Returns
    [None] when [raw] is not valid JSON. *)
val classify_raw : string -> deterministic_reason option

(** Stable lowercase identifier used for telemetry / log labels.
    Format: [deterministic_error_<reason>]. *)
val to_telemetry_key : deterministic_reason -> string

(** Human-readable summary suitable for short error log lines. *)
val to_string : deterministic_reason -> string
