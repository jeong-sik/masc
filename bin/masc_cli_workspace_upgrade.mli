type action = Inspect | Apply of { keeper_name : string; source_sha256 : string }
  | Restore of { backup_id : string }
  | Inspect_journal of string
  | Prepare_journal of { keeper_name : string; source_sha256 : string }
  | Inspect_journal_bundle of string
  | Inspect_journal_input of { bundle_id : string; trace_id : string }
  | Adopt_journal_input of { bundle_id : string; trace_id : string; checkpoint_sha256 : string }
  | Inspect_journal_adoption of string
  | Assess_journal_installation of string
  | Install_journal of { adoption_id : string; source_sha256 : string; adopted_sha256 : string }
  | Inspect_journal_installation of string
  | List_journal_installations
  | Restore_journal_installation of string
val run : base_path:string -> action:action -> int
