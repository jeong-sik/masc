(** Keeper_chat_backfill — offline mention backfill for keeper chat
    lanes (RFC-0232 §3.3 / P4).

    Rows written before P4 carry no [mentions] field; at read time they
    decode as "no mentions", so an unanswered pre-P4 "@name" line would
    stop registering as pending once observation switches to persisted
    ids.  This tool stamps those rows offline: for every user row
    without a [mentions] field whose content yields mention ids under
    the boundary parser ({!Keeper_lane_mentions.mention_ids_of_content}),
    it rewrites the row with the parsed ids.  All other lines are
    preserved byte-for-byte; rewrites are atomic per file (temp file +
    rename).

    Offline contract: run while the server is stopped — a concurrent
    appender can lose lines to the read-rewrite-rename window. *)

type file_report = {
  path : string;
  total_lines : int;
  rewritten : int;
}

type line_result =
  | Line_unchanged
  | Line_rewritten of string
  | Line_error of string

type file_error = {
  path : string;
  line_no : int;
  message : string;
}

val backfill_line : string -> line_result
(** [backfill_line line] is [Line_rewritten rewritten] when the line is a user
    row without a [mentions] field whose content parses to at least one mention
    id. Rows that need no rewrite are [Line_unchanged]. Malformed JSON,
    non-object rows, malformed existing [mentions], or malformed required chat
    fields are [Line_error _]. *)

val backfill_file : dry_run:bool -> string -> (file_report, file_error list) result
(** Backfill one lane file. If any row returns [Line_error _], the file is not
    rewritten and all row errors are returned. With [dry_run] the file is not
    modified; the report counts what would change. *)

val backfill_base_path :
  dry_run:bool -> string -> (file_report list, file_error list) result
(** Backfill every [.jsonl] lane under
    [<base_path>/.masc/keeper_chat/].  Missing directory returns []. *)
