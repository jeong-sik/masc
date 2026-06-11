(** Keeper_person_notes — deliberate per-speaker memory (RFC-0229 P1).

    Append-only JSONL per keeper:
    [<base_dir>/.masc/keeper_person_notes/<name>.jsonl], rows
    [{"speaker_id":"98791450001","note":"...","ts":1781400000.0}].

    A note exists only because the keeper called
    [keeper_person_note_set] in a turn — no automatic extraction, no
    background writer. The current note per speaker is the last row
    (fold-at-read, latest wins); a blank note row is a tombstone, so
    deletion needs no delete operation. Volume grows with deliberate
    writes only, so reads are whole-file at v1 (revisit with a tail
    bound only if measured otherwise). *)

(** [set_note ~base_dir ~keeper_name ~speaker_id ~note ()] appends one
    note row. Blank [note] clears. Failures are logged and counted
    ([PersonNoteStoreFailures]), never raised past
    {!Eio.Cancel.Cancelled} — same policy as the chat store appends. *)
val set_note :
  base_dir:string ->
  keeper_name:string ->
  speaker_id:string ->
  note:string ->
  unit ->
  unit

(** [notes ~base_dir ~keeper_name] folds the file into the current
    note per speaker: latest row wins, tombstoned (blank) entries are
    absent. Missing file is []. Unparseable lines are skipped and
    counted as persistence read drops. *)
val notes : base_dir:string -> keeper_name:string -> (string * string) list
