(** Operator-facing disposition for keeper turns. RFC-0047.

    This module is the *application-layer* counterpart of
    [Keeper_turn_terminal_code] (RFC-0042, runtime/SDK layer). The
    runtime layer answers "what terminated this turn at the
    SDK/registry boundary?"; this layer answers "what should the
    operator see and do?".

    The two layers are deliberately separate types:
    - [Keeper_turn_terminal_code.t] stays narrow (RFC-0042 §3.1) and
      is sourced from [Keeper_registry.failure_reason] /
      [Agent_sdk.Error.sdk_error].
    - [Keeper_turn_disposition.t] is what
      [Keeper_turn_terminal.t.code: string] *currently mashes
      together*; PR-2 swaps the field type to this closed sum, PR-3
      removes the legacy string field.

    PR-1 introduces this module as inert (no callers in the tree).
    PR-2 populates [Keeper_turn_terminal.t.disposition] from typed
    producers. PR-3 deletes the legacy [code: string] field, making
    [severity / summary / next_action] exhaustive matches with no
    string-substring classifiers.

    @stability Evolving
    @since 0.193.3 *)

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
  (** Last-resort escape hatch for un-classified producer paths
          that have not yet been promoted to a closed constructor.
          [to_wire] returns ["unknown_error"] when [raw_error] is empty,
          else [raw_error] verbatim.

          PR-3 lint
          [scripts/lint/no-free-unknown-disposition.sh] will block
          PRs that construct [Unknown { raw_error = X }] with the same
          [X] at >= 2 sites; such [X] must be promoted to a
          constructor. *)

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

(** Stable wire format. The strings produced here are byte-for-byte
    compatible with the strings emitted today by
    [Keeper_turn_terminal.t.code] for every code consumed by the
    legacy [severity_of_code / summary_of_code / next_action_of_code]
    in [keeper_turn_terminal.ml].

    Mapping:
    - [Success] → ["success"]
    - [Input_required] → ["input_required"]
    - [External_cancel] → ["external_cancel"]
    - [Turn_wall_clock_timeout] → ["turn_wall_clock_timeout"]
    - [Runtime_attempts_exhausted] → ["runtime_attempts_exhausted"]
    - [Provider_error code] → [Keeper_turn_terminal_code.to_wire code]
    - [Unknown { raw_error = "" }] → ["unknown_error"]
    - [Unknown { raw_error }] → [raw_error] (verbatim) *)
val to_wire : t -> string

(** Best-effort deserialiser. Canonical application strings round-trip
    exactly. Unrecognised strings first try
    [Keeper_turn_terminal_code.of_wire]; if that succeeds, the result
    is wrapped via [of_termination_code].
    Otherwise [Unknown { raw_error = wire }] is returned. *)
val of_wire : string -> t

(** Typed success predicate for consumers of the strict canonical decoder. *)
val is_success : t -> bool

(** {1 Layer projection} *)

(** Canonical projection from runtime layer to operator layer. See
    RFC-0047 §3.1 for the full mapping table.

    A runtime cause maps to a non-[Provider_error] disposition only
    when the runtime classification fully determines the operator
    action.
    Otherwise the runtime cause is preserved by wrapping with
    [Provider_error] so dashboards keep the typed runtime trace. *)
val of_termination_code : Keeper_turn_terminal_code.t -> t

(** {1 Equality / debug} *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
