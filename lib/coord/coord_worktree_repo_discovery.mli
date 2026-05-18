(** Coord Worktree - Repo discovery & task-evidence scoring.

    Decides which sandbox clone (or workspace repo) a task should land on
    when the caller does not pass [repo_name] explicitly. *)

type repo_candidate = {
  name : string;
  path : string;
}

val workspace_repo_matches :
  search_root:String.t ->
  repo_name:string ->
  ?max_dirs:int ->
  ?max_entries:int ->
  unit ->
  String.t list
(** Return absolute paths of every directory under [search_root] whose
    basename equals [repo_name] and which looks like a git checkout. *)

val git_origin_url : string -> string option
(** [git -C root config --get remote.origin.url], or [None] if unset. *)

val infer_task_repo_name :
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  (string option, Masc_domain.masc_error) result
(** Pick the repo_name for a task using sandbox clones and task
    evidence.  Returns [Ok None] when there is no usable candidate;
    [Error _] for ambiguous matches. *)
