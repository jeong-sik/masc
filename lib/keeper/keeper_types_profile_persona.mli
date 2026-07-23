type persona_summary =
  { persona_name : string
  ; display_name : string
  ; role : string option
  ; trait : string option
  ; profile_path : string
  ; has_keeper_defaults : bool
  }

val operator_todo_placeholder_marker : string
val string_has_operator_todo_placeholder : string -> bool
val json_has_operator_todo_placeholder : Yojson.Safe.t -> bool
val json_operator_todo_placeholder_paths : Yojson.Safe.t -> string list
val reject_placeholder_persona_profile :
  label:string -> path:string -> Yojson.Safe.t -> bool
val personas_root_opt : unit -> string option
val persona_profile_path_opt_in_dirs : string list -> string -> string option
val persona_profile_path_opt : string -> string option
val persona_description_max_chars : int
val load_persona_extended : ?max_chars:int -> string -> string option
val load_persona_summary : string -> persona_summary option
val load_persona_summary_from_path : string -> string -> persona_summary option
val list_persona_summaries : unit -> persona_summary list
