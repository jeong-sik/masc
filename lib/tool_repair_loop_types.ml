module U = Yojson.Safe.Util

type tool_result = bool * string

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t option;
  clock : 'a Eio.Time.clock option;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type target_mode =
  | Snippet
  | Repo

type repair_status =
  | Running
  | Passed
  | Repairable_failure
  | Terminal_failure
  | Stopped
  | Timed_out

type attempt_phase =
  | Provided
  | Generate
  | Repair

type attempt_classification =
  | Attempt_passed
  | Attempt_repairable
  | Attempt_terminal
  | Attempt_timed_out

type validator_result = {
  command : string list;
  cwd : string;
  exit_code : int;
  stdout : string;
  stderr : string;
  timed_out : bool;
  duration_sec : float;
}

type attempt_record = {
  attempt_index : int;
  phase : attempt_phase;
  started_at : float;
  finished_at : float;
  code_path : string;
  code_preview : string;
  validation : validator_result;
  classification : attempt_classification;
  summary : string;
}

type state = {
  loop_id : string;
  plugin_id : string;
  target_mode : target_mode;
  task_spec : string;
  working_dir : string;
  target_file : string option;
  validator_profile : string;
  model_label : string;
  max_attempts : int;
  attempt_count : int;
  artifact_session_id : string;
  status : repair_status;
  last_error : string option;
  source_text : string option;
  current_code : string option;
  attempts : attempt_record list;
  created_at : float;
  updated_at : float;
  stopped_at : float option;
}

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let preview ?(limit = 320) value =
  let trimmed = String.trim value in
  if String.length trimmed <= limit then trimmed
  else String.sub trimmed 0 limit ^ "..."

let target_mode_to_string = function
  | Snippet -> "snippet"
  | Repo -> "repo"

let target_mode_of_string = function
  | "repo" -> Repo
  | _ -> Snippet

let repair_status_to_string = function
  | Running -> "running"
  | Passed -> "passed"
  | Repairable_failure -> "repairable_failure"
  | Terminal_failure -> "terminal_failure"
  | Stopped -> "stopped"
  | Timed_out -> "timed_out"

let repair_status_of_string = function
  | "passed" -> Passed
  | "repairable_failure" -> Repairable_failure
  | "terminal_failure" -> Terminal_failure
  | "stopped" -> Stopped
  | "timed_out" -> Timed_out
  | _ -> Running

let attempt_phase_to_string = function
  | Provided -> "provided"
  | Generate -> "generate"
  | Repair -> "repair"

let attempt_phase_of_string = function
  | "provided" -> Provided
  | "repair" -> Repair
  | _ -> Generate

let attempt_classification_to_string = function
  | Attempt_passed -> "passed"
  | Attempt_repairable -> "repairable"
  | Attempt_terminal -> "terminal"
  | Attempt_timed_out -> "timed_out"

let attempt_classification_of_string = function
  | "passed" -> Attempt_passed
  | "terminal" -> Attempt_terminal
  | "timed_out" -> Attempt_timed_out
  | _ -> Attempt_repairable

let json_string_opt key json =
  match U.member key json with
  | `String value -> trim_nonempty value
  | _ -> None

let json_int_opt key json =
  match U.member key json with
  | `Int value -> Some value
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let json_float_opt key json =
  match U.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> Option.map float_of_int (int_of_string_opt raw)
  | _ -> None

let json_bool_opt key json =
  match U.member key json with
  | `Bool value -> Some value
  | _ -> None

let json_list_string key json =
  match U.member key json with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value -> trim_nonempty value
           | _ -> None)
  | _ -> []

let validator_result_to_json (result : validator_result) =
  `Assoc
    [
      ("command", `List (List.map (fun item -> `String item) result.command));
      ("cwd", `String result.cwd);
      ("exit_code", `Int result.exit_code);
      ("stdout", `String result.stdout);
      ("stderr", `String result.stderr);
      ("timed_out", `Bool result.timed_out);
      ("duration_sec", `Float result.duration_sec);
    ]

let validator_result_of_json (json : Yojson.Safe.t) : validator_result =
  {
    command = json_list_string "command" json;
    cwd = Option.value ~default:"." (json_string_opt "cwd" json);
    exit_code = Option.value ~default:1 (json_int_opt "exit_code" json);
    stdout = Option.value ~default:"" (json_string_opt "stdout" json);
    stderr = Option.value ~default:"" (json_string_opt "stderr" json);
    timed_out = Option.value ~default:false (json_bool_opt "timed_out" json);
    duration_sec = Option.value ~default:0.0 (json_float_opt "duration_sec" json);
  }

