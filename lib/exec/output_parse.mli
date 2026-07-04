(** P10: Structured Output Extraction

    Pure-function parsers that turn raw command output into
    machine-readable JSON fields.  Every parser is total and returns
    [Some json] on a confident match or [None] to decline (fail-open).

    Inspired by agent harness literature ("harness-engineering" et al.):
    agents waste tokens on fragile regex parsing of raw text.  This
    layer turns common outputs into typed JSON that the agent can
    consume directly. *)

val try_parse :
  cmd:string -> status:Unix.process_status -> output:string -> Yojson.Safe.t option
(** Top-level dispatcher.  Examines [cmd] to select a parser, then
    feeds [output] through it.  Returns [None] when no parser matches
    or when the output does not conform to the expected format. *)

type git_status_porcelain_summary = {
  changed_files : int;
  staged_files : int;
  unstaged_files : int;
  untracked_files : int;
  conflicted_files : int;
  staged_paths : string list;
  unstaged_paths : string list;
  untracked_paths : string list;
  conflicted_paths : string list;
}
(** Typed summary of Git porcelain-v1 status rows. A file with both index and
    worktree changes increments [changed_files] once and may appear in both
    [staged_paths] and [unstaged_paths]. *)

val summarize_git_status_porcelain :
  string -> (git_status_porcelain_summary, string) result
(** Parse [git status --porcelain=v1] output. Empty output is a clean tree.
    Malformed or unknown status rows return [Error _] so production callers can
    fail loud, while {!try_parse} still declines with [None]. *)

val utf8_truncate : string -> int -> string
(** [utf8_truncate s max_bytes] truncates [s] at a UTF-8 character
    boundary.  Exported for consumers that need safe truncation
    outside of [Exec_buffer.render]. *)
