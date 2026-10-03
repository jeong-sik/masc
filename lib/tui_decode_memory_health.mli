(** One of the six conditions the memory keeper reports. The server derives the
    wire's [severity] and [target] from this code, and the decoder rejects a
    payload where they disagree, so the code alone identifies the alert. *)
type memory_alert_code =
  | Snapshot_read_error
  | Source_snapshot_read_error
  | Librarian_stopped
  | Librarian_failures
  | Librarian_starvation
  | Vision_ingest_errors

val memory_alert_is_history : memory_alert_code -> bool
(** Failed-pass totals and starvation from historical failures describe
    server-start history, not the outcome of the current Librarian pass. *)

(** The severity the server is contractually required to send for a code. *)
val memory_alert_severity : memory_alert_code -> [ `Warn | `Error ]

(** The wire also carries [value] and [threshold]; neither is kept. Every count
    a [value] would report is already drawn from {!memory_keeper_health} two
    lines above the alert, and the server pins [threshold] to [0.0] for all six
    codes. The decoder still requires and range-checks both, so a payload that
    starts meaning something by them fails loudly instead of passing unread. *)
type memory_alert = {
  ma_code : memory_alert_code;
  ma_label : string;
  ma_message : string;
}

(** How the keeper's last durable Librarian pass ended, one constructor per
    server [pass_end]. [Pass_stopped] and [Pass_raised] carry the server's
    account of why; the other endings have none. An ending this build does not
    know fails the decode. *)
type memory_librarian_pass_end =
  | Pass_off
  | Pass_lane_unconfigured
  | Pass_drained
  | Pass_yielded_to_waiting_unit
  | Pass_not_committed
  | Pass_stopped of string
  | Pass_raised of string

(** Why a Librarian pass journaled a failure, one constructor per server
    [librarian_failure_kind]. A kind this build does not know fails the
    decode. *)
type memory_librarian_failure_kind =
  | Failure_prompt_render
  | Failure_execution_clock_unavailable
  | Failure_exact_setup
  | Failure_exact_execution
  | Failure_domain_output_invalid
  | Failure_absorb_judgment
  | Failure_memory_snapshot_write
  | Failure_runtime_context_unavailable
  | Failure_lane_cancelled
  | Failure_unhandled_exception

(** The server's account of why a pass stopped or crashed; [None] for the
    endings that carry none. *)
val memory_librarian_pass_end_cause : memory_librarian_pass_end -> string option

(** RFC librarian-lifecycle §4.10: the atoms the Keeper's requests skip
   because the Librarian stands behind the start the provider last
   accepted. [mls_gap_end_atom] is that start; the gap ends just before it.
   [Stalled_unmeasured] is a file the gap is read from that did not read:
   neither "no gap" nor a gap. *)
type memory_librarian_stall_cause =
  | Stall_meta_unreadable
  | Stall_turn_records_unreadable
  | Stall_turn_boundary_refused
  | Stall_snapshot_unreadable
  | Stall_read_position_unreadable

type memory_librarian_stalled =
  | Stalled_gap of {
      mls_gap_start_atom : int;
      mls_gap_end_atom : int;
    }
  | Stalled_unmeasured of {
      mls_cause : memory_librarian_stall_cause;
      mls_detail : string;
    }

(* RFC librarian-lifecycle §4.9: how far behind the keeper's Librarian is
   standing, and what its last pass and its journal say. [None] in a field is
   "not measured", which the header prints as such; it is not zero. *)
type memory_librarian_health = {
  mlh_state : memory_librarian_pass_end option;
  mlh_measured_at : float option;
  mlh_unread_atom_turns : int option;
  mlh_unread_official_turns : int option;
  mlh_continuity_unread_atoms : int option;
      (** How far the continuity snapshot trails the Librarian's read
          position. A different lag from [mlh_unread_atom_turns], which is
          the durable round's: the two fall behind separately. [None] is
          "cannot say" -- no snapshot, an unreadable one, or one from
          another trace -- and is not the same as caught up. *)
  mlh_last_success_at : float option;
  mlh_last_failure_kind : memory_librarian_failure_kind option;
  mlh_stalled : memory_librarian_stalled option;
      (** [None] while the Librarian point is at or past the start the
          provider last accepted, or when there is no accepted start yet. *)
}