let attempt_record_to_json (attempt : attempt_record) =
  `Assoc
    [
      ("attempt_index", `Int attempt.attempt_index);
      ("phase", `String (attempt_phase_to_string attempt.phase));
      ("started_at", `Float attempt.started_at);
      ("finished_at", `Float attempt.finished_at);
      ("code_path", `String attempt.code_path);
      ("code_preview", `String attempt.code_preview);
      ("validation", validator_result_to_json attempt.validation);
      ( "classification",
        `String (attempt_classification_to_string attempt.classification) );
      ("summary", `String attempt.summary);
    ]

let attempt_record_of_json (json : Yojson.Safe.t) : attempt_record =
  {
    attempt_index = Option.value ~default:0 (json_int_opt "attempt_index" json);
    phase =
      json_string_opt "phase" json
      |> Option.map attempt_phase_of_string
      |> Option.value ~default:Generate;
    started_at = Option.value ~default:0.0 (json_float_opt "started_at" json);
    finished_at = Option.value ~default:0.0 (json_float_opt "finished_at" json);
    code_path = Option.value ~default:"" (json_string_opt "code_path" json);
    code_preview = Option.value ~default:"" (json_string_opt "code_preview" json);
    validation =
      (match U.member "validation" json with
       | `Assoc _ as payload -> validator_result_of_json payload
       | _ ->
           {
             command = [];
             cwd = ".";
             exit_code = 1;
             stdout = "";
             stderr = "";
             timed_out = false;
             duration_sec = 0.0;
           });
    classification =
      json_string_opt "classification" json
      |> Option.map attempt_classification_of_string
      |> Option.value ~default:Attempt_repairable;
    summary = Option.value ~default:"" (json_string_opt "summary" json);
  }

let state_to_json (state : state) =
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("plugin_id", `String state.plugin_id);
      ("target_mode", `String (target_mode_to_string state.target_mode));
      ("task_spec", `String state.task_spec);
      ("working_dir", `String state.working_dir);
      ( "target_file",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.target_file );
      ("validator_profile", `String state.validator_profile);
      ("model_label", `String state.model_label);
      ("max_attempts", `Int state.max_attempts);
      ("attempt_count", `Int state.attempt_count);
      ("artifact_session_id", `String state.artifact_session_id);
      ("status", `String (repair_status_to_string state.status));
      ( "last_error",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.last_error );
      ( "source_text",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.source_text );
      ( "current_code",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.current_code );
      ( "attempts",
        `List (List.map attempt_record_to_json state.attempts) );
      ("created_at", `Float state.created_at);
      ("updated_at", `Float state.updated_at);
      ( "stopped_at",
        Option.fold ~none:`Null ~some:(fun value -> `Float value)
          state.stopped_at );
    ]

let state_of_json (json : Yojson.Safe.t) : state =
  {
    loop_id = Option.value ~default:"repair-loop" (json_string_opt "loop_id" json);
    plugin_id = Option.value ~default:"ocaml" (json_string_opt "plugin_id" json);
    target_mode =
      json_string_opt "target_mode" json
      |> Option.map target_mode_of_string
      |> Option.value ~default:Snippet;
    task_spec = Option.value ~default:"" (json_string_opt "task_spec" json);
    working_dir = Option.value ~default:"." (json_string_opt "working_dir" json);
    target_file = json_string_opt "target_file" json;
    validator_profile =
      Option.value ~default:"snippet_ocamlc" (json_string_opt "validator_profile" json);
    model_label =
      Option.value ~default:Env_config.Local_runtime.default_model (json_string_opt "model_label" json);
    max_attempts = Option.value ~default:2 (json_int_opt "max_attempts" json);
    attempt_count = Option.value ~default:0 (json_int_opt "attempt_count" json);
    artifact_session_id =
      Option.value ~default:"repair-loop" (json_string_opt "artifact_session_id" json);
    status =
      json_string_opt "status" json
      |> Option.map repair_status_of_string
      |> Option.value ~default:Running;
    last_error = json_string_opt "last_error" json;
    source_text = json_string_opt "source_text" json;
    current_code = json_string_opt "current_code" json;
    attempts =
      (match U.member "attempts" json with
       | `List values -> List.map attempt_record_of_json values
       | _ -> []);
    created_at = Option.value ~default:(Time_compat.now ()) (json_float_opt "created_at" json);
    updated_at = Option.value ~default:(Time_compat.now ()) (json_float_opt "updated_at" json);
    stopped_at = json_float_opt "stopped_at" json;
  }

let state_status_json (state : state) =
  let latest_attempt =
    match List.rev state.attempts with
    | latest :: _ -> Some latest
    | [] -> None
  in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("plugin_id", `String state.plugin_id);
      ("status", `String (repair_status_to_string state.status));
      ("attempt_count", `Int state.attempt_count);
      ("max_attempts", `Int state.max_attempts);
      ( "last_error",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.last_error );
      ( "current_code_preview",
        Option.fold ~none:`Null ~some:(fun value -> `String (preview value))
          state.current_code );
      ( "latest_attempt",
        Option.fold ~none:`Null ~some:attempt_record_to_json latest_attempt );
      ( "attempts",
        `List (List.map attempt_record_to_json state.attempts) );
    ]

let is_terminal_status = function
  | Passed | Terminal_failure | Stopped | Timed_out -> true
  | Running | Repairable_failure -> false

let status_of_json (json : Yojson.Safe.t) =
  json_string_opt "status" json |> Option.map repair_status_of_string
