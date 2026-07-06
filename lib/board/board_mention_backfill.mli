(** Offline board mention-id backfill.

    Rows written before board-level [mention_ids] existed decode as "no
    structured mentions" at runtime. This module stamps the field offline so
    keeper wake logic can continue to consume persisted structured ids instead
    of reparsing board text at observation time.

    Offline contract: run while the server is stopped. The implementation
    reads, validates, rewrites a temp file, and renames it into place; a
    concurrent appender can lose lines to that read-rewrite-rename window. *)

type target =
  | Posts
  | Comments

type line_result =
  | Line_unchanged
  | Line_rewritten of string
  | Line_error of string

type file_error = {
  path : string;
  line_no : int;
  message : string;
}

type file_report = {
  path : string;
  target : target;
  total_lines : int;
  rewritten : int;
}

val target_to_string : target -> string
val path_for_target : base_path:string -> target -> string

val backfill_line : target:target -> string -> line_result
(** Backfill one JSONL row.

    [Line_rewritten line] is returned only when the row is a JSON object without
    [mention_ids] and explicit mention tokens are found. Rows already carrying a
    valid [mention_ids] field are [Line_unchanged]. Malformed JSON, non-object
    rows, malformed existing [mention_ids], or missing/non-string content are
    [Line_error _]. *)

val backfill_file :
  dry_run:bool -> target:target -> string -> (file_report, file_error list) result
(** Backfill one file. If any row returns [Line_error _], the file is not
    rewritten and all row errors are returned. *)

val backfill_base_path :
  dry_run:bool -> string -> (file_report list, file_error list) result
(** Backfill existing board post/comment JSONL files under the cluster-aware
    MASC root for [base_path]. Missing files are skipped. *)
