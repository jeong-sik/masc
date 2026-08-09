(** Operator-facing disposition for keeper turns.

    This module is the *application-layer* counterpart of
    [Keeper_turn_terminal_code] (RFC-0042, runtime/agent-core layer). The
    runtime layer answers "what terminated this turn at the
    agent-core/registry boundary?"; this layer answers "what should the
    operator see and do?".

    The two layers are deliberately separate types:
    - [Keeper_turn_terminal_code.t] stays narrow (RFC-0042 §3.1) and
      is sourced from [Keeper_registry.failure_reason] /
      [Agent_core.Error.t].
    - [Keeper_turn_disposition.t] is a display and operator-action
      projection. It never grants runtime failure authority to an opaque wire
      string. *)

type t =
  | Success (** Turn completed normally. *)
  | External_cancel
  (** Turn cancelled before completion (operator stop, switch_keeper, …). *)
  | Input_required
  (** Agent emitted a typed input request. Not a failure. Operator action:
          provide input or decline. *)
  | Turn_wall_clock_timeout (** Turn exceeded its wall-clock budget. *)
  | Runtime_attempts_exhausted
  (** Runtime aggregate outcome: all candidate attempts were exhausted.
          Operators should inspect per-attempt root causes instead of treating
          this as the root cause. *)
  | Provider_error of Keeper_turn_terminal_code.t
  (** Runtime-layer termination promoted to operator-facing
          disposition. The inner code preserves the typed runtime cause
          for diagnostics (Otel_metric_store / dashboard / bin/masc-trace).
          [to_wire (Provider_error code) = Keeper_turn_terminal_code.to_wire code].
          PR-3 readers match on this constructor instead of
          [String.starts_with ~prefix:"api_error_"]. *)
  | Unknown of { raw_error : string }
  (** Opaque display-only wire value. It does not carry typed failure
      authority. [to_wire] returns [raw_error] verbatim. *)

(** {1 Severity} *)

type severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

(** Severity classification. Exhaustive — every disposition has a
    severity assigned at the type level, not at substring level. *)
val severity : t -> severity

(** Operator-readable summary string. Exhaustive. *)
val summary : t -> string

(** Optional follow-up action the operator can take. Exhaustive. *)
val next_action : t -> string option

(** {1 Wire format} *)

(** Stable wire format for operator-facing dispositions.

    Mapping:
    - [Success] → ["success"]
    - [Input_required] → ["input_required"]
    - [External_cancel] → ["external_cancel"]
    - [Turn_wall_clock_timeout] → ["turn_wall_clock_timeout"]
    - [Runtime_attempts_exhausted] → ["runtime_attempts_exhausted"]
    - [Provider_error code] → [Keeper_turn_terminal_code.to_wire code]
    - [Unknown { raw_error }] → [raw_error] verbatim *)
val to_wire : t -> string

(** Canonical operator-disposition deserialiser. Application strings round-trip
    exactly. Other strings are promoted through
    [Keeper_turn_terminal_code.of_wire_exact] only when their meaning is
    one-to-one; ambiguous and unknown strings remain [Unknown] with their
    original bytes. *)
val of_wire : string -> t

(** Typed success predicate for consumers of the strict canonical decoder. *)
val is_success : t -> bool

(** {1 Layer projection} *)

(** Canonical projection from runtime layer to operator layer.

    A runtime cause maps to a non-[Provider_error] disposition only
    when the runtime classification fully determines the operator
    action.
    Otherwise the runtime cause is preserved by wrapping with
    [Provider_error] so dashboards keep the typed runtime trace. *)
val of_termination_code : Keeper_turn_terminal_code.t -> t

(** {1 Equality / debug} *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
