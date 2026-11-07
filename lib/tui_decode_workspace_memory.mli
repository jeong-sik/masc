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

type available_inventory = {
  generated_at : float;
  ledger_sha256 : string;
  claim_count : int;
  conflict_count : int;
  excluded_count : int;
  classified_count : int;
  briefing : briefing;
}

type inventory =
  | Missing of { generated_at : float }
  | Available of available_inventory

val decode_inventory : Yojson.Safe.t -> (inventory, string) result
