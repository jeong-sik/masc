(** Pure editor request and response contracts shared by the TUI and protocol fixtures. *)

type runtime_config_save_error =
  | Runtime_config_conflict of Masc_tui_runtime_config_edit.document
  | Runtime_config_save_refused of string
  | Runtime_config_save_unconfirmed of string

type skill_editor_loaded =
  { sel_reference : Skill_reference.t
  ; sel_source_text : string
  ; sel_access : Skill_source_config.access
  }

type skill_editor_save_status =
  | Skill_unchanged
  | Skill_saved_and_published
  | Skill_saved_but_unpublished of string

type skill_editor_save_receipt =
  { ses_status : skill_editor_save_status
  ; ses_reference : Skill_reference.t
  ; ses_snapshot_revision : string option
  }

type skill_editor_create_status =
  | Skill_created_and_published
  | Skill_created_but_shadowed of Skill_reference.identity
  | Skill_created_but_unpublished of string

type skill_editor_create_receipt =
  { sec_status : skill_editor_create_status
  ; sec_reference : Skill_reference.t
  }

type skill_editor_write_error =
  | Skill_write_refused of string
  | Skill_write_unconfirmed of string

val runtime_config_text_revision : string -> string
val runtime_config_conflict_document : string -> (Masc_tui_runtime_config_edit.document, string) result
val skill_editor_body : Skill_reference.t -> string option -> string
val decode_skill_editor_loaded : Yojson.Safe.t -> (skill_editor_loaded, string) result
val decode_skill_editor_save_receipt : Yojson.Safe.t -> (skill_editor_save_receipt, string) result
val skill_editor_create_body : composition:bool -> source_id:string -> package_id:string -> source_text:string -> string
val decode_skill_editor_create_receipt : source_id:string -> package_id:string -> source_text:string -> Yojson.Safe.t -> (skill_editor_create_receipt, string) result
