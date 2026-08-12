(** Read a keeper's per-turn raw traces for operator inspection.

    A turn record carries a [raw_trace_run_ref] naming the file that holds what
    the turn actually did — the assistant blocks, the tool calls, the hook
    decisions. Until now nothing served that file: the pointer reached the
    dashboard type and the content had no route, so the only way to read a turn
    was to open the JSONL on the host.

    {1 Containment}

    A turn is addressed by keeper name and file name, never by path. The name is
    validated as a keeper identity and the file name must be a bare basename
    ending in the raw-trace extension, so a caller cannot name a file outside
    [Keeper_types_support.keeper_raw_trace_dir]. Directory traversal is rejected
    rather than normalized: a request that tries to leave the keeper's directory
    is a different request from one that stays, and answering it as if it stayed
    would hide the attempt. *)

(** What the listing established about one turn file's records.

    Listing reads a bounded prefix of each file rather than the whole thing, so
    a turn larger than that budget yields its identity but not its count. The
    two cases are separate constructors because a count that was never taken
    and a count of zero are different facts, and a listing that reported the
    prefix's line count as the file's would be reporting a wrong number. *)
type record_census =
  | Whole_file of { records : int }
      (** The file fit the listing budget. [records] is its exact non-blank
          JSONL line count, and every one of those records carried the same
          identity. *)
  | Prefix_only of { budget_bytes : int }
      (** The file is larger than [budget_bytes]. Use {!read_turn}, which reads
          it in full and reports [total_records]. *)

type turn_summary =
  { file : string (** Bare file name, the handle later reads take. *)
  ; trace_id : string option
        (** Unique typed session identifier of the first retained record.
            [None] is possible only for an empty file; a malformed, missing,
            duplicate, or invalid identity rejects the listing. Under
            [Whole_file] every record was checked to carry this same identity;
            under [Prefix_only] only the first was, because establishing it for
            the rest would mean reading the file the budget exists to bound. *)
  ; bytes : int (** Whole-file size, from the same descriptor as the prefix. *)
  ; modified_at : float
  ; census : record_census
  }

type read_error =
  | Unknown_keeper of string
  | Invalid_file_name of string
  | No_such_turn of string
  | Invalid_trace_record of { file : string; line : int; detail : string }
  | Read_failed of { file : string; detail : string }

val read_error_to_string : read_error -> string

(** Recent turns for one keeper, newest first, at most [limit]. An absent
    directory is an empty list — a keeper that has not run yet has no traces,
    which is not an error.

    Cost is one bounded prefix read per retained file — never the whole of any
    turn, so the call no longer scales with how much a single turn wrote. (A
    stat-first pass that read content only for the returned page was measured
    and rejected: each owned read crosses a systhread, and the extra pass cost
    more than the content it avoided.) A single runaway turn used to make this
    call take seconds for every operator who opened the panel; see
    {!record_census}. *)
val list_turns :
  config:Workspace.config
  -> keeper:string
  -> limit:int
  -> (turn_summary list, read_error) result

type turn_record =
  { raw : string (** Literal non-blank JSONL line, before decoding. *)
  ; parsed : (Yojson.Safe.t, string) result
        (** Typed view of the same line, or its exact decode failure. *)
  }

type turn_records =
  { file : string
  ; total_records : int (** Non-blank lines in the file, independent of [limit]. *)
  ; offset : int
  ; records : turn_record list
  }

(** One turn's records in file order, at most [limit] starting at [offset].
    A line that is not valid JSON is returned as [Error] in place rather than
    dropped: a trace with a torn line is a different observation from a shorter
    trace, and the operator reading it is the one who has to tell them apart. *)
val read_turn :
  config:Workspace.config
  -> keeper:string
  -> file:string
  -> offset:int
  -> limit:int
  -> (turn_records, read_error) result

val turn_summary_to_json : turn_summary -> Yojson.Safe.t
val turn_records_to_json : turn_records -> Yojson.Safe.t
