type alert_severity =
  | Alert_warn
  | Alert_error

let alert_severity_to_wire = function
  | Alert_warn -> "warn"
  | Alert_error -> "error"
;;

module Row = struct
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
    ; librarian_attention_required : bool
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
  ; librarian_continuity_unread_atoms : int
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
  }

let of_rows (rows : Row.t list) =
  let sum (field : Row.t -> int) =
    List.fold_left (fun total row -> total + field row) 0 rows
  in
  let count (holds : Row.t -> bool) = sum (fun row -> if holds row then 1 else 0) in
  let unread_turns =
    List.fold_left
      (fun total (row : Row.t) ->
         match total, row.Row.unread_atom_turns, row.Row.unread_official_turns with
         | Some total, Some atoms, Some official -> Some (total + atoms + official)
         | None, _, _ | Some _, None, _ | Some _, Some _, None -> None)
      (Some 0)
      rows
  in
  let alerts_of severity (row : Row.t) =
    List.length
      (List.filter
         (fun alert ->
            match alert, severity with
            | Alert_warn, Alert_warn | Alert_error, Alert_error -> true
            | Alert_warn, Alert_error | Alert_error, Alert_warn -> false)
         row.Row.alerts)
  in
  { facts = sum (fun row -> row.Row.facts)
  ; observed_facts = sum (fun row -> row.Row.observed_facts)
  ; derived_facts = sum (fun row -> row.Row.derived_facts)
  ; support_invalidations = sum (fun row -> row.Row.support_invalidations)
  ; snapshot_bytes = sum (fun row -> row.Row.snapshot_bytes)
  ; added = sum (fun row -> row.Row.added)
  ; removed = sum (fun row -> row.Row.removed)
  ; source_facts = sum (fun row -> row.Row.source_facts)
  ; source_invalidations = sum (fun row -> row.Row.source_invalidations)
  ; source_snapshot_bytes = sum (fun row -> row.Row.source_snapshot_bytes)
  ; librarian_unread_turns = unread_turns
  ; librarian_continuity_unread_atoms =
      sum (fun row -> Option.value row.Row.continuity_unread_atoms ~default:0)
  ; librarian_continuity_unmeasured =
      count (fun row -> Option.is_none row.Row.continuity_unread_atoms)
  ; librarian_failures = sum (fun row -> row.Row.librarian_failures)
  ; vision_ingest_errors = sum (fun row -> row.Row.vision_ingest_errors)
  ; read_errors = count (fun row -> row.Row.read_error)
  ; source_read_errors = count (fun row -> row.Row.source_read_error)
  ; total_alerts = sum (fun row -> List.length row.Row.alerts)
  ; warn_alerts = sum (alerts_of Alert_warn)
  ; error_alerts = sum (alerts_of Alert_error)
  ; keepers_with_alerts = count (fun row -> row.Row.alerts <> [])
  ; snapshot_read_error_keepers = count (fun row -> row.Row.read_error)
  ; source_snapshot_read_error_keepers = count (fun row -> row.Row.source_read_error)
  ; librarian_stopped_keepers = count (fun row -> row.Row.librarian_stopped)
  ; librarian_attention_required_keepers = count (fun row -> row.Row.librarian_attention_required)
  ; librarian_starving_keepers =
      count (fun row -> row.Row.librarian_failures > 0 && not row.Row.snapshot_present)
  }
;;

let totals_to_json (t : t) =
  `Assoc
    [ "facts", `Int t.facts
    ; "observed_facts", `Int t.observed_facts
    ; "derived_facts", `Int t.derived_facts
    ; "support_invalidations", `Int t.support_invalidations
    ; "snapshot_bytes", `Int t.snapshot_bytes
    ; "added", `Int t.added
    ; "removed", `Int t.removed
    ; "source_facts", `Int t.source_facts
    ; "source_invalidations", `Int t.source_invalidations
    ; "source_snapshot_bytes", `Int t.source_snapshot_bytes
    ; ( "librarian_unread_turns"
      , match t.librarian_unread_turns with
        | Some total -> `Int total
        | None -> `Null )
    ; "librarian_continuity_unread_atoms", `Int t.librarian_continuity_unread_atoms
    ; "librarian_continuity_unmeasured", `Int t.librarian_continuity_unmeasured
    ; "librarian_failures", `Int t.librarian_failures
    ; "vision_ingest_errors", `Int t.vision_ingest_errors
    ; "read_errors", `Int t.read_errors
    ; "source_read_errors", `Int t.source_read_errors
    ]
;;

let alert_summary_to_json (t : t) =
  `Assoc
    [ "total_alerts", `Int t.total_alerts
    ; "warn_alerts", `Int t.warn_alerts
    ; "error_alerts", `Int t.error_alerts
    ; "keepers_with_alerts", `Int t.keepers_with_alerts
    ; "snapshot_read_error_keepers", `Int t.snapshot_read_error_keepers
    ; "source_snapshot_read_error_keepers", `Int t.source_snapshot_read_error_keepers
    ; "librarian_stopped_keepers", `Int t.librarian_stopped_keepers
    ; "librarian_attention_required_keepers", `Int t.librarian_attention_required_keepers
    ; "librarian_starving_keepers", `Int t.librarian_starving_keepers
    ]
;;
