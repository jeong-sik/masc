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
    ("commit_hash", Json_util.string_opt_to_json r.commit_hash);
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
    ("queued_hypothesis", Json_util.string_opt_to_json s.queued_hypothesis);
    ("total_keeps", `Int s.total_keeps);
    ("total_discards", `Int s.total_discards);
    ("max_cycles", `Int s.max_cycles);
    ("cycle_timeout_s", `Float s.cycle_timeout_s);
    ("workdir", `String s.workdir);
    ("source_workdir", `String s.source_workdir);
    ("elapsed_s", `Float (Time_compat.now () -. s.start_time));
    ("updated_at", `Float s.updated_at);
    ("history_count", `Int (List.length s.history));
    ("insights_count", `Int (List.length s.insights));
    ("program_note", Json_util.string_opt_to_json s.program_note);
    ("warnings", `List (List.map (fun value -> `String value) s.warnings));
    ("patience", `Int s.patience);
    ("consecutive_discards", `Int s.consecutive_discards);
    ("build_verify_fn", Json_util.string_opt_to_json s.build_verify_fn);
    ("lower_is_better", `Bool s.lower_is_better);
    ("error", Json_util.string_opt_to_json s.error_message);
  ]

let state_of_yojson (json : Yojson.Safe.t) : persisted_summary =
  let open Yojson.Safe.Util in
  let str key ~default = json |> member key |> to_string_option |> Option.value ~default in
  let required_str key =
    match json |> member key |> to_string_option |> Option.map String.trim with
    | Some value when value <> "" -> value
    | _ ->
        raise
          (Invalid_argument
             (Printf.sprintf
                "missing required autoresearch state field: %s" key))
  in
  let int_ key ~default = Safe_ops.json_int ~default key json in
  let float_ key ~default = Safe_ops.json_float ~default key json in
  {
    loop_id = required_str "loop_id";
    status = status_of_string (required_str "status") |> Option.value ~default:Error;
    current_cycle = int_ "current_cycle" ~default:0;
    baseline = float_ "baseline" ~default:0.0;
    best_score = float_ "best_score" ~default:0.0;
    best_cycle = int_ "best_cycle" ~default:0;
    queued_hypothesis = json |> member "queued_hypothesis" |> to_string_option;
    total_keeps = int_ "total_keeps" ~default:0;
    total_discards = int_ "total_discards" ~default:0;
    goal = str "goal" ~default:"";
    metric_fn = str "metric_fn" ~default:"";
    model_model = str "model_model" ~default:"";
    target_file = str "target_file" ~default:"";
    workdir = str "workdir" ~default:".";
    cycle_timeout_s = float_ "cycle_timeout_s" ~default:300.0;
    max_cycles = int_ "max_cycles" ~default:10;
    error_message = json |> member "error" |> to_string_option;
    elapsed_s = float_ "elapsed_s" ~default:0.0;
    updated_at = Safe_ops.json_float_opt "updated_at" json;
    source_workdir =
      json |> member "source_workdir" |> to_string_option
      |> Option.value ~default:(str "workdir" ~default:".");
    program_note = json |> member "program_note" |> to_string_option;
    warnings =
      (match json |> member "warnings" with
      | `List items ->
          items
          |> List.filter_map (function
               | `String value ->
                   let trimmed = String.trim value in
                   if trimmed = "" then None else Some trimmed
               | _ -> None)
      | _ -> []);
    patience = int_ "patience" ~default:(max 3 (int_ "max_cycles" ~default:10 / 3));
    consecutive_discards = int_ "consecutive_discards" ~default:0;
    build_verify_fn = json |> member "build_verify_fn" |> to_string_option;
    lower_is_better = Safe_ops.json_bool ~default:false "lower_is_better" json;
  }

let swarm_link_to_yojson (link : swarm_link) : Yojson.Safe.t =
  `Assoc
    [
      ("loop_id", `String link.loop_id);
      ("session_id", `String link.session_id);
      ("operation_id", Json_util.string_opt_to_json link.operation_id);
      ("task_id", Json_util.string_opt_to_json link.task_id);
      ("target_file", `String link.target_file);
      ("program_note", Json_util.string_opt_to_json link.program_note);
      ("created_by", Json_util.string_opt_to_json link.created_by);
      ("linked_at", `Float link.linked_at);
    ]

let swarm_link_of_yojson (json : Yojson.Safe.t) : swarm_link =
  let open Yojson.Safe.Util in
  {
    loop_id = json |> member "loop_id" |> to_string;
    session_id = json |> member "session_id" |> to_string;
    operation_id = json |> member "operation_id" |> to_string_option;
    task_id = json |> member "task_id" |> to_string_option;
    target_file = json |> member "target_file" |> to_string;
    program_note = json |> member "program_note" |> to_string_option;
    created_by = json |> member "created_by" |> to_string_option;
    linked_at = json |> member "linked_at" |> to_float;
  }
