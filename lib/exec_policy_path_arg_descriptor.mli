(** Path-argument descriptors consulted by [Exec_policy] before the
    [looks_like_path_token] heuristic. See [exec_policy_path_arg_descriptor.ml]
    for design intent. *)

val is_path_flag : string -> bool
(** [is_path_flag token] returns [true] when [token] introduces a path
    in *separated* flag/value form (e.g. [-C], [--git-dir]). The
    *value* follows as the next argv token. *)

val path_flag_requires_existing_dir : string -> bool
(** [path_flag_requires_existing_dir token] is [true] when the value
    of [token] (a path flag in separated form) must point at an
    existing directory at policy-check time. *)

val path_value_of_flagged_token : string -> string option
(** [path_value_of_flagged_token token] returns the path payload of an
    *inline* flag=value form (e.g. ["--git-dir=/repo/.git"]). Returns
    [None] for tokens that do not match an inline path flag. *)

val inline_path_flag_requires_existing_dir : string -> bool
(** [inline_path_flag_requires_existing_dir token] returns [true] when
    the inline flag=value form requires the value to be an existing
    directory (currently only ["--work-tree=..."]). *)

val command_materializes_path_arg : string -> bool
(** [command_materializes_path_arg command_name] is [true] when the
    positional argv tokens of [command_name] are paths.

    Closed set: see [path_arg_command_corpus].

    [git] and [gh] are *not* in the corpus; their positional args are
    revisions/refs/issue-numbers, not paths, and they are validated by
    typed surfaces ([Exec_policy.git_revisionish_token] and
    [Keeper_gh_shared]) instead. *)

val path_arg_command_corpus : string list
(** The documented closed set used by [command_materializes_path_arg].
    Exposed so tests can assert the descriptor stays in sync. *)
