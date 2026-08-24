(** SKILL.md-backed catalog of Keeper skills (RFC skills-as-tools).

    One directory declares one skill: [<skills-dir>/<name>/SKILL.md]. The
    frontmatter carries the Agent Skills required pair ([name] /
    [description]); unknown frontmatter keys from other runtimes are ignored
    so a skill file shared with Claude Code or OpenClaw loads unchanged.

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
            fence. [keeper_skill] serves this text verbatim. *)
  ; surface : surface
  }

type t

type error =
  | Missing_name of { directory : string }
  | Missing_description of { skill : string }
  | Directory_name_mismatch of
      { directory : string
      ; declared : string
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

val parse_skill : directory:string -> string -> (skill, error) result
(** Parse one SKILL.md document. [directory] is the skill's directory name;
    the declared frontmatter [name] must equal it exactly, so a copied file
    cannot silently ship under two names. A composition block must declare
    exactly one composition and its [name] must equal the skill name. *)

val of_documents : (string * string) list -> (t, error) result
(** Build the catalog from [(directory, content)] pairs. The first failing
    document fails the whole catalog — a broken skill file is a boot error,
    never a silently missing skill. Skills are ordered by name so prompt
    rendering does not depend on directory scan order. *)

val empty : t
val skills : t -> skill list
val find : t -> string -> skill option

val surface_to_string : surface -> string
(** ["instruction"] or ["composition"] — diagnostics and dashboard wire. *)

val error_to_string : error -> string
