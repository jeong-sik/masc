open Types
open Result_syntax

type record_type =
  | Run_started
  | Assistant_block
  | Tool_execution_started
  | Tool_execution_finished
  | Hook_invoked
  | Run_finished
[@@deriving yojson, show]

type run_ref =
  { worker_run_id : string
  ; path : string
  ; start_seq : int
  ; end_seq : int
  ; agent_name : string
  ; session_id : string option
  }
[@@deriving yojson, show]

type run_summary =
  { run_ref : run_ref
  ; record_count : int
  ; assistant_block_count : int
  ; tool_execution_started_count : int
  ; tool_execution_finished_count : int
  ; hook_invoked_count : int
  ; hook_names : string list
  ; tool_names : string list
  ; model : string option
  ; tool_choice : Yojson.Safe.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; thinking_budget : int option
  ; reasoning_effort : string option
  ; thinking_block_count : int
  ; text_block_count : int
  ; tool_use_block_count : int
  ; tool_result_block_count : int
  ; first_assistant_block_kind : string option
  ; selection_outcome : string
  ; saw_tool_use : bool
  ; saw_thinking : bool
  ; final_text : string option
  ; stop_reason : string option
  ; error : string option
  ; started_at : float option
  ; finished_at : float option
  }
[@@deriving yojson, show]

type validation_check =
  { name : string
  ; passed : bool
  }
[@@deriving yojson, show]

type run_validation =
  { run_ref : run_ref
  ; ok : bool
  ; checks : validation_check list
  ; evidence : string list
  ; paired_tool_result_count : int
  ; final_text : string option
  ; tool_names : string list
  ; stop_reason : string option
  ; failure_reason : string option
  }
[@@deriving yojson, show]

type record =
  { trace_version : int
  ; worker_run_id : string
  ; seq : int
  ; ts : float
  ; agent_name : string
  ; session_id : string option
  ; record_type : record_type
  ; prompt : string option
  ; model : string option
  ; tool_choice : Yojson.Safe.t option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; thinking_budget : int option
  ; reasoning_effort : string option
  ; block_index : int option
  ; block_kind : string option
  ; assistant_block : Yojson.Safe.t option
  ; tool_use_id : string option
  ; tool_name : string option
  ; tool_input : Yojson.Safe.t option
  ; tool_turn : int option
  ; tool_planned_index : int option
  ; tool_batch_index : int option
  ; tool_batch_size : int option
  ; tool_execution_mode : Tool_contract.execution_mode option
  ; tool_result : string option
  ; tool_error : bool option
  ; hook_name : string option
  ; hook_decision : string option
  ; hook_detail : string option
  ; final_text : string option
  ; stop_reason : string option
  ; error : string option
  }
[@@deriving show]

type t =
  { path : string
  ; session_id : string option
  ; lock : Eio.Mutex.t
  ; mutable next_seq : int
  ; mutable run_counter : int
  ; mutable last_run : run_ref option
  ; redact_secrets : bool
  }

type active_run =
  { sink : t
  ; worker_run_id : string
  ; agent_name : string
  ; session_id : string option
  ; mutable start_seq : int
  ; mutable end_seq : int
  ; redact_secrets : bool
  }

exception Trace_error of Error.sdk_error

let trace_version = 2
let json_parse_error = Util.json_parse_error

let safe_name name =
  let trimmed = String.trim name in
  let base = if trimmed = "" then "agent" else trimmed in
  String.map
    (function
      | '/' | '\\' | ' ' | '\t' | '\n' | '\r' -> '_'
      | c -> c)
    base
;;

let ensure_dir = Fs_result.ensure_dir

let record_type_to_string = function
  | Run_started -> "run_started"
  | Assistant_block -> "assistant_block"
  | Tool_execution_started -> "tool_execution_started"
  | Tool_execution_finished -> "tool_execution_finished"
  | Hook_invoked -> "hook_invoked"
  | Run_finished -> "run_finished"
;;

let record_type_of_string = function
  | "run_started" -> Ok Run_started
  | "assistant_block" -> Ok Assistant_block
  | "tool_execution_started" -> Ok Tool_execution_started
  | "tool_execution_finished" -> Ok Tool_execution_finished
  | "hook_invoked" -> Ok Hook_invoked
  | "run_finished" -> Ok Run_finished
  | other ->
    Error
      (Error.Serialization
         (UnknownVariant { type_name = "raw_trace.record_type"; value = other }))
