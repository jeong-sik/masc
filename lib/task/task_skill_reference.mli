(** Validation of task-declared SKILL.md references at authoring time. *)

val validate_all : base_path:string -> string list -> (unit, string) result
(** Every name must be one portable path segment and resolve to a regular
    [<base_path>/.masc/skills/<name>/SKILL.md] accepted by the canonical
    {!Agent_core.Skill_document} decoder. Empty input succeeds. *)
