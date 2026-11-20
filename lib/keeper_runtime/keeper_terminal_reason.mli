(** Why a Keeper turn ended, as the code that ended it knew it.

    The execution receipt holds this value. {!to_wire} writes the one spelling
    that the receipt JSON, manifest rows and activity events carry; nothing
    decodes that spelling back into this type. The operator disposition reads
    {!failure_class} of the typed error, so a new error constructor is a
    compile obligation in this module instead of a string nobody recognises. *)

type t =
  | Completed
  (** The turn finished. Wire ["success"]. *)
  | Checkpoint
  (** The turn yielded at a continuation boundary. Wire ["checkpoint"]. *)
  | Input_required
  (** The turn stopped on a typed input request. Wire ["input_required"]. *)
  | Supervisor_stop
  (** The supervisor's stop signal ended the turn. Wire ["supervisor_stop"]. *)
  | External_cancel
  (** Something other than the supervisor cancelled the streaming turn.
      Wire ["external_cancel"]. *)
  | Phase_not_executable of Keeper_state_machine.phase
  (** The phase gate skipped the turn in this phase.
      Wire ["non_executable_phase:<phase>"]. *)
  | Registry_phase_missing
  (** The phase gate found no registry phase before dispatch.
      Wire ["registry_phase_missing"]. *)
  | Failed of Agent_core.Error.t
  (** The turn ended with this error. Wire {!code_of_core_error}. *)

val to_wire : t -> string

(** The wire of [Failed err]. Surfaces that carry only an error's code use it:
    the typed bridge [Keeper_turn_terminal_code], trajectory outcomes and
    event payloads. Provider text inside an error (a reported error type, an
    unrecognised stop reason) is copied into the spelling as data. *)
val code_of_core_error : Agent_core.Error.t -> string

(** Snake_case label of a closed terminal tool effect: ["proven_pre_effect"],
    ["proven_post_effect"] or ["effect_outcome_unknown"]. *)
val terminal_effect_disposition_to_wire : Agent_core.Error.closed_terminal_effect -> string

(** Whether the next turn may simply try again: a timeout, a dropped
    connection, or a connection that did not open. *)
type provider_retry =
  | Transient
  | Persistent

(** The receipt disposition's view of a failed turn. Every error lands in
    exactly one class through exhaustive matches on its constructors. *)
type failure_class =
  | Runtime_exhausted
  (** Every runtime candidate was tried. *)
  | Config_invalid
  (** A setting was rejected before dispatch: an agent-core configuration
      error, a provider's invalid config field, or a Task Skill pin that did
      not resolve (#31131). *)
  | Authorization_refused
  (** The API or the provider refused under authorization. The error does not
      say why; measurement shows it carries usage limits far more often than
      credential rejection (852 September turns: 838 weekly limit, 14
      five-hour limit). *)
  | Provider_runtime_failure of provider_retry
  (** Any other API or provider failure, and a closed runtime connection. *)
  | Transcript_corruption
  (** Stored history failed admission. Nothing was dispatched, and retry is
      forbidden until an operator resets the checkpoint. *)
  | Official_client_recovery_required
  (** The durable official-client session refused a local claim and stays
      held until an operator resolves its recovery. *)
  | Official_client_session_refused of Keeper_official_client_session_refusal.t
  (** An official-client runtime refused the turn before dispatch because of
      the state of its vendor session, not because of a setting (#38402). *)
  | Provider_attempt_effect_fenced
  (** A provider attempt may have crossed an effect boundary; same-turn replay
      is forbidden. *)
  | Tool_correction_lost
  (** The same fence on a turn that also recorded pre_tool_use rejections
      (masc#28885). *)
  | Accept_rejected
  (** The provider answered, and MASC's accept contract found nothing usable
      in the answer. *)
  | Terminal_effect_failed
  (** The tool that ends the turn by producing an external artifact failed or
      returned no typed receipt. Whether the artifact left the process is
      unknown. *)
  | Internal_error
  (** An internal error without a MASC envelope, an unhandled or bridge
      exception, a contract rejection, or a host stop. *)
  | No_failure_policy
  (** Errors with no disposition of their own: agent-loop errors other than a
      terminal effect failure, MCP, serialization, IO, orchestration and media
      errors, and three MASC kinds never observed in receipts (a resumable CLI
      session, a receipt persistence failure, a gate replay repair). The
      disposition reads the receipt's outcome and lane facts for these. *)

val failure_class : Agent_core.Error.t -> failure_class

(** {1 Provider timeout spellings}

    [Keeper_provider_runtime_boundary] still reads a persisted registry
    failure code with these. The encoder above writes the same constants. *)

val wire_provider_error_timeout : string
val wire_provider_error_timeout_prefix : string
val wire_provider_error_network_timeout : string
val wire_provider_error_network_timeout_prefix : string
val wire_provider_error_connect_failed_timeout : string
