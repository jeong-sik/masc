(** In-process counters for the Legendary Bash observers that are still live.

    The legacy-vs-AST gate diff observer was removed; this module now tracks
    auto-background observation, gh exit classification, typed-advisor parity,
    and Shell_command_gate caller partitioning.

    All counters are [Atomic.t] and safe to increment from any fiber or
    domain. The module is a pure sidecar to the log-line stream: flipping
    observers on produces both structured logs and in-memory totals for
    dashboards / HTTP snapshot endpoints. *)

val incr_auto_bg_observed : promoted_candidate:bool -> unit
(** Record one P4 foreground-only call that the observer inspected.
    When [promoted_candidate] is [true] the elapsed duration would
    have tripped [MASC_BLOCKING_BUDGET_MS]. *)

val incr_gh_exit_class : Gh_exit_class.t -> unit
(** Record one docker-sandbox gh invocation under its exit class, as
    classified by {!Gh_exit_class.classify}. Callers increment this
    from the docker shell emission sites in [Keeper_shell_docker] so
    dashboards can visualise the distribution of gh outcomes
    (Ok_0 vs Auth_failed vs Network vs ...) without parsing stderr
    blobs in the UI layer. *)

val incr_typed_advisor : Shell_ir_validator.advisory -> unit
(** RFC-0092 Phase A — record one typed-advisor outcome under its
    bucket ([typed_advisor_allow] / [typed_advisor_reject] /
    [typed_advisor_cannot_parse]). Exhaustive over
    [Shell_ir_validator.advisory]; a new variant in the validator
    forces an update here at compile time. Increment only while
    [Gate_diff_types.typed_advisor_log_enabled ()] is true so an
    operator running with the flag off pays zero cost. *)

(** RFC-0131 — caller × verdict telemetry partition for the exec
    shell command gate.

    Mirrors the [caller] tag defined in
    {!Masc_exec_command_gate.Shell_command_gate.caller}.  Callers that
    produce an exec gate verdict increment this counter at their boundary
    so production telemetry follows the actual authoritative path rather
    than the retired legacy authority-flip shim. *)
type shell_gate_caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

type shell_gate_verdict_kind =
  | Allow
  | Reject
  | Cannot_parse

val incr_shell_gate
  :  caller:shell_gate_caller
  -> verdict:shell_gate_verdict_kind
  -> unit
(** Record one shell_command_gate verdict under the given
    [caller × verdict] bucket. Exhaustive over both sums; adding a
    new caller or verdict variant forces an update here at compile
    time. *)

val reset : unit -> unit
(** Zero every counter. Used by tests; operators should not rely on
    this surface. *)

type snapshot = {
  auto_bg_observed : int;
  auto_bg_would_have_promoted : int;
  (* Distribution of docker-sandbox gh invocations by exit class, as
     classified by {!Gh_exit_class.classify}. *)
  gh_exit_ok_0 : int;
  gh_exit_policy_blocked : int;
  gh_exit_type_mismatch : int;
  gh_exit_auth_failed : int;
  gh_exit_network : int;
  gh_exit_unknown : int;
  (* RFC-0092 Phase A typed-advisor parity counters. Increment only
     while [Gate_diff_types.typed_advisor_log_enabled ()] is true. *)
  typed_advisor_allow : int;
  typed_advisor_reject : int;
  typed_advisor_cannot_parse : int;
  (* RFC-0131 — caller × verdict partition for the exec shell command
     gate.  3 callers × 3 verdicts = 9
     buckets.  Field order matches [shell_gate_caller × shell_gate_verdict_kind]
     row-major.  See {!incr_shell_gate} for the increment surface. *)
  shell_gate_worker_dev_tools_allow : int;
  shell_gate_worker_dev_tools_reject : int;
  shell_gate_worker_dev_tools_cannot_parse : int;
  shell_gate_tool_code_write_allow : int;
  shell_gate_tool_code_write_reject : int;
  shell_gate_tool_code_write_cannot_parse : int;
  shell_gate_keeper_shell_bash_allow : int;
  shell_gate_keeper_shell_bash_reject : int;
  shell_gate_keeper_shell_bash_cannot_parse : int;
}

val snapshot : unit -> snapshot

val snapshot_to_json : snapshot -> Yojson.Safe.t
(** Stable JSON shape for dashboard / HTTP consumers. Field names
    mirror the record labels exactly. *)

(** {2 Derived ratios} *)

val auto_bg_promotion_rate : snapshot -> float
(** [auto_bg_would_have_promoted / auto_bg_observed].

    Fraction of P4 observed foreground calls that exceeded
    [MASC_BLOCKING_BUDGET_MS]. Guides both the
    [MASC_BLOCKING_BUDGET_MS] tuning and the [MASC_BASH_AUTO_BG]
    default-flip decision. Returns [0.0] when the denominator is zero. *)

val snapshot_to_json_with_ratios : snapshot -> Yojson.Safe.t
(** Same flat field set as {!snapshot_to_json}, with an additional
    ["ratios"] sibling object containing {!auto_bg_promotion_rate}. *)
