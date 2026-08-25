(** Skill_definition — one [SKILL.md] read into the two fields masc uses.

    Agent Skills is an open standard: [name] is optional and defaults to the
    directory name, [description] is what a runtime is expected to carry, and a
    conforming runtime ignores keys it does not recognise. A skill written for OpenClaw carries [metadata.openclaw],
    one written for Hermes carries [metadata.hermes], and the same file is
    expected to load in both. Rejecting a file for carrying another runtime's
    keys would break that contract, so unknown keys are dropped here.

    This is the opposite of [Tool_definition_toml], and deliberately. That
    loader is fail-closed because [config/tools/*.toml] is masc's own contract
    with itself — a key it does not know is masc's bug. A [SKILL.md] is not
    masc's contract; it is someone else's file that masc agreed to read.

    What is still fail-closed is the description masc depends on: a skill
    without one tells a keeper nothing about when it applies, so it is [Error]
    rather than a blank that surfaces later as an empty prompt block. A missing
    name is not an error — the directory supplies it, which is what a task
    references anyway. [Missing_name] therefore only reaches a caller that
    passes an empty directory name.

    RFC skills-declared-not-discovered §4.1. *)

type t =
  { name : string
  ; description : string
  ; model_invocable : bool
        (** [false] when the frontmatter carries
            [disable-model-invocation: true]. The standard field says the
            author does not want a model reaching for this on its own, so a
            composition skill that sets it stays off the model-visible tool
            surface. Ignoring it would let a declared intent be silently
            reversed. *)
  ; body : string
        (** Everything after the frontmatter, verbatim. Not trimmed to a
            summary: a task that names a skill has already chosen it, so the
            whole instruction goes to the keeper rather than a teaser it would
            have to open. *)
  }

type load_error =
  | Missing_name
  | Missing_description
  | Name_mismatch of
      { declared : string
      ; directory : string
      }
      (** The frontmatter [name] disagrees with the directory the file was
          found in. Tasks reference skills by the name they see on disk, so a
          file that renames itself would answer to a name no task can write. *)

val load : directory_name:string -> contents:string -> (t, load_error) result
(** [load ~directory_name ~contents] parses one [SKILL.md].

    [directory_name] is the skill's directory basename, which is the name
    tasks use. The file's own [name] must equal it.

    Frontmatter keys other than [name] and [description] are ignored, whatever
    runtime they were written for. *)

val load_error_to_string : load_error -> string
(** A single line naming the file's defect, for the operator who has to fix
    it. *)
