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

val backfill_line : string -> string option
(** [backfill_line line] is [Some rewritten] when the line is a user
    row without a [mentions] field whose content parses to at least one
    mention id; [None] when the line needs no rewrite (kept
    byte-for-byte), including unparseable lines. *)

val backfill_file : dry_run:bool -> string -> file_report
(** Backfill one lane file.  With [dry_run] the file is not modified;
    the report counts what would change. *)

val backfill_base_path : dry_run:bool -> string -> file_report list
(** Backfill every [.jsonl] lane under
    [<base_path>/.masc/keeper_chat/].  Missing directory returns []. *)
