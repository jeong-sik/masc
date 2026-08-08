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

type turn_summary =
  { file : string (** Bare file name, the handle later reads take. *)
  ; trace_id : string option
        (** Unique typed session identifier shared by every retained record.
            [None] is possible only for an empty file; malformed, missing,
            duplicate, invalid, or mixed identities reject the listing. *)
  ; bytes : int
  ; modified_at : float
  ; records : int (** Non-blank JSONL lines. *)
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
    which is not an error. *)
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
