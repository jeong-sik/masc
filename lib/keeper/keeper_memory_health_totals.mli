(** The fleet totals and alert summary of the Keeper memory health answer
    ([GET /api/v1/dashboard/keeper-memory-health]), counted from its rows.

    The server counts them when it answers the fleet, and the TUI counts them
    from the rows it holds, both through {!of_rows}: the two cannot disagree
    on how a row is counted (RFC-0487 §2.5). *)

type alert_severity =
  | Alert_warn
  | Alert_error

val alert_severity_to_wire : alert_severity -> string

(** What one Keeper's row contributes to the totals. *)
module Row : sig
  type t =
    { facts : int
    ; observed_facts : int
    ; derived_facts : int
    ; support_invalidations : int
    ; snapshot_bytes : int
    ; added : int
    ; removed : int
    ; source_facts : int
    ; source_invalidations : int
    ; source_snapshot_bytes : int
    ; unread_atom_turns : int option
    ; unread_official_turns : int option
    ; continuity_unread_atoms : int option
    ; librarian_failures : int
    ; vision_ingest_errors : int
    ; read_error : bool
    ; source_read_error : bool
    ; snapshot_present : bool
    ; librarian_stopped : bool
        (** The Keeper's last durable Librarian pass ended without draining:
            its lane is unconfigured, it did not commit, it stopped or it
            raised. *)
    ; librarian_attention_required : bool
        (** Derived from the Keeper's durable and explicit-admission pending
            observations, independently of its stopped-pass count. *)
    ; alerts : alert_severity list
    }
end

type t =
  { facts : int
  ; observed_facts : int
  ; derived_facts : int
  ; support_invalidations : int
  ; snapshot_bytes : int
  ; added : int
  ; removed : int
  ; source_facts : int
  ; source_invalidations : int
  ; source_snapshot_bytes : int
  ; librarian_unread_turns : int option
      (** [None] when any row's unread turns were not measured: a sum over
          the measured rows would read as the fleet's. *)
  ; librarian_continuity_unread_atoms : int
      (** Summed over the rows whose continuity lag is known; the others are
          counted in [librarian_continuity_unmeasured]. Most Keepers carry no
          continuity snapshot, so a total that went [None] on one would hide
          the rest. *)
  ; librarian_continuity_unmeasured : int
  ; librarian_failures : int
  ; vision_ingest_errors : int
  ; read_errors : int
  ; source_read_errors : int
  ; total_alerts : int
  ; warn_alerts : int
  ; error_alerts : int
  ; keepers_with_alerts : int
  ; snapshot_read_error_keepers : int
  ; source_snapshot_read_error_keepers : int
  ; librarian_stopped_keepers : int
  ; librarian_attention_required_keepers : int
  ; librarian_starving_keepers : int
      (** Rows with Librarian failures and no memory snapshot. *)
  }

val of_rows : Row.t list -> t

val totals_to_json : t -> Yojson.Safe.t
(** The answer's [totals] object. *)

val alert_summary_to_json : t -> Yojson.Safe.t
(** The answer's [alert_summary] object. *)
