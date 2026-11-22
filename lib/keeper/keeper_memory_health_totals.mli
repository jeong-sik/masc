(** The fleet totals and alert summary of the Keeper memory health answer
    ([GET /api/v1/dashboard/keeper-memory-health]), counted from its rows.

    The server counts them when it answers the fleet, and the TUI counts them
    from the rows it holds, both through {!of_rows}: the two cannot disagree
    on how a row is counted. *)

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
    ; librarian_failures : int
    ; vision_ingest_errors : int
    ; read_error : bool
    ; source_read_error : bool
    ; snapshot_present : bool
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
  ; librarian_starving_keepers : int
      (** Rows with Librarian failures and no memory snapshot. *)
  }

val of_rows : Row.t list -> t

val totals_to_json : t -> Yojson.Safe.t
(** The answer's [totals] object. *)

val alert_summary_to_json : t -> Yojson.Safe.t
(** The answer's [alert_summary] object. *)
