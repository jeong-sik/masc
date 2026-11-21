(* One Keeper's Memory health row as the TUI decodes it, for the TUI tests
   that draw rows. A test takes [keeper] and changes only the fields it
   reads, so a field the server adds to the row is written here once. *)

module Health = Masc.Tui_decode_memory_health

let context_cycle : Health.memory_context_cycle =
  { mcc_saved = None
  ; mcc_saved_unreadable = false
  ; mcc_read_position = None
  ; mcc_read_position_unreadable = false
  ; mcc_rewriting_through = None
  ; mcc_unread_snapshot = Ok []
  ; mcc_unread_memory = Ok []
  ; mcc_prepared = None
  ; mcc_synthesis = None
  }
;;

(* A Librarian that has not reported a pass or measured anything. *)
let librarian_unreported : Health.memory_librarian_health =
  { mlh_state = None
  ; mlh_admission_wait = None
  ; mlh_operator_action_required = false
  ; mlh_measured_at = None
  ; mlh_unread_atom_turns = None
  ; mlh_unread_official_turns = None
  ; mlh_continuity_unread_atoms = None
  ; mlh_last_success_at = None
  ; mlh_last_failure_kind = None
  ; mlh_stalled = None
  }
;;

(* A Librarian whose last pass drained what there was, with nothing unread. *)
let librarian_drained : Health.memory_librarian_health =
  { librarian_unreported with
    mlh_state = Some Health.Pass_drained
  ; mlh_measured_at = Some 1_775_000_000.0
  ; mlh_unread_atom_turns = Some 0
  ; mlh_unread_official_turns = Some 0
  ; mlh_continuity_unread_atoms = Some 0
  }
;;

(* Ten facts, two of them derived, in a snapshot of 1024 bytes, and a source
   snapshot of five facts. No change since the start, no error, no alert,
   and no Memory writer: the Keeper is outside the registry. *)
let keeper ~keeper_id : Health.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
  ; mkh_updated_at = None
  ; mkh_facts = 10
  ; mkh_observed_facts = 8
  ; mkh_derived_facts = 2
  ; mkh_support_invalidations = 0
  ; mkh_snapshot_bytes = 1024
  ; mkh_added = 0
  ; mkh_removed = 0
  ; mkh_snapshot_present = true
  ; mkh_age_bins = None
  ; mkh_facts_by_hour = []
  ; mkh_changes_since_start = []
  ; mkh_context_cycle = context_cycle
  ; mkh_librarian = librarian_unreported
  ; mkh_writer = Masc.Tui_decode_memory_writer.No_writer
  ; mkh_librarian_failures = 0
  ; mkh_vision_ingest_errors = 0
  ; mkh_vision_ingest_error_reasons = []
  ; mkh_read_error = None
  ; mkh_source_revision = 1
  ; mkh_source_facts = 5
  ; mkh_source_invalidations = 0
  ; mkh_source_snapshot_bytes = 512
  ; mkh_source_snapshot_present = true
  ; mkh_source_read_error = None
  ; mkh_alerts = []
  }
;;

(* A keeper with [facts] facts in [snapshot_bytes] bytes, all added since the
   start, and no source snapshot. *)
let keeper_without_source ~keeper_id ~facts ~snapshot_bytes : Health.memory_keeper_health =
  { (keeper ~keeper_id) with
    mkh_updated_at = Some 1700000000.
  ; mkh_facts = facts
  ; mkh_snapshot_bytes = snapshot_bytes
  ; mkh_added = facts
  ; mkh_age_bins = Some Masc.Keeper_memory_age_bins.zero
  ; mkh_librarian = librarian_drained
  ; mkh_source_revision = 0
  ; mkh_source_facts = 0
  ; mkh_source_snapshot_bytes = 0
  ; mkh_source_snapshot_present = false
  }
;;