;;

let option_assoc name value =
  match value with
  | Some json -> [ name, json ]
  | None -> []
;;

let option_string name value = option_assoc name (Option.map (fun v -> `String v) value)
let option_int name value = option_assoc name (Option.map (fun v -> `Int v) value)
let option_bool name value = option_assoc name (Option.map (fun v -> `Bool v) value)
let option_json name value = option_assoc name value
let tool_choice_to_json_opt value = Option.map Types.tool_choice_to_json value

let tool_choice_of_json_opt json =
  match Yojson.Safe.Util.member "tool_choice" json with
  | `Null -> Ok None
  | value ->
    let+ tool_choice = Types.tool_choice_of_json value in
    Some (Types.tool_choice_to_json tool_choice)
;;

let execution_mode_of_json_opt json =
  match Yojson.Safe.Util.member "tool_execution_mode" json with
  | `Null -> Ok None
  | value ->
    (match Tool_contract.execution_mode_of_yojson value with
     | Ok mode -> Ok (Some mode)
     | Error detail -> Error (Error.Serialization (JsonParseError { detail })))
;;

let validate_record_fields json =
  let allowed =
    [ "trace_version"
    ; "worker_run_id"
    ; "seq"
    ; "ts"
    ; "agent_name"
    ; "session_id"
    ; "record_type"
    ; "prompt"
    ; "model"
    ; "tool_choice"
    ; "enable_thinking"
    ; "preserve_thinking"
    ; "thinking_budget"
    ; "reasoning_effort"
    ; "block_index"
    ; "block_kind"
    ; "assistant_block"
    ; "tool_use_id"
    ; "tool_name"
    ; "tool_input"
    ; "tool_turn"
    ; "tool_planned_index"
    ; "tool_batch_index"
    ; "tool_batch_size"
    ; "tool_execution_mode"
    ; "tool_result"
    ; "tool_error"
    ; "hook_name"
    ; "hook_decision"
    ; "hook_detail"
    ; "final_text"
    ; "stop_reason"
    ; "error"
    ]
  in
  let removed = [ "tool_concurrency_class"; "evidence_role" ] in
  let field_error detail = Error (Error.Serialization (JsonParseError { detail })) in
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: _ when List.mem name removed ->
      field_error (Printf.sprintf "raw trace field %S has been removed" name)
    | (name, _) :: _ when not (List.mem name allowed) ->
      field_error (Printf.sprintf "raw trace field %S is not supported" name)
    | (name, _) :: _ when List.mem name seen ->
      field_error (Printf.sprintf "raw trace field %S is duplicated" name)
    | (name, _) :: rest -> loop (name :: seen) rest
  in
  match json with
  | `Assoc fields -> loop [] fields
  | _ -> field_error "raw trace record must be a JSON object"
;;

let record_to_json (record : record) =
  `Assoc
    ([ "trace_version", `Int record.trace_version
     ; "worker_run_id", `String record.worker_run_id
     ; "seq", `Int record.seq
     ; "ts", `Float record.ts
     ; "agent_name", `String record.agent_name
     ; "record_type", `String (record_type_to_string record.record_type)
     ; ( "session_id"
       , match record.session_id with
         | Some value -> `String value
         | None -> `Null )
     ]
     @ option_string "prompt" record.prompt
     @ option_string "model" record.model
     @ option_json "tool_choice" record.tool_choice
     @ option_bool "enable_thinking" record.enable_thinking
     @ option_bool "preserve_thinking" record.preserve_thinking
     @ option_int "thinking_budget" record.thinking_budget
     @ option_string "reasoning_effort" record.reasoning_effort
     @ option_int "block_index" record.block_index
     @ option_string "block_kind" record.block_kind
     @ option_json "assistant_block" record.assistant_block
     @ option_string "tool_use_id" record.tool_use_id
     @ option_string "tool_name" record.tool_name
     @ option_json "tool_input" record.tool_input
     @ option_int "tool_turn" record.tool_turn
     @ option_int "tool_planned_index" record.tool_planned_index
     @ option_int "tool_batch_index" record.tool_batch_index
     @ option_int "tool_batch_size" record.tool_batch_size
     @ option_json
         "tool_execution_mode"
         (Option.map Tool_contract.execution_mode_to_yojson record.tool_execution_mode)
     @ option_string "tool_result" record.tool_result
     @ option_bool "tool_error" record.tool_error
     @ option_string "hook_name" record.hook_name
     @ option_string "hook_decision" record.hook_decision
     @ option_string "hook_detail" record.hook_detail
     @ option_string "final_text" record.final_text
     @ option_string "stop_reason" record.stop_reason
     @ option_string "error" record.error)
;;

let record_of_json_unchecked json =
  let open Yojson.Safe.Util in
  let* () = validate_record_fields json in
  let got_version = json |> member "trace_version" |> to_int in
  let* () =
    if got_version = trace_version
    then Ok ()
    else
      Error
        (Error.Serialization
           (VersionMismatch { expected = trace_version; got = got_version }))
  in
  let* record_type = json |> member "record_type" |> to_string |> record_type_of_string in
  let* tool_choice = tool_choice_of_json_opt json in
  let* tool_execution_mode = execution_mode_of_json_opt json in
  let* () =
    match record_type, tool_execution_mode with
    | Tool_execution_started, Some _ -> Ok ()
    | Tool_execution_started, None ->
      Error
        (Error.Serialization
           (JsonParseError
              { detail = "tool_execution_started requires tool_execution_mode" }))
    | ( ( Run_started
        | Assistant_block
        | Tool_execution_finished
        | Hook_invoked
        | Run_finished )
      , None ) -> Ok ()
    | ( ( Run_started
        | Assistant_block
        | Tool_execution_finished
        | Hook_invoked
        | Run_finished )
      , Some _ ) ->
      Error
        (Error.Serialization
           (JsonParseError
              { detail = "tool_execution_mode is valid only for tool_execution_started" }))
  in
  Ok
    { trace_version = got_version
    ; worker_run_id = json |> member "worker_run_id" |> to_string
    ; seq = json |> member "seq" |> to_int
    ; ts = json |> member "ts" |> to_float
    ; agent_name = json |> member "agent_name" |> to_string
    ; session_id = json |> member "session_id" |> to_string_option
    ; record_type
    ; prompt = json |> member "prompt" |> to_string_option
    ; model = json |> member "model" |> to_string_option
    ; tool_choice
    ; enable_thinking = json |> member "enable_thinking" |> to_bool_option
    ; preserve_thinking = json |> member "preserve_thinking" |> to_bool_option
    ; thinking_budget = json |> member "thinking_budget" |> to_int_option
    ; reasoning_effort = json |> member "reasoning_effort" |> to_string_option
    ; block_index = json |> member "block_index" |> to_int_option
    ; block_kind = json |> member "block_kind" |> to_string_option
    ; assistant_block =
        (match json |> member "assistant_block" with
         | `Null -> None
         | value -> Some value)
    ; tool_use_id = json |> member "tool_use_id" |> to_string_option
    ; tool_name = json |> member "tool_name" |> to_string_option
    ; tool_input =
        (match json |> member "tool_input" with
         | `Null -> None
         | value -> Some value)
    ; tool_turn = json |> member "tool_turn" |> to_int_option
    ; tool_planned_index = json |> member "tool_planned_index" |> to_int_option
    ; tool_batch_index = json |> member "tool_batch_index" |> to_int_option
    ; tool_batch_size = json |> member "tool_batch_size" |> to_int_option
    ; tool_execution_mode
    ; tool_result = json |> member "tool_result" |> to_string_option
    ; tool_error = json |> member "tool_error" |> to_bool_option
    ; hook_name = json |> member "hook_name" |> to_string_option
    ; hook_decision = json |> member "hook_decision" |> to_string_option
    ; hook_detail = json |> member "hook_detail" |> to_string_option
    ; final_text = json |> member "final_text" |> to_string_option
    ; stop_reason = json |> member "stop_reason" |> to_string_option
    ; error = json |> member "error" |> to_string_option
    }
;;

let record_of_json json =
  try record_of_json_unchecked json with
  | Yojson.Safe.Util.Type_error (detail, _) -> Error (json_parse_error detail)
;;

let record_to_yojson = record_to_json

let record_of_yojson json =
  match record_of_json json with
  | Ok record -> Ok record
  | Error error -> Error (Error.to_string error)
;;

let parse_json_string raw =
  try Ok (Yojson.Safe.from_string raw) with
  | Yojson.Json_error detail -> Error (json_parse_error detail)
;;

let load_lines path =
  if not (Fs_result.file_exists path)
  then Ok []
  else
    let* raw = Fs_result.read_file path in
    Ok (String.split_on_char '\n' raw |> Util.filter_non_empty)
;;

let read_all ~path () =
  let* lines = load_lines path in
  lines
  |> List.map String.trim
  |> Util.filter_non_empty
  |> List.map (fun line ->
    let* json = parse_json_string line in
    record_of_json json)
  |> List.fold_left
       (fun acc item ->
          let* records = acc in
          let* record = item in
          Ok (record :: records))
       (Ok [])
  |> Result.map List.rev
;;

let scan_next_seq path =
  let* records = read_all ~path () in
  let next =
    match List.rev records with
    | [] -> 1
    | last :: _ -> last.seq + 1
  in
  Ok next
;;

let create ?(redact_secrets = true) ?session_id ~path () =
  let* () = ensure_dir (Filename.dirname path) in
  let* next_seq = scan_next_seq path in
  Ok
    { path
    ; session_id
    ; lock = Eio.Mutex.create ()
    ; next_seq
    ; run_counter = 0
    ; last_run = None
    ; redact_secrets
    }
;;

let create_for_session ?(redact_secrets = true) ?session_root ~session_id ~agent_name () =
  let* store = Runtime_store.create ?root:session_root () in
  let* () = Runtime_store.ensure_tree store session_id in
  let path =
    Filename.concat
      (Runtime_store.raw_traces_dir store session_id)
      (Printf.sprintf "%s.jsonl" (safe_name agent_name))
  in
  create ~redact_secrets ~session_id ~path ()
;;

let file_path trace = trace.path
let session_id (trace : t) = trace.session_id
let last_run trace = trace.last_run

let next_worker_run_id sink =
  let ts = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let pid = Unix.getpid () land 0xFFFF in
  let idx = sink.run_counter in
  sink.run_counter <- idx + 1;
  Printf.sprintf "wr-%08x-%04x-%04x" ts pid idx
;;

let append_locked sink (record : record) =
  let line = (record_to_json record |> Yojson.Safe.to_string) ^ "\n" in
  Fs_result.append_file sink.path line
;;

let append_record
      active
      ~record_type
      ?prompt
      ?block_index
      ?block_kind
      ?model
      ?tool_choice
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      ?reasoning_effort
      ?assistant_block
      ?tool_use_id
      ?tool_name
      ?tool_input
      ?tool_turn
      ?tool_planned_index
      ?tool_batch_index
      ?tool_batch_size
      ?tool_execution_mode
      ?tool_result
      ?tool_error
      ?hook_name
      ?hook_decision
      ?hook_detail
      ?final_text
      ?stop_reason
      ?error
      ()
  =
  Eio.Mutex.use_rw ~protect:true active.sink.lock (fun () ->
    let seq = active.sink.next_seq in
    let maybe_redact_string =
      if active.redact_secrets then Llm_provider.Secret_redactor.redact_string else Fun.id
    in
    let maybe_redact_json =
      if active.redact_secrets then Llm_provider.Secret_redactor.redact_json else Fun.id
    in
    let record =
      { trace_version
      ; worker_run_id = active.worker_run_id
      ; seq
      ; ts = Unix.gettimeofday ()
      ; agent_name = active.agent_name
      ; session_id = active.session_id
      ; record_type
      ; prompt = Option.map maybe_redact_string prompt
      ; model
      ; tool_choice
      ; enable_thinking
      ; preserve_thinking
      ; thinking_budget
      ; reasoning_effort
      ; block_index
      ; block_kind
      ; assistant_block = Option.map maybe_redact_json assistant_block
      ; tool_use_id
      ; tool_name
      ; tool_input = Option.map maybe_redact_json tool_input
      ; tool_turn
      ; tool_planned_index
      ; tool_batch_index
      ; tool_batch_size
      ; tool_execution_mode
      ; tool_result = Option.map maybe_redact_string tool_result
      ; tool_error
      ; hook_name
      ; hook_decision
      ; hook_detail = Option.map maybe_redact_string hook_detail
      ; final_text = Option.map maybe_redact_string final_text
      ; stop_reason
      ; error = Option.map maybe_redact_string error
      }
    in
    let* () = append_locked active.sink record in
    active.sink.next_seq <- seq + 1;
    if active.start_seq = 0 then active.start_seq <- seq;
    active.end_seq <- max active.end_seq seq;
    Ok seq)
;;

let start_run
      sink
      ~agent_name
      ~prompt
      ?model
      ?tool_choice
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      ?reasoning_effort
      ()
  =
  let worker_run_id =
    Eio.Mutex.use_rw ~protect:true sink.lock (fun () -> next_worker_run_id sink)
  in
  let active =
    { sink
    ; worker_run_id
    ; agent_name
    ; session_id = sink.session_id
    ; start_seq = 0
    ; end_seq = 0
    ; redact_secrets = sink.redact_secrets
    }
  in
  let+ _ =
    append_record
      active
      ~record_type:Run_started
      ~prompt
      ?model
      ?tool_choice:(tool_choice_to_json_opt tool_choice)
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      ?reasoning_effort
      ()
  in
  active
;;

let record_assistant_block active ~block_index block =
  let json = Llm_provider.Api_common.content_block_to_json block in
  let block_kind =
    match block with
    | Text _ -> "text"
    | Thinking _ -> "thinking"
    | ReasoningDetails _ -> "reasoning_details"
    | RedactedThinking _ -> "redacted_thinking"
    | ToolUse _ -> "tool_use"
    | ToolResult _ -> "tool_result"
    | Image _ -> "image"
    | Document _ -> "document"
    | Audio _ -> "audio"
  in
  append_record
    active
    ~record_type:Assistant_block
    ~block_index
    ~block_kind
    ~assistant_block:json
    ()
  |> Result.map (fun _ -> ())
;;

let record_tool_execution_started active ~invocation ~tool_name ~tool_input =
  let schedule = Tool_contract.Invocation.schedule invocation in
  append_record
    active
    ~record_type:Tool_execution_started
    ~tool_use_id:(Tool_contract.Invocation.tool_use_id invocation)
    ~tool_name
    ~tool_input
    ~tool_turn:(Tool_contract.Invocation.turn invocation)
    ~tool_planned_index:schedule.planned_index
    ~tool_batch_index:schedule.batch_index
    ~tool_batch_size:schedule.batch_size
    ~tool_execution_mode:schedule.execution_mode
    ()
  |> Result.map (fun _ -> ())
;;

let record_tool_execution_finished
      active
      ~invocation
      ~tool_name
      ~tool_result
      ~tool_error
      ()
  =
  append_record
    active
    ~record_type:Tool_execution_finished
    ~tool_use_id:(Tool_contract.Invocation.tool_use_id invocation)
    ~tool_turn:(Tool_contract.Invocation.turn invocation)
    ~tool_planned_index:(Tool_contract.Invocation.planned_index invocation)
    ~tool_name
    ~tool_result
    ~tool_error
    ()
  |> Result.map (fun _ -> ())
;;

let record_hook_invoked active ?invocation ~hook_name ~hook_decision ?hook_detail () =
  let result =
    match invocation with
    | None ->
      append_record
        active
        ~record_type:Hook_invoked
        ~hook_name
        ~hook_decision
        ?hook_detail
        ()
    | Some invocation ->
      append_record
        active
        ~record_type:Hook_invoked
        ~tool_use_id:(Tool_contract.Invocation.tool_use_id invocation)
        ~tool_turn:(Tool_contract.Invocation.turn invocation)
        ~tool_planned_index:(Tool_contract.Invocation.planned_index invocation)
        ~hook_name
        ~hook_decision
        ?hook_detail
        ()
  in
  result |> Result.map (fun _ -> ())
;;

let finish_run
      active
      ~(final_text : string option)
      ~(stop_reason : string option)
      ~(error : string option)
  =
  let* _ =
    append_record active ~record_type:Run_finished ?final_text ?stop_reason ?error ()
  in
  let run_ref =
    { worker_run_id = active.worker_run_id
    ; path = active.sink.path
    ; start_seq = active.start_seq
    ; end_seq = active.end_seq
    ; agent_name = active.agent_name
    ; session_id = active.session_id
    }
  in
  Eio.Mutex.use_rw ~protect:true active.sink.lock (fun () ->
    active.sink.last_run <- Some run_ref);
  Ok run_ref
;;

let raise_if_error : type a. (a, Error.sdk_error) result -> unit = function
  | Ok _ -> ()
  | Error err -> raise (Trace_error err)
;;

let active_run_id (active : active_run) = active.worker_run_id
