(** Append-only shared workspace memory log with two-phase batch visibility
    (Prepared -> Change* -> Committed | Aborted) and deterministic crash
    recovery (RFC-shared-memory-appends-a-log-and-keepers-read-from-their-position). *)

type batch_id = string
type seq = int

type batch_header = {
  batch_id : batch_id;
  author : string;
  started_at : string;
  expected_changes : int;
}

type change_entry = {
  seq : seq;
  batch_id : batch_id;
  fact_id : string;
  summary : string;
  payload : Yojson.Safe.t;
  recorded_at : string;
}

type log_record =
  | Prepared of batch_header
  | Change of change_entry
  | Committed of { batch_id : batch_id; committed_at : string; final_seq : seq }
  | Aborted of { batch_id : batch_id; aborted_at : string; reason : string }

type error =
  | Unknown_record_kind of string
  | Missing_field of string
  | Invalid_field of { field : string; detail : string }
  | Malformed_json of string
  | Io_error of string
  | Invalid_batch of string

val error_to_string : error -> string

type recovery_report = {
  committed_changes : change_entry list;
  incomplete_batches : batch_header list;
  aborted_batches : batch_id list;
  last_committed_seq : seq;
}

val record_to_yojson : log_record -> Yojson.Safe.t
val record_of_yojson : Yojson.Safe.t -> (log_record, error) result

val record_to_json_line : log_record -> string
val record_of_json_line : string -> (log_record, error) result

val recover : log_record list -> recovery_report
(** Fold log records deterministically. Only [Change] records belonging to a
    [Prepared] batch that has a subsequent matching [Committed] record (with
    matching [expected_changes] count and [final_seq]) are included in
    [committed_changes]. Batches that are [Prepared] without a matching
    [Committed] or [Aborted] record at EOF are reported in
    [incomplete_batches]. *)

val log_path : base_path:string -> string
(** Default log path under [<base_path>/.masc/workspace-memory/log.jsonl]. *)

val append_record : path:string -> log_record -> (unit, error) result
(** Append a single JSONL record line to [path]. *)

val append_batch
  :  path:string
  -> header:batch_header
  -> changes:change_entry list
  -> committed_at:string
  -> (seq, error) result
(** Under an exclusive file lock on [path ^ ".lock"], load the current log's
    [last_committed_seq], validate that [header.batch_id] is fresh and
    [changes] match [header.batch_id], [header.expected_changes], and strictly
    increasing [seq] numbers greater than [last_committed_seq], then append
    [Prepared], all [Change] records, and [Committed], returning [final_seq]. *)

val load_log : path:string -> (log_record list, error) result
(** Load all complete (newline-terminated) JSONL records from [path]. Returns
    [Ok []] if [path] does not exist. A trailing fragment without a terminating
    newline at EOF is ignored as an incomplete mid-append write; any malformed
    complete line in the file returns [Error]. *)

val abort_incomplete_batches
  :  path:string
  -> aborted_at:string
  -> reason:string
  -> recovery_report
  -> (recovery_report, error) result
(** Append an [Aborted] record to [path] for every batch in
    [recovery_report.incomplete_batches] and return the updated recovery
    report with [incomplete_batches = []]. *)

val recover_file : path:string -> (recovery_report, error) result
(** Load [path] and compute [recover] over its JSONL records. *)
