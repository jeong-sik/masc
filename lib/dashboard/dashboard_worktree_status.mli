(** Dashboard_worktree_status — Live worktree status surface.

    Enumerates all MASC linked worktrees and enriches each entry with
    git status counts, HEAD SHA, optional PR link, and a keeper-attached
    flag.

    SSE channel: [GET /api/dashboard/worktree-status] *)

(** {1 Types} *)

type worktree_entry = {
  worktree_path : string;
  branch : string;
  changed_count : int;
  staged_count : int;
  head_sha : string;
  pr_number : int option;
  pr_state : string option;
  keeper_attached : bool;
}

(** {1 Query} *)

val list_entries : base_path:string -> worktree_entry list
(** Enumerate all MASC worktrees under [base_path] and enrich each with
    git status counts, HEAD SHA, and keeper presence.  Non-fatal errors
    (missing git, unreadable worktrees) produce empty or zero-count
    entries rather than raising. *)

(** {1 JSON output} *)

val entry_to_json : worktree_entry -> Yojson.Safe.t

val json : base_path:string -> Yojson.Safe.t
(** Full snapshot payload: [generated_at], [count], [entries]. *)

(** {1 SSE helpers} *)

val format_sse_event : Yojson.Safe.t -> string
(** Format a JSON value as a single SSE [data:] frame (trailing
    double-newline included). *)

val sse_events : base_path:string -> string list
(** One SSE event string per worktree entry (sorted by path), plus a
    terminal [event: done\\ndata: {}\\n\\n] sentinel.  The caller
    writes these sequentially to the streaming response body and then
    closes the writer. *)
