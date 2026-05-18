(** Coord Worktree - Lifecycle (create / remove / list / link). *)

val link_worktree_to_task :
  Coord_utils_backend_setup.config ->
  task_id:string ->
  worktree_info:Masc_domain.worktree_info ->
  (unit, Masc_domain.masc_error) result

val worktree_create_r :
  ?link_task:bool ->
  ?repo_name:string ->
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  base_branch:string ->
  string Masc_domain.masc_result

val worktree_remove_r :
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  string Masc_domain.masc_result

val worktree_list : Coord_utils.config -> Yojson.Safe.t
