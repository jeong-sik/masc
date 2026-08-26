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
  ; model_invocable : bool
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
  | Duplicate_skill of { name : string }

type projection_diagnostic = private
  { identity : Skill_catalog_snapshot.identity
  ; error : error
  }

val parse_skill : directory:string -> string -> (skill, error) result
(** Parse one SKILL.md document. [directory] is the skill's directory name;
    {!Agent_core.Skill_document.decode} enforces the frontmatter contract. A
    composition block must declare exactly one composition and its [name]
    must equal the skill name. *)

val of_documents : (string * string) list -> (t, error) result
(** Build the catalog from [(directory, content)] pairs. The first failing
    document fails the whole catalog — a broken skill file is a boot error,
    never a silently missing skill. Skills are ordered by name so prompt
    rendering does not depend on directory scan order. *)

val of_snapshot :
  Skill_catalog_snapshot.t -> t * projection_diagnostic list
(** Project effective snapshot entries into the temporary composition-tool
    catalog. Snapshot order is preserved. A composition projection failure
    keeps the standard Skill as an instruction and returns a diagnostic; it
    never rejects the snapshot or turn. *)

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
(** Model-invocable composition entries with their exact snapshot provenance.
    Catalogs built directly from document strings carry [None]; production
    snapshot projections carry [Some provenance]. *)

val composition_entries : t -> Keeper_tool_composition_catalog.entry list
(** The validated composition entries declared by composition skills, in
    catalog (name) order. The tool surface materializes these exactly like
    entries from [tool-compositions.toml]. *)

val surface_to_string : surface -> string
(** ["instruction"] or ["composition"] — diagnostics and dashboard wire. *)

val provenance_to_yojson : provenance -> Yojson.Safe.t

val error_code : error -> string
val error_to_string : error -> string
