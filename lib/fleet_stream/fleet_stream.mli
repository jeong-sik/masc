(** The keeper fleet reading as events (RFC-0477).

    The server encodes and the terminal client decodes with this one module, so
    neither side keeps its own copy of the field names. The decoder is exact: a
    missing field, a field this build does not know, a word that names no
    variant, or a number out of range is an error, never a default.

    Times are epoch seconds. No event carries an age: an age changes on every
    read, so two readings of the same fleet would never compare equal. *)

val schema_version : int
(** The [schema] every initial snapshot carries. A client that reads another value
    stops with [Schema_mismatch] instead of reading fields whose meaning may
    have changed. *)

val stream_path : string
(** The path the server answers with Server-Sent Events, one {!event} per
    frame, and the terminal client connects to. *)

module Revision : sig
  type t
  (** The position of an event in one stream. Starts at 1 and rises by 1 for
      each event the hub publishes. *)

  val first : t
  val next : t -> t

  val is_next : after:t -> t -> bool
  (** [is_next ~after r] holds when [r] directly follows [after]. A client whose
      next event fails this has lost one and must reconnect. *)

  val of_int : int -> t option
  (** [None] below 1. *)

  val to_int : t -> int
  val equal : t -> t -> bool
end

module Names : sig
  type t
  (** Keeper names, sorted and without duplicates by construction, so two
      readings of the same set are equal however the scan listed them. *)

  val empty : t

  val of_list : string list -> t
  (** Sorts and removes duplicates. For the side that produces a reading. *)

  val of_canonical_list : string list -> t option
  (** [Some] only for a list that is already strictly increasing. The decoder
      uses it, so a wire list in any other order is an error. *)

  val to_list : t -> string list
  val length : t -> int
  val mem : string -> t -> bool
  val equal : t -> t -> bool
end

(** The fleet scan's reading, with the fields the Keepers screen draws. *)
type fleet =
  { fs_status : Keeper_fleet_grade.t
  ; fs_blocker : Keeper_fleet_blocker.t option
  ; fs_operator_action_required : bool
  ; fs_bootable_count : int
  ; fs_running_count : int
  ; fs_executable_count : int
  ; fs_failing_count : int
  ; fs_recovering_count : int
  ; fs_turn_configuration_error_count : int
  ; fs_official_client_recovery_required_count : int
  ; fs_paused_count : int
  ; fs_target_reaction_capacity : int
  ; fs_reaction_capacity_shortfall : int
  ; fs_bootable_names : Names.t
  ; fs_running_names : Names.t
  ; fs_executable_names : Names.t
  ; fs_turn_configuration_error_names : Names.t
  ; fs_official_client_recovery_required_names : Names.t
  ; fs_active_task_owner_without_fiber_count : int
  ; fs_completion_authority_pending_count : int
  ; fs_active_task_owner_scan_error_count : int
  }

type degraded_reason =
  | Scan_timed_out
  | Scan_failed

type degradation =
  { since : float
  ; reason : degraded_reason
  }

type event =
  | Unavailable_snapshot of
      { revision : Revision.t
      ; degradation : degradation
      }
      (** The first scan failed before any reading was available. *)
  | Snapshot of
      { revision : Revision.t
      ; measured_at : float
      ; fleet : fleet
      ; degraded : degradation option
      }
      (** The whole state, as one read would have told it: the first event of
          every connection that has a reading. [degraded] says whether the scan
          has failed since [measured_at]. *)
  | Changed of
      { revision : Revision.t
      ; measured_at : float
      ; fleet : fleet
      }
      (** The reading after a scan whose result differs from the last one. It
          also ends a degradation, whether or not the reading differs. *)
  | Degraded of
      { revision : Revision.t
      ; degradation : degradation
      }
      (** No scan has produced a reading since [degradation.since]. The last
          reading stays what the fleet looked like at its [measured_at]. *)

val revision_of_event : event -> Revision.t

val equal_fleet : fleet -> fleet -> bool

type decode_error =
  | Not_an_object of { at : string }
  | Missing_field of { at : string; field : string }
  | Unknown_field of { at : string; field : string }
  | Duplicate_field of { at : string; field : string }
  | Wrong_type of { at : string; field : string; expected : string }
  | Out_of_range of { at : string; field : string }
  | Unknown_word of { at : string; field : string; word : string }
  | Not_canonical of { at : string; field : string }
  | Unknown_event of string
  | Schema_mismatch of { expected : int; received : int }

val decode_error_to_string : decode_error -> string

val encode : event -> Yojson.Safe.t

val decode : Yojson.Safe.t -> (event, decode_error) result
