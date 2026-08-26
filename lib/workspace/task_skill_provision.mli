(** Task_skill_provision — Provisioning of task-declared skills into per-keeper sandbox. *)

val provision_skills :
  base_path:string ->
  keeper_name:string ->
  string list ->
  (unit, string) result
(** Copy skill directory contents from [<base_path>/.masc/skills/<name>/]
    into [<base_path>/.masc/playground/<keeper>/.masc/skills/<name>/]
    for each skill in the given list. Returns [Ok ()] if empty or all succeed. *)
