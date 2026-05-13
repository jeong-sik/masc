(** Autoresearch_serde — JSON serialization and deserialization for autoresearch types.

    Converts cycle_record, loop_state, persisted_summary, and execution_link
    to/from Yojson.Safe.t.

    @since 2.80.0 *)

include Autoresearch_types

let decision_to_string = function Keep -> "keep" | Discard -> "discard"

let decision_of_string_result = function
  | "keep" -> Ok Keep
  | "discard" -> Ok Discard
  | s -> Stdlib.Error (Printf.sprintf "unknown decision: %s" s)

let status_to_string = function
  | Running -> "running"
  | Completed -> "completed"
  | Stopped -> "stopped"
  | Error -> "error"

let status_of_string_result = function
  | "running" -> Ok Running
  | "completed" -> Ok Completed
  | "stopped" -> Ok Stopped
  | "error" -> Ok Error
  | s -> Stdlib.Error (Printf.sprintf "unknown status: %s" s)

let ( let* ) result f =
  match result with
  | Ok value -> f value
  | Stdlib.Error _ as error -> error

let yojson_type_name = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ | `Intlit _ -> "int"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let field_error kind field message =
  Printf.sprintf "%s.%s: %s" kind field message

let required_string_field kind json field =
  match Yojson.Safe.Util.member field json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then
        Stdlib.Error (field_error kind field "empty string")
      else
        Ok trimmed
  | value ->
      Stdlib.Error
        (field_error kind field
           (Printf.sprintf "expected string, got %s" (yojson_type_name value)))

let optional_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `Null -> Ok None
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then Ok None else Ok (Some trimmed)
  | value ->
      Stdlib.Error
        (Printf.sprintf "%s: expected string or null, got %s" field
           (yojson_type_name value))

let redacted_runtime_label = "runtime"

let redacted_runtime_model_field json field =
  match optional_string_field json field with
  | Ok _ -> Ok redacted_runtime_label
  | Stdlib.Error _ as error -> error

let required_int_field kind json field =
  match Yojson.Safe.Util.member field json with
  | `Int value -> Ok value
  | `Intlit value -> (
      match int_of_string_opt value with
      | Some parsed -> Ok parsed
      | None -> Stdlib.Error (field_error kind field "invalid int literal"))
  | value ->
      Stdlib.Error
        (field_error kind field
           (Printf.sprintf "expected int, got %s" (yojson_type_name value)))

let optional_int_field json field =
  match Yojson.Safe.Util.member field json with
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | `Intlit value -> (
      match int_of_string_opt value with
      | Some parsed -> Ok (Some parsed)
      | None -> Stdlib.Error (Printf.sprintf "%s: invalid int literal" field))
  | value ->
      Stdlib.Error
        (Printf.sprintf "%s: expected int or null, got %s" field
           (yojson_type_name value))

let required_float_field kind json field =
  match Yojson.Safe.Util.member field json with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some parsed -> Ok parsed
      | None -> Stdlib.Error (field_error kind field "invalid float literal"))
  | value ->
      Stdlib.Error
        (field_error kind field
           (Printf.sprintf "expected float, got %s" (yojson_type_name value)))

let optional_float_field json field =
  match Yojson.Safe.Util.member field json with
  | `Null -> Ok None
  | `Float value -> Ok (Some value)
  | `Int value -> Ok (Some (float_of_int value))
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some parsed -> Ok (Some parsed)
      | None -> Stdlib.Error (Printf.sprintf "%s: invalid float literal" field))
  | value ->
      Stdlib.Error
        (Printf.sprintf "%s: expected float or null, got %s" field
           (yojson_type_name value))

let loop_target_reached (state : loop_state) =
  match state.target_score with
  | None -> false
  | Some target ->
      if state.lower_is_better then state.best_score <= target
      else state.best_score >= target

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
    ("model_used", `Null);
    ("timestamp", `Float r.timestamp);
  ]

