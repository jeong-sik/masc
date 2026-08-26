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
  ; conformance : Agent_core.Skill_document.conformance
        (** Specification diagnostics retained for the turn and operator
            projections. Runtime-compatible documents remain usable. *)
  ; reference : Skill_reference.t option
        (** Exact snapshot identity. [None] exists only for document-only test
            catalogs that have no snapshot authority. *)
  ; provenance : provenance option
  ; surface : surface
  }

type composition = private
  { entry : Keeper_tool_composition_catalog.entry
  ; provenance : provenance option
  }

type t

type named_skill_error = Missing_named_skill of { name : string }

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
  | Removed_invocation_policy of
      { skill : string
      ; field : string
      }
  | Duplicate_skill of { name : string }

type rejected_document = private
  { directory : string
  ; error : error
  }

type projection_diagnostic = private
  { identity : Skill_catalog_snapshot.identity
  ; error : error
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
    turn. *)

val project_entry :
  Skill_catalog_snapshot.t -> Skill_catalog_snapshot.entry -> (skill, error) result
(** Project one exact snapshot entry, including a shadowed entry. The returned
    Skill preserves the entry's exact reference and source provenance. *)

val empty : t
val skills : t -> skill list
val find : t -> string -> skill option
val instruction_entries : t -> (string * string * string) list
(** Instruction skills as [(name, description, body)] in catalog order. This
    is the single input used to build both executable and schema-only
    [keeper_skill] tools. *)

val instruction_names_for :
  t -> string list -> (string list, named_skill_error) result
(** Resolve task-declared names and return only instruction skill names in
    declaration order. Composition names are valid but omitted. *)

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