type memory_context_frontier = {
  mcf_trace_id : string;
  mcf_end_atom : int;
  mcf_boundary_line : int;
}
type memory_context_position = {
  mcpo_trace_id : string;
  mcpo_end_atom : int;
}
type memory_context_input =
  | Context_summarized of memory_context_frontier
  | Context_absorbed of memory_context_position
      (** The request started at the Librarian's durable position; nothing
          summarizes what lies before it. *)
  | Context_without_snapshot
  | Context_not_applied

type memory_context_prepared = {
  mcp_prepared_at : float;
  mcp_runtime_id : string;
  mcp_input : memory_context_input;
  mcp_request_bytes : int;
}
type memory_context_cycle = {
  mcc_saved : memory_context_frontier option;
  mcc_saved_unreadable : bool;
  mcc_read_position : int option;
      (** Where the Librarian has read to, beside where its snapshot cuts
          ([mcc_saved]). A request starts at the cut and carries the atoms up
          to here, so the two apart is what the turn pays; the distance is the
          subtraction and is not a field (#37793). *)
  mcc_read_position_unreadable : bool;
      (** The position file could not be read, which is why there is no
          number. A keeper that has read nothing has neither. *)
  mcc_rewriting_through : int option;
      (** Where a snapshot being rewritten from atom 0 has to reach before a
          request starts from it. Always past [mcc_saved]'s cut; [None] on a
          snapshot that is not being rewritten. *)
  mcc_prepared : memory_context_prepared option;
  mcc_synthesis : Keeper_continuity_observation.synthesis option;
}

type memory_keeper_health = {
  mkh_keeper_id : string;
  mkh_revision : int;
  mkh_updated_at : float option;
  mkh_facts : int;
  mkh_observed_facts : int;
  mkh_derived_facts : int;
  mkh_support_invalidations : int;
  mkh_snapshot_bytes : int;
  mkh_added : int;
  mkh_removed : int;
  mkh_snapshot_present : bool;
  mkh_context_cycle : memory_context_cycle;
  mkh_librarian : memory_librarian_health;
  mkh_librarian_failures : int;
  mkh_vision_ingest_errors : int;
  mkh_vision_ingest_error_reasons : (string * int) list;
  mkh_read_error : string option;
  mkh_source_revision : int;
  mkh_source_facts : int;
  mkh_source_invalidations : int;
  mkh_source_snapshot_bytes : int;
  mkh_source_snapshot_present : bool;
  mkh_source_read_error : string option;
  mkh_alerts : memory_alert list;
}

(** A keeper row this build could not read, and why. The other rows still
    decode, so one row from a newer server does not blank the pane.
    [mkr_keeper_id] is [None] when the row's own [keeper_id] could not be read
    either. *)
type memory_keeper_refusal = {
  mkr_keeper_id : string option;
  mkr_reason : string;
}

type memory_health_snapshot = {
  mhs_generated_at : float;
  mhs_keepers : memory_keeper_health list;
  mhs_refused_keepers : memory_keeper_refusal list;
  mhs_total_facts : int;
  mhs_total_observed_facts : int;
  mhs_total_derived_facts : int;
  mhs_total_support_invalidations : int;
  mhs_total_snapshot_bytes : int;
  mhs_total_source_facts : int;
  mhs_total_source_invalidations : int;
  mhs_total_source_snapshot_bytes : int;
  mhs_total_librarian_failures : int;
  mhs_total_librarian_unread_turns : int option;
  mhs_total_librarian_continuity_unread_atoms : int;
      (** Summed over the keepers whose continuity lag could be taken. *)
  mhs_total_librarian_continuity_unmeasured : int;
      (** How many keepers it could not be taken for, so the sum above is not
          read as a caught-up fleet. *)
  mhs_total_vision_ingest_errors : int;
  mhs_total_read_errors : int;
  mhs_total_source_read_errors : int;
  mhs_warn_alerts : int;
  mhs_error_alerts : int;
  mhs_starving_keepers : int;
}

val decode_memory_health_snapshot :
  Yojson.Safe.t -> (memory_health_snapshot, string) result
(** Decode the fleet memory-health snapshot served at
    [/api/v1/dashboard/keeper-memory-health]. Every consumed field is
    required: a keeper the server left out is invisible here, not defaulted. *)