let cycle_of_yojson_result (json : Yojson.Safe.t) : (cycle_record, string) result =
  let kind = "cycle_record" in
  let* cycle = required_int_field kind json "cycle" in
  let* hypothesis = required_string_field kind json "hypothesis" in
  let* score_before = required_float_field kind json "score_before" in
  let* score_after = required_float_field kind json "score_after" in
  let* delta = required_float_field kind json "delta" in
  let* decision =
    match Yojson.Safe.Util.member "decision" json with
    | `String value -> decision_of_string_result (String.trim value)
    | value ->
        Stdlib.Error
          (field_error kind "decision"
             (Printf.sprintf "expected string, got %s" (yojson_type_name value)))
  in
  let* commit_hash = optional_string_field json "commit_hash" in
  let* elapsed_ms = required_int_field kind json "elapsed_ms" in
  let* model_used = redacted_runtime_model_field json "model_used" in
  let* timestamp = required_float_field kind json "timestamp" in
  Ok
    {
      cycle;
      hypothesis;
      score_before;
      score_after;
      delta;
      decision;
      commit_hash;
      elapsed_ms;
      model_used;
      timestamp;
    }

let state_to_yojson (s : loop_state) : Yojson.Safe.t =
  `Assoc [
    ("loop_id", `String s.loop_id);
    ("author", Json_util.string_opt_to_json s.author);
    ("goal", `String s.goal);
    ("metric_fn", `String s.metric_fn);
    ("model_model", `String s.model_model);
    ("target_file", `String s.target_file);
    ("target_score", Json_util.float_opt_to_json s.target_score);
    ("target_reached", `Bool (loop_target_reached s));
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

let state_of_yojson_result (json : Yojson.Safe.t) : (persisted_summary, string) result =
  let kind = "persisted_summary" in
  let* loop_id = required_string_field kind json "loop_id" in
  let* author = optional_string_field json "author" in
  let* status =
    match Yojson.Safe.Util.member "status" json with
    | `String value -> status_of_string_result (String.trim value)
    | value ->
        Stdlib.Error
          (field_error kind "status"
             (Printf.sprintf "expected string, got %s" (yojson_type_name value)))
  in
  let* current_cycle = required_int_field kind json "current_cycle" in
  let* baseline = required_float_field kind json "baseline" in
  let* best_score = required_float_field kind json "best_score" in
  let* best_cycle = required_int_field kind json "best_cycle" in
  let* queued_hypothesis = optional_string_field json "queued_hypothesis" in
  let* total_keeps = required_int_field kind json "total_keeps" in
  let* total_discards = required_int_field kind json "total_discards" in
  let* goal = required_string_field kind json "goal" in
  let* metric_fn = required_string_field kind json "metric_fn" in
  let* model_model = required_string_field kind json "model_model" in
  let* target_file = required_string_field kind json "target_file" in
  let* target_score = optional_float_field json "target_score" in
  let* workdir = required_string_field kind json "workdir" in
  let* cycle_timeout_s = required_float_field kind json "cycle_timeout_s" in
  let* max_cycles = required_int_field kind json "max_cycles" in
  let* error_message = optional_string_field json "error" in
  let* elapsed_s = required_float_field kind json "elapsed_s" in
  let* updated_at = optional_float_field json "updated_at" in
  let* source_workdir =
    match optional_string_field json "source_workdir" with
    | Ok (Some value) -> Ok value
    | Ok None -> Ok workdir
    | Stdlib.Error _ as error -> error
  in
  let* program_note = optional_string_field json "program_note" in
  let* warnings =
    match Yojson.Safe.Util.member "warnings" json with
    | `List values -> (
        let rec collect acc = function
          | [] -> Ok (List.rev acc)
          | `String value :: rest ->
              let trimmed = String.trim value in
              if trimmed = "" then
                collect acc rest
              else
                collect (trimmed :: acc) rest
          | _ :: rest -> collect acc rest
        in
        collect [] values)
    | _ -> Ok []
  in
  let patience =
    match Yojson.Safe.Util.member "patience" json with
    | `Int value -> value
    | `Intlit value -> (
        match int_of_string_opt value with
        | Some parsed -> parsed
        | None -> max 3 (max_cycles / 3))
    | _ -> max 3 (max_cycles / 3)
  in
  let consecutive_discards =
    match Yojson.Safe.Util.member "consecutive_discards" json with
    | `Int value -> value
    | `Intlit value -> (
        match int_of_string_opt value with
        | Some parsed -> parsed
        | None -> 0)
    | _ -> 0
  in
  let* build_verify_fn = optional_string_field json "build_verify_fn" in
  let* lower_is_better =
    match Yojson.Safe.Util.member "lower_is_better" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | _ -> Ok false
  in
  Ok
    {
      loop_id;
      author;
      status;
      current_cycle;
      baseline;
      best_score;
      best_cycle;
      queued_hypothesis;
      total_keeps;
      total_discards;
      goal;
      metric_fn;
      model_model;
      target_file;
      target_score;
      workdir;
      cycle_timeout_s;
      max_cycles;
      error_message;
      elapsed_s;
      updated_at;
      source_workdir;
      program_note;
      warnings;
      patience;
      consecutive_discards;
      build_verify_fn;
      lower_is_better;
    }

let execution_link_to_yojson (link : execution_link) : Yojson.Safe.t =
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

let execution_link_of_yojson_result (json : Yojson.Safe.t) : (execution_link, string) result =
  let kind = "execution_link" in
  let* loop_id = required_string_field kind json "loop_id" in
  let* session_id = required_string_field kind json "session_id" in
  let* operation_id = optional_string_field json "operation_id" in
  let* task_id = optional_string_field json "task_id" in
  let* target_file = required_string_field kind json "target_file" in
  let* program_note = optional_string_field json "program_note" in
  let* created_by = optional_string_field json "created_by" in
  let* linked_at = required_float_field kind json "linked_at" in
  Ok
    {
      loop_id;
      session_id;
      operation_id;
      task_id;
      target_file;
      program_note;
      created_by;
      linked_at;
    }
