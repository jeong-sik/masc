(** Workspace memory inventory wire decoder. No I/O or rendering. *)

type briefing_status =
  | Pending
  | Current
  | Stale
  | Unavailable

type building_pass = {
  target : int;
  remaining : int;
}

type briefing = {
  status : briefing_status;
  building : building_pass option;
}

type absence_counts = {
  facts : int;
  absent : int;
  available_stores : int;
  missing_stores : int;
}
type ordinary_absence =
  | Absence_complete of absence_counts
  | Absence_partial of { counts : absence_counts; unavailable_stores : int }
  | Absence_unavailable of string
(** Ordinary fact identity membership in the observed ledger, not semantic
    verification. Partial counts cover readable stores only and are lower
    bounds. Missing stores are known empty; an unavailable read is never zero. *)

type available_inventory = {
  generated_at : float;
  ledger_sha256 : string;
  claim_count : int;
  conflict_count : int;
  excluded_count : int;
  classified_count : int;
  briefing : briefing;
  ordinary_absence : ordinary_absence;
}

type inventory =
  | Missing of { generated_at : float; ordinary_absence : ordinary_absence }
  | Available of available_inventory

val decode_inventory : Yojson.Safe.t -> (inventory, string) result
