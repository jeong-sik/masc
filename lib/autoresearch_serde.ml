(** Autoresearch_serde — JSON serialization and deserialization for autoresearch types.

    Converts cycle_record, loop_state, persisted_summary, and swarm_link
    to/from Yojson.Safe.t.

    @since 2.80.0 *)

include Autoresearch_types

let decision_to_string = function Keep -> "keep" | Discard -> "discard"

let decision_of_string = function
  | "keep" -> Keep
  | "discard" -> Discard
  | s -> invalid_arg (Printf.sprintf "Unknown decision: %s" s)

let status_to_string = function
  | Running -> "running"
  | Completed -> "completed"
  | Stopped -> "stopped"
  | Error -> "error"

let status_of_string = function
  | "running" -> Some Running
  | "completed" -> Some Completed
  | "stopped" -> Some Stopped
  | "error" -> Some Error
  | _ -> None

let cycle_to_yojson (r : cycle_record) : Yojson.Safe.t =
  `Assoc [
    ("cycle", `Int r.cycle);
    ("hypothesis", `String r.hypothesis);
    ("score_before", `Float r.score_before);
    ("score_after", `Float r.score_after);
    ("delta", `Float r.delta);
    ("decision", `String (decision_to_string r.decision));
    ("commit_hash", match r.commit_hash with
      | Some h -> `String h | None -> `Null);
    ("elapsed_ms", `Int r.elapsed_ms);
    ("model_used", `String r.model_used);
    ("timestamp", `Float r.timestamp);
  ]

let cycle_of_yojson (json : Yojson.Safe.t) : cycle_record =
  let open Yojson.Safe.Util in
  {
    cycle = json |> member "cycle" |> to_int;
    hypothesis = json |> member "hypothesis" |> to_string;
    score_before = json |> member "score_before" |> to_float;
    score_after = json |> member "score_after" |> to_float;
    delta = json |> member "delta" |> to_float;
    decision = json |> member "decision" |> to_string |> decision_of_string;
    commit_hash = json |> member "commit_hash" |> to_string_option;
    elapsed_ms = json |> member "elapsed_ms" |> to_int;
    model_used = json |> member "model_used" |> to_string;
    timestamp = json |> member "timestamp" |> to_float;
  }

let state_to_yojson (s : loop_state) : Yojson.Safe.t =
  `Assoc [
    ("loop_id", `String s.loop_id);
    ("goal", `String s.goal);
    ("metric_fn", `String s.metric_fn);
    ("model_model", `String s.model_model);
    ("target_file", `String s.target_file);
    ("status", `String (status_to_string s.status));
    ("current_cycle", `Int s.current_cycle);
    ("baseline", `Float s.baseline);
    ("best_score", `Float s.best_score);
    ("best_cycle", `Int s.best_cycle);
    ( "queued_hypothesis",
      match s.queued_hypothesis with
      | Some value -> `String value
      | None -> `Null );
    ("total_keeps", `Int s.total_keeps);
    ("total_discards", `Int s.total_discards);
    ("max_cycles", `Int s.max_cycles);
    ("cycle_timeout_s", `Float s.cycle_timeout_s);
    ("workdir", `String s.workdir);
    ("source_workdir", `String s.source_workdir);
    ("elapsed_s", `Float (Time_compat.now () -. s.start_time));
    ("history_count", `Int (List.length s.history));
    ("insights_count", `Int (List.length s.insights));
    ( "program_note",
      match s.program_note with
      | Some value -> `String value
      | None -> `Null );
    ("warnings", `List (List.map (fun value -> `String value) s.warnings));
    ("error", match s.error_message with
      | Some e -> `String e | None -> `Null);
  ]

let state_of_yojson (json : Yojson.Safe.t) : persisted_summary =
  let open Yojson.Safe.Util in
  {
    loop_id = json |> member "loop_id" |> to_string;
    status =
      (json |> member "status" |> to_string |> status_of_string)
      |> Option.value ~default:Error;
    current_cycle = json |> member "current_cycle" |> to_int;
    baseline = json |> member "baseline" |> to_float;
    best_score = json |> member "best_score" |> to_float;
    best_cycle = json |> member "best_cycle" |> to_int;
    queued_hypothesis = json |> member "queued_hypothesis" |> to_string_option;
    total_keeps = json |> member "total_keeps" |> to_int;
    total_discards = json |> member "total_discards" |> to_int;
    goal = json |> member "goal" |> to_string;
    metric_fn = json |> member "metric_fn" |> to_string;
    model_model = json |> member "model_model" |> to_string;
    target_file = json |> member "target_file" |> to_string;
    workdir = json |> member "workdir" |> to_string;
    cycle_timeout_s = json |> member "cycle_timeout_s" |> to_float;
    max_cycles = json |> member "max_cycles" |> to_int;
    error_message = json |> member "error" |> to_string_option;
    elapsed_s = json |> member "elapsed_s" |> to_float;
    source_workdir =
      json |> member "source_workdir" |> to_string_option
      |> Option.value ~default:(json |> member "workdir" |> to_string);
    program_note = json |> member "program_note" |> to_string_option;
    warnings =
      match json |> member "warnings" with
      | `List items ->
          items
          |> List.filter_map (function
               | `String value ->
                   let trimmed = String.trim value in
                   if trimmed = "" then None else Some trimmed
               | _ -> None)
      | _ -> [];
  }

let swarm_link_to_yojson (link : swarm_link) : Yojson.Safe.t =
  `Assoc
    [
      ("loop_id", `String link.loop_id);
      ("session_id", `String link.session_id);
      ( "operation_id",
        match link.operation_id with Some value -> `String value | None -> `Null );
      ("target_file", `String link.target_file);
      ( "program_note",
        match link.program_note with Some value -> `String value | None -> `Null );
      ( "created_by",
        match link.created_by with Some value -> `String value | None -> `Null );
      ("linked_at", `Float link.linked_at);
    ]

let swarm_link_of_yojson (json : Yojson.Safe.t) : swarm_link =
  let open Yojson.Safe.Util in
  {
    loop_id = json |> member "loop_id" |> to_string;
    session_id = json |> member "session_id" |> to_string;
    operation_id = json |> member "operation_id" |> to_string_option;
    target_file = json |> member "target_file" |> to_string;
    program_note = json |> member "program_note" |> to_string_option;
    created_by = json |> member "created_by" |> to_string_option;
    linked_at = json |> member "linked_at" |> to_float;
  }
