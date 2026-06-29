(** MASC-owned memory facade. *)

type state_snapshot =
  Keeper_memory_policy.keeper_state_snapshot = {
  priority : int option;
  goal : string option;
  progress : string option;
  done_summary : string option;
  next_summary : string option;
  next_items : string list;
  decisions : string list;
  open_questions : string list;
  constraints : string list;
}

type line =
  Keeper_memory_policy.keeper_memory_line = {
  kind : string;
  text : string;
  priority : int;
  ts_unix : float;
}

type summary =
  Keeper_memory_policy.keeper_memory_summary = {
  total_notes : int;
  last_ts_unix : float;
  top_kind : string option;
  kind_counts : (string * int) list;
  recent_notes : line list;
}

type compaction_source =
  Keeper_memory_policy.compaction_source =
    Pre_dispatch_hygiene
  | MASC_policy
  | Memory_bank

type compaction_error =
  Keeper_memory_policy.compaction_error =
    Read_error
  | Write_error of string
  | Schema_mismatch

type compaction =
  Keeper_memory_policy.memory_bank_compaction = {
  performed : bool;
  source : compaction_source option;
  target_notes : int;
  before_notes : int;
  after_notes : int;
  dropped_notes : int;
  dedup_dropped : int;
  invalid_dropped : int;
  dropped_by_kind : (string * int) list;
  error : compaction_error option;
}

type read_error = Keeper_memory_recall_exn_class.t

type consolidation_summarizer =
  Keeper_memory_bank.memory_consolidation_summarizer

type t = {
  state_snapshot : state_snapshot;
  bank_summary : summary;
  last_compaction : compaction;
}

let empty_summary =
  {
    total_notes = 0;
    last_ts_unix = 0.0;
    top_kind = None;
    kind_counts = [];
    recent_notes = [];
  }

let make
    ?(state_snapshot = Keeper_memory_policy.empty_keeper_state_snapshot)
    ?(bank_summary = empty_summary)
    ?(last_compaction = Keeper_memory_policy.no_memory_bank_compaction)
    ()
  =
  { state_snapshot; bank_summary; last_compaction }

let empty = make ()

let state_snapshot memory = memory.state_snapshot
let bank_summary memory = memory.bank_summary
let last_compaction memory = memory.last_compaction

let compaction_source_to_string =
  Keeper_memory_policy.compaction_source_to_string

let compaction_source_of_string_opt =
  Keeper_memory_policy.compaction_source_of_string_opt

let default_max_bytes = 128 * 1024
let default_max_lines = 500
let default_recent_limit = 10

let read_summary
    ~config
    ~name
    ?(max_bytes = default_max_bytes)
    ?(max_lines = default_max_lines)
    ?(recent_limit = default_recent_limit)
    ()
  =
  Keeper_memory_recall.read_keeper_memory_summary_result
    config
    ~name
    ~max_bytes
    ~max_lines
    ~recent_limit

let read ~config ~name ?max_bytes ?max_lines ?recent_limit () =
  match read_summary ~config ~name ?max_bytes ?max_lines ?recent_limit () with
  | Error _ as err -> err
  | Ok bank_summary ->
    let state_snapshot =
      match Keeper_memory_policy.read_progress_snapshot ~config ~name with
      | Some snapshot -> snapshot
      | None -> Keeper_memory_policy.empty_keeper_state_snapshot
    in
    Ok (make ~state_snapshot ~bank_summary ())

let append_from_reply
    config
    meta
    ?snapshot
    ?state_snapshot_source
    ~turn
    ~reply
    ()
  =
  Keeper_memory_bank.append_memory_notes_from_reply
    config
    meta
    ?snapshot
    ?state_snapshot_source
    ~turn
    ~reply
    ()

let append_from_tool_results config meta ~turn ~results =
  Keeper_memory_bank.append_memory_notes_from_tool_results
    config
    meta
    ~turn
    ~results

let compact_if_needed ?summarizer config meta =
  Keeper_memory_bank.compact_memory_bank_if_needed ?summarizer config meta

let summary_to_json = Keeper_memory_bank.memory_summary_to_json

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null

let compaction_to_json (compaction : compaction) : Yojson.Safe.t =
  `Assoc
    [
      ("performed", `Bool compaction.performed);
      ( "source",
        compaction.source
        |> Option.map compaction_source_to_string
        |> json_string_opt );
      ("target_notes", `Int compaction.target_notes);
      ("before_notes", `Int compaction.before_notes);
      ("after_notes", `Int compaction.after_notes);
      ("dropped_notes", `Int compaction.dropped_notes);
      ("dedup_dropped", `Int compaction.dedup_dropped);
      ("invalid_dropped", `Int compaction.invalid_dropped);
      ( "dropped_by_kind",
        `List
          (List.map
             (fun (kind, count) ->
               `Assoc [ ("kind", `String kind); ("count", `Int count) ])
             compaction.dropped_by_kind) );
      ( "error",
        match compaction.error with
        | None -> `Null
        | Some Read_error -> `String "read_error"
        | Some (Write_error msg) -> `Assoc [ ("write_error", `String msg) ]
        | Some Schema_mismatch -> `String "schema_mismatch" );
    ]

let to_json (memory : t) : Yojson.Safe.t =
  `Assoc
    [
      ( "state_snapshot",
        Keeper_memory_policy.keeper_state_snapshot_to_json
          memory.state_snapshot );
      ("bank_summary", summary_to_json memory.bank_summary);
      ("last_compaction", compaction_to_json memory.last_compaction);
    ]
