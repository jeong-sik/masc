(** Prompt Registry - Versioned template storage and management *)

(** {1 Types} *)

type prompt_metrics =
  { usage_count : int
  ; avg_score : float
  ; last_used : float
  }

val prompt_metrics_to_yojson : prompt_metrics -> Yojson.Safe.t
val prompt_metrics_of_yojson : Yojson.Safe.t -> (prompt_metrics, string) result

type prompt_entry =
  { id : string
  ; template : string
  ; version : string
  ; variables : string list
  ; metrics : prompt_metrics option
  ; created_at : float
  ; deprecated : bool
  }

val prompt_entry_to_yojson : prompt_entry -> Yojson.Safe.t
val prompt_entry_of_yojson : Yojson.Safe.t -> (prompt_entry, string) result

type registry_stats =
  { total_prompts : int
  ; active_prompts : int
  ; deprecated_prompts : int
  ; most_used : string option
  ; avg_usage : float
  }

type prompt_meta =
  { description : string
  ; category : string
  ; required_file : bool
  ; template_variables : string list
  }

type prompt_resolution =
  { effective : string
  ; source : string
  ; file_value : string option
  ; override_value : string option
  ; default_value : string option
  ; file_path : string option
  ; file_exists : bool
  ; has_override : bool
  }

(** {1 Variable Extraction} *)

val extract_variables : string -> string list

(** {1 Initialization} *)

val init : ?persist_dir:string -> unit -> unit
val set_markdown_dir : string -> unit
val get_markdown_dir : unit -> string option

(** {1 Registration and Lookup} *)

val register : prompt_entry -> unit
val get : id:string -> ?version:string -> unit -> prompt_entry option
val get_versions : id:string -> unit -> prompt_entry list
val list_all : unit -> prompt_entry list
val list_ids : unit -> string list
val exists : id:string -> ?version:string -> unit -> bool
val unregister : id:string -> ?version:string -> unit -> bool
val deprecate : id:string -> version:string -> unit -> bool

(** {1 Metrics} *)

val update_metrics : id:string -> version:string -> score:float -> unit -> unit

(** {1 Template Rendering} *)

val render_template
  :  template:string
  -> vars:(string * string) list
  -> unit
  -> (string, string) result

val render
  :  id:string
  -> ?version:string
  -> vars:(string * string) list
  -> unit
  -> (string, string) result

val render_prompt_template : string -> (string * string) list -> (string, string) result

(** {1 Statistics} *)

val stats : unit -> registry_stats

(** {1 Utility} *)

val clear : unit -> unit
val count : unit -> int
val count_unique : unit -> int
val to_json : unit -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (int, string) result

(** {1 Override API} *)

val register_prompt
  :  key:string
  -> description:string
  -> ?category:string
  -> ?required_file:bool
  -> ?template_variables:string list
  -> unit
  -> unit

(** Auto-discover and register prompts from markdown files with frontmatter.
    Files without frontmatter are skipped. Key is derived from filename. *)
val load_prompts_from_directory : string -> unit

val register_default
  :  key:string
  -> default:string
  -> description:string
  -> ?category:string
  -> unit
  -> unit

val resolve_prompt : string -> prompt_resolution
val get_prompt : string -> string
val set_override : string -> string -> (unit, string) result
val clear_prompt_override : string -> unit
val prompt_source : string -> string
val restore_overrides : string -> unit
val persist_overrides : string -> unit
val validate_required_prompt_files : unit -> (string * string) list
val validate_prompt_templates : unit -> (string * string) list
val list_prompts : unit -> Yojson.Safe.t list
val prompts_json : unit -> Yojson.Safe.t
