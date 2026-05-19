(** Repo-wide shell scan detection for the keeper bash safety policy.

    Pure-function predicates over parsed shell commands. Given a parsed
    [Keeper_shell_bash_words.shell_word list], decide whether a [grep]/
    [find]/[rg]/[git log --all] invocation walks the entire repo.

    Used by [keeper_shell_bash] to block (or rewrite) repo-wide scans
    that would blow the keeper context window. *)

open Keeper_shell_bash_words

(** [has_malformed_dev_null_redirect_token text] detects malformed
    redirect tokens such as ["0/dev/null"] where the user forgot the
    space-before-[>]. Returns [true] on a positive match. *)
val has_malformed_dev_null_redirect_token : string -> bool

(** [strip_trailing_slashes text] removes a run of [/] characters from
    the right side of [text] (used to normalize path roots before
    comparison). *)
val strip_trailing_slashes : string -> string

(** [is_repo_wide_root text] returns [true] when [text] designates the
    repo root or [repos/] subtree as a search root. *)
val is_repo_wide_root : string -> bool

(** [is_scoped_read_root text] returns [true] when [text] designates a
    known scoped subtree (e.g. [lib], [test], [bin], [docs], [src],
    [repos/<id>], or anything with a [/]). *)
val is_scoped_read_root : string -> bool

(** [option_consumes_next_arg text] returns [true] if [text] is a CLI
    option that consumes the next positional argument (e.g. [-e PATTERN],
    [--exclude DIR]). *)
val option_consumes_next_arg : string -> bool

(** [non_option_args words] returns the positional (non-flag) arguments
    of [words], skipping over options that consume the next argument. *)
val non_option_args : shell_word list -> string list

(** [grep_has_recursive_flag args] returns [true] if [args] contains
    [-r], [-R], or a short-flag bundle including [r] or [R]. *)
val grep_has_recursive_flag : shell_word list -> bool

(** [grep_is_repo_wide args] returns [true] when [grep] with [args]
    would walk the entire repo. *)
val grep_is_repo_wide : shell_word list -> bool

(** [find_is_repo_wide args] returns [true] when [find] with [args]
    starts at the repo root. *)
val find_is_repo_wide : shell_word list -> bool

(** [rg_has_files_mode args] returns [true] if [args] contains
    [--files]. *)
val rg_has_files_mode : shell_word list -> bool

(** [rg_is_repo_wide args] returns [true] when [rg] with [args] would
    walk the entire repo. *)
val rg_is_repo_wide : shell_word list -> bool

(** [git_log_all_is_repo_wide args] returns [true] when [git log --all]
    is run without an explicit output limit ([-n N], [-N], or
    [--max-count]). *)
val git_log_all_is_repo_wide : shell_word list -> bool

(** [simple_command_is_repo_wide_scan words] returns [true] when [words]
    is a single command (after [strip_command_wrappers]) that performs
    a repo-wide scan. *)
val simple_command_is_repo_wide_scan : shell_word list -> bool

(** [command_has_repo_wide_scan cmd] returns [true] when [cmd] (raw
    shell text) contains any repo-wide scan, including inside
    [bash -c "..."] payloads. *)
val command_has_repo_wide_scan : string -> bool
