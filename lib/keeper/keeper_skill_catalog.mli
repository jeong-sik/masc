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

type skill = private
  { name : string
  ; description : string
  ; body : string
        (** Everything after the frontmatter, including any composition
            fence, exactly as {!Agent_core.Skill_document} returned it. *)
  ; conformance : Agent_core.Skill_document.conformance
        (** Specification diagnostics retained for the turn and operator
            projections. Runtime-compatible documents remain usable. *)
  ; surface : surface
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
  | Removed_allowed_tools of { skill : string }
  | Removed_invocation_policy of
      { skill : string
      ; field : string
      }
  | Duplicate_skill of { name : string }

val parse_skill : directory:string -> string -> (skill, error) result
(** Parse one SKILL.md document. [directory] is the skill's directory name;
    {!Agent_core.Skill_document.decode} enforces the frontmatter contract. A
    composition block must declare exactly one composition and its [name]
    must equal the skill name. *)

type rejection =
  { directory : string
  ; error : error
  }

val of_documents : (string * string) list -> t * rejection list
(** The catalog these documents make, and the documents that did not make it.

    A document this cannot read is left out and named rather than taking the
    catalog with it. Failing the whole load protected against a turn believing
    it has a skill it does not have; leaving the document out protects against
    that too, since the skill is simply absent. What it cost was every turn on
    the workspace -- including the turn that would remove the document, which
    is reachable because the sources are declared read-write.

    The rejections come back beside the catalog rather than inside it: a caller
    has to hold them to get the skills. Dropping them on the floor is the
    failure this must not become. *)
(** Build the catalog from [(directory, content)] pairs. The first failing
    document fails the whole catalog — a broken skill file is a boot error,
    never a silently missing skill. Skills are ordered by name so prompt
    rendering does not depend on directory scan order. *)

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

val composition_entries : t -> Keeper_tool_composition_catalog.entry list
(** The validated composition entries declared by composition skills, in
    catalog (name) order. The tool surface materializes these directly from
    the effective Skill snapshot. *)

val surface_to_string : surface -> string
(** ["instruction"] or ["composition"] — diagnostics and dashboard wire. *)

val error_to_string : error -> string
