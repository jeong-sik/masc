(** The one JSON shape for a repository's Git working-tree answer. Both
    [GET /api/v1/git/status] and [GET /api/v1/repositories/:id/changes] build
    their body here, so the TUI decoder reads one shape from either. *)

(** [snapshot ~scope ~branch ~changes] is
    [{scope; branch; changes; total}]. [branch.head] is null for a detached
    HEAD. [branch.upstream] is null without a configured upstream; its
    [ahead]/[behind] are null when the configured upstream ref is gone. *)
val snapshot
  :  scope:Yojson.Safe.t
  -> branch:Repo_git.branch_status
  -> changes:Repo_git.status_file list
  -> Yojson.Safe.t

(** [upstream_json upstream] is the [upstream] member shared by the status
    answer's [branch] and each entry of the branch list: null without an
    upstream, otherwise [{name; ahead; behind}] with null counts when the
    configured upstream ref is gone. *)
val upstream_json : Repo_git.upstream_state -> Yojson.Safe.t
