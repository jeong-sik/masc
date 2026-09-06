(** SKILL.md-backed catalog of Keeper skills (RFC skills-as-tools).

    {!Agent_core.Skill_document} is the parse authority for one SKILL.md file.
    This
    module never reads frontmatter itself. What it adds is the layer above one
    file: assembling documents into a duplicate-free, name-sorted catalog, and
    detecting the composition surface.

    What kind of skill a file is comes from its body, not from a declared
    field: a body with no [```toml composition] fenced block is an
    instruction skill, exactly one block is a composition skill, and the
    block's content is read by {!Keeper_tool_composition_catalog.parse}
    unchanged — the catalog grammar is the only composition grammar. A kind
    field could disagree with the body; the body alone cannot. *)

type surface =
  | Instruction
  | Composition of Keeper_tool_composition_catalog.entry

type provenance = private
  { identity : Skill_catalog_snapshot.identity
  ; source : Skill_source_config.source
  ; source_root : string option
        (** Exact resolved source root captured by the snapshot scan. Omitted
            from public JSON because it is a host path. *)
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes option
  ; directory : string
  }

type skill = private
  { name : string
  ; description : string
  ; body : string
        (** Everything after the frontmatter, including any composition
            fence, exactly as {!Agent_core.Skill_document} returned it. *)
  ; reference : Skill_reference.t option
        (** Exact snapshot identity. [None] exists only for document-only test
            catalogs that have no snapshot authority. *)
  ; provenance : provenance option
  ; composition_span : Keeper_skill_body_ast.span option
        (** Source lines of the top-level [toml composition] fence. [None] for
            instruction Skills and projection fallbacks. *)
  ; surface : surface
  }

type composition = private
  { entry : Keeper_tool_composition_catalog.entry
  ; provenance : provenance option
  ; span : Keeper_skill_body_ast.span option
  }

type t

type error =
  | Definition_rejected of
      { directory : string
      ; diagnostics : Agent_core.Skill_document.diagnostic list
      }
  | Unterminated_composition_block of { skill : string }
  | Multiple_composition_blocks of
      { skill : string
      ; count : int
      }
  | Composition_rejected of
      { skill : string
      ; error : Keeper_tool_composition_catalog.error
      }
  | Not_exactly_one_composition of
      { skill : string
      ; count : int
      }
  | Composition_name_mismatch of
      { skill : string
      ; declared : string
      }
  | Composition_info_near_miss of
      { skill : string
      ; info : string
      }
      (** Advisory: a fence info string that normalizes to the composition
          contract (case, tabs, doubled spaces) but does not match it exactly.
          The entry stays a projected instruction skill; the diagnostic tells
          the author why no composition tool appeared. *)
  | Duplicate_skill of { name : string }

type rejected_document = private
  { directory : string
  ; error : error
  }

type projection_diagnostic = private
  { identity : Skill_catalog_snapshot.identity
  ; error : error
  }

type entry_projection =
  | Projected of skill
  | Frozen_instruction of
      { skill : skill
      ; diagnostic : error
      }
  | Entry_unavailable of error

type turn_unavailable =
  | Composition_tool_name_collision of
      { tool_name : string
      ; selected : Skill_reference.t
      ; unavailable : Skill_reference.t
      }
  | Composition_tool_name_collision_unattributed of
      { tool_name : string
      ; selected_name : string
      ; unavailable_name : string
      }
  | Configured_skill_name_unavailable of { name : string }

type configured_name_unavailable = private Configured_name_unavailable of string

type turn_projection = private
  { catalog : t
  ; unavailable : turn_unavailable list
  }

type exact_surface_availability =
  | Instruction_tool
  | Composition_tool of { tool_name : string }
  | Exact_unavailable of { diagnostic : string }

type exact_surface = private
  { reference : Skill_reference.t
  ; availability : exact_surface_availability
  }

val parse_skill : directory:string -> string -> (skill, error) result
(** Parse one SKILL.md document. [directory] is the skill's directory name;
    {!Agent_core.Skill_document.decode} enforces the frontmatter contract. A
    composition block must declare exactly one composition and its [name]
    must equal the skill name. *)

val partition_documents :
  (string * string) list -> t * rejected_document list
(** Build the usable catalog and retain every rejected document separately.
    A rejected document never contributes a tool or instruction. Every caller
    receives the rejection list explicitly, so one bad optional Skill cannot
    stop unrelated Keeper turns or disappear silently. *)

val of_snapshot :
  Skill_catalog_snapshot.t -> t * projection_diagnostic list
(** Project effective snapshot entries into the temporary composition-tool
    catalog. Snapshot order and exact source provenance are preserved. A
    composition projection failure keeps the frozen document as an instruction
    Skill and returns a diagnostic. Removed invocation-policy fields still omit
    that entry; neither failure rejects the snapshot or an unrelated Keeper
    turn. An instruction skill whose body carries a fence info near-miss also
    returns an advisory {!Composition_info_near_miss} diagnostic while staying
    projected. *)

val all_entries_of_snapshot :
  Skill_catalog_snapshot.t -> t * projection_diagnostic list
(** Project every exact snapshot entry, including shadowed identities. This is
    the operator-surface projection. Executable turn catalogs start with
    {!of_snapshot}, then {!project_turn} merges exact Task-selected shadows. *)

val project_entry_or_fallback :
  Skill_catalog_snapshot.t -> Skill_catalog_snapshot.entry -> entry_projection
(** Canonical projection for global, Task-selected, and shadowed entries.
    Malformed composition declarations remain available as their frozen
    instruction body with a typed diagnostic. Other rejected declarations are
    explicitly unavailable. *)

val project_turn : names:string list option -> global:t -> task:skill list -> turn_projection
(** Merge exact Task-selected entries before the global catalog, then apply the
    same optional exact-name selection to both sources. Absent [names] exposes
    all Skills; [[]] exposes none. Exact
    duplicates collapse. When two different exact composition references
    publish one model tool name, the Task-first entry stays available and the
    other reference is returned as typed unavailable instead of silently
    replacing either identity. *)

val turn_unavailable_to_string : turn_unavailable -> string
val configured_names_unavailable : turn_projection -> configured_name_unavailable list
val configured_name_unavailable_to_yojson : configured_name_unavailable -> Yojson.Safe.t

val exact_surfaces : turn_projection -> task:skill list -> exact_surface list
(** Render every Task-selected exact reference from the same turn projection
    that builds executable tools. *)

val exact_is_executable : turn_projection -> Skill_reference.t -> bool
(** Whether one exact reference is present in the executable turn catalog. *)

val exact_surface_to_yojson : exact_surface -> Yojson.Safe.t

val empty : t
val skills : t -> skill list
val find : t -> string -> skill option
val instruction_entries : t -> (string * string * string) list
(** Instruction skills as [(name, description, body)] in catalog order. This
    is the single input used to build both executable and schema-only
    [keeper_skill] tools. *)

val compositions : t -> composition list
(** Composition entries with their exact snapshot provenance. Catalogs built
    directly from document strings carry [None]; production snapshot
    projections carry [Some provenance]. *)

val composition_entries : t -> Keeper_tool_composition_catalog.entry list
(** The validated composition entries declared by composition skills, in
    catalog (name) order. The tool surface materializes these directly from
    the effective Skill snapshot. *)

val surface_to_string : surface -> string
(** ["instruction"] or ["composition"] — diagnostics and dashboard wire. *)

val provenance_to_yojson : provenance -> Yojson.Safe.t

val error_code : error -> string
val error_to_string : error -> string
