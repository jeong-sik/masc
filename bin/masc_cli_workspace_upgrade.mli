type action = Inspect | Apply of { keeper_name : string; source_sha256 : string }
  | Restore of { backup_id : string }
  | Inspect_journal of string
  | Prepare_journal of { keeper_name : string; source_sha256 : string }
  | Inspect_journal_bundle of string
val run : base_path:string -> action:action -> int
