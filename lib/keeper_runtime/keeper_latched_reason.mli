(** Typed SSOT for "why a keeper is latched (paused / blocked)".

    Producer: typed only. Consumer: exhaustive match. No string
    classifiers allowed at call sites.

    Distinct from {!Keeper_turn_disposition} (turn outcome) and
    {!Keeper_terminal_reason} (terminal-reason classifier). This type
    answers the operator-facing question: "why did the supervisor latch
    this keeper and refuse to advance the FSM until an external signal?"

    See docs/superpowers/specs/2026-06-26-masc-oas-p0-infra-hardening-design.md
    §3 (Keeper_latched_reason.t) for the design rationale.

    {1 Construction}

    The polymorphic variants [dimension], [source], [reason_code] make
    the closed set of possibilities explicit. Adding a new axis is a
    compile-time change, not a runtime one — readers can use
    [assert_never] to detect forgotten arms. *)

type t =
  | No_progress_loop of
      { consecutive_idle_cycles : int
      ; detector_kind :
          [ `Consecutive_idle_turns
          | `Consecutive_no_progress
          | `Both
          ]
      }
  | Completion_contract_violation of contract_violation_detail
  | Idle_detected of { consecutive_idle_turns : int }
  | Runtime_exhausted of runtime_exhaustion_reason
  | Turn_budget_exhausted of turn_budget_exhausted
  | Stale_storm
  | Provider_timeout_loop of { consecutive_timeouts : int }
  | Operator_paused of { operator_actor : operator_actor }
  | Dead_tombstone
      (** The supervisor reaped a dead keeper and left [paused = true] on
          disk as a tombstone (see
          [Keeper_supervisor_cleanup_tombstone]). Carries no payload:
          the fact that the paused meta is a dead-keeper tombstone — not
          an operator pause or a runtime latch — is the whole
          observability signal. *)

and contract_violation_detail =
  { reason_code :
      [ `No_tool_use_block
      | `No_keeper_tool_returned
      | `Repeated_text_only_response
      | `Unspecified
      ]
  ; raw_error_summary : string  (** display only, never classified *)
  }

and runtime_exhaustion_reason =
  | All_providers_failed
  | No_providers_available
  | Structural_attempt_timeout of { stage : string }
  | Unspecified_runtime

and turn_budget_exhausted =
  { detail : turn_budget_detail
  ; used : int
  ; limit : int
  }

and turn_budget_detail =
  { dimension :
      [ `Turns                       (** OAS SDK [max_turns] cap *)
      | `Wall_clock_seconds          (** env-sourced turn_timeout_sec *)
      | `Idle_turns                  (** env-sourced idle watchdog *)
      ]
  ; source :
      [ `Oas_sdk
      | `Keeper_runtime
      | `User_config
      ]
  }

and operator_actor =
  | Grpc_directive
  | Keeper_down

(** {1 Wire format}

    Used for log/dashboard events. Wire is a closed set of names with
    structured payload encoded as a single tail segment after [":"]. The
    reverse direction is a fail-closed [result] — never returns
    [Unknown] silently. *)

val to_wire : t -> string
(** [to_wire t] returns a stable string suitable for the dashboard
    payload. The wire form is informational only; consumers in this
    repo must use [of_wire] or pattern-match on the typed value
    directly. *)

val of_wire : string -> (t, string) result
(** [of_wire s] parses [s] into a typed [t]. Returns [Error] when [s]
    is not a known wire form. Never falls back to a permissive
    default. *)

(** {1 Equality & hashing (typed, no string comparison)} *)

val equal : t -> t -> bool
val hash : t -> int

(** {1 Display} *)

val pp : Format.formatter -> t -> unit

(** {1 Well-known operator actors}

    These are the only operator actors produced by production pause
    sites. Wire strings are derived only at serialization boundaries. *)

val operator_actor_grpc_directive : operator_actor
val operator_actor_keeper_down : operator_actor
val operator_actor_to_wire : operator_actor -> string

module Stable : sig
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
