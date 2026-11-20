(** The task backlog as the TUI reads it (RFC-tui-backlog-read).

    A writer's commit gives [tasks/backlog.json] a new file version on almost
    every refresh of a busy fleet, and a commit changes a task or two of
    about 1,500. This reader decodes only the task rows whose bytes are not
    the bytes of a row it decoded before. Its answer is the one
    {!Workspace_backlog.read_backlog_observation_with_source_r} gives for
    the same file, and every answer it does not take from the bytes itself
    -- a document it does not take apart, a row that does not decode, a
    missing file, the recovery copy -- is that function's own. *)

val read :
  Workspace_utils_backend_setup.config ->
  (Workspace_backlog.backlog_observation, string) result
(** [read config] is the backlog observation of [config]'s workspace. While
    the file keeps its version (device, inode, size and modification time)
    it is the value read last, physically. Reads are meant to come one at a
    time; a read that overlaps another reads without the kept rows and gives
    the same answer. *)
