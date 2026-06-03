(** Contract fixtures for Jsonl_writer.

    These fixtures encode the behavioral contract of the JSONL writer module:
    - dated_path layout is UTC-based (YYYY-MM/DD.jsonl)
    - append_dated_jsonl creates intermediate directories
    - append_jsonl produces one valid JSON line per call
    - repeated appends to the same path preserve row ordering

    They are intended for use by contract tests and catalog verification. *)

(** A dated path fixture: known timestamp → expected layout. *)
type dated_path_fixture =
  { ts : float
  ; base_dir : string
  ; expected_month_dir : string
  ; expected_day_file : string
  ; expected_path : string
  }

let dated_path_fixtures : dated_path_fixture list =
  [ { ts = 0.0
    ; base_dir = "/tmp/audit"
    ; expected_month_dir = "1970-01"
    ; expected_day_file = "01.jsonl"
    ; expected_path = "/tmp/audit/1970-01/01.jsonl"
    }
  ; { ts = 1_704_067_200.0
    ; base_dir = "/data/logs"
    ; expected_month_dir = "2024-01"
    ; expected_day_file = "01.jsonl"
    ; expected_path = "/data/logs/2024-01/01.jsonl"
    }
  ; { ts = 1_735_689_600.0
    ; base_dir = "/var/masc"
    ; expected_month_dir = "2025-01"
    ; expected_day_file = "01.jsonl"
    ; expected_path = "/var/masc/2025-01/01.jsonl"
    }
  ]
;;

(** A write fixture: json value → expected serialized form. *)
type write_fixture =
  { label : string
  ; input_json : Yojson.Safe.t
  ; expected_line : string
  }

let write_fixtures : write_fixture list =
  [ { label = "assoc with string"
    ; input_json = `Assoc [ ("kind", `String "adapter"); ("n", `Int 1) ]
    ; expected_line = "{\"kind\":\"adapter\",\"n\":1}"
    }
  ; { label = "string"
    ; input_json = `String "hello"
    ; expected_line = "\"hello\""
    }
  ; { label = "int"
    ; input_json = `Int 42
    ; expected_line = "42"
    }
  ; { label = "nested list"
    ; input_json = `List [ `Int 1; `Int 2; `Int 3 ]
    ; expected_line = "[1,2,3]"
    }
  ; { label = "bool true"
    ; input_json = `Bool true
    ; expected_line = "true"
    }
  ; { label = "null"
    ; input_json = `Null
    ; expected_line = "null"
    }
  ]
;;

(** Contract invariants for the JSONL writer. *)
let contract_invariants =
  [ "dated_path_uses_utc_gmtime"
  ; "dated_path_layout_is_YYYY_MM_slash_DD_jsonl"
  ; "append_jsonl_produces_valid_single_json_line"
  ; "append_dated_jsonl_creates_intermediate_dirs"
  ; "repeated_appends_preserve_row_order"
  ]
;;

(** Eval criteria for contract catalog integration.

    Returns the JSON shape matching [Masc_cdal_runtime.Criteria.
    Contract_catalog_invariants]. Kept as raw JSON here (not the typed
    variant) because [jsonl_writer] is a leaf sub-library that intentionally
    does not depend on [cdal_runtime]. Consumers that need the typed form
    can pass the value through [Masc_cdal_runtime.Criteria.of_yojson],
    which auto-routes contract_catalog shapes by required-field detection. *)
let eval_criteria =
  `Assoc
    [ ("contract_name", `String "jsonl-writer")
    ; ("description", `String "JSONL writer behavioral contract fixtures")
    ; ( "invariants"
      , `List (List.map (fun inv -> `String inv) contract_invariants) )
    ]
;;