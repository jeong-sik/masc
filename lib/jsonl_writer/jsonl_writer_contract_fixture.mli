(** Contract fixtures for Jsonl_writer.

    These fixtures encode the behavioral contract of the JSONL writer module:
    - dated_path layout is UTC-based (YYYY-MM/DD.jsonl)
    - append_dated_jsonl creates intermediate directories
    - append_jsonl produces one valid JSON line per call
    - repeated appends to the same path preserve row ordering

    They are intended for use by contract tests and catalog verification. *)

(** A dated path fixture: known timestamp -> expected layout. *)
type dated_path_fixture =
  { ts : float
  ; base_dir : string
  ; expected_month_dir : string
  ; expected_day_file : string
  ; expected_path : string
  }

val dated_path_fixtures : dated_path_fixture list

(** A write fixture: json value -> expected serialized form. *)
type write_fixture =
  { label : string
  ; input_json : Yojson.Safe.t
  ; expected_line : string
  }

val write_fixtures : write_fixture list

val contract_invariants : string list

val eval_criteria : Yojson.Safe.t
