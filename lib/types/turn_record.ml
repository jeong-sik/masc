type prompt_block =
  { block : Prompt_block_id.t
  ; bytes : int
  ; digest : string
  }

type input_component_id =
  | Prompt_block of Prompt_block_id.t
  | Tool_schemas
  | Message_user
  | Message_system
  | Message_assistant_text
  | Message_thinking
  | Message_redacted_thinking
  | Message_tool_use
  | Message_tool_result
  | Message_image
  | Message_document
  | Message_audio

type input_component =
  { component : input_component_id
  ; bytes : int
  }

type sampling =
  { temperature : float option
  ; top_p : float option
  ; max_tokens : int option
  ; thinking_budget : int option
  ; enable_thinking : bool option
  }

type usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; cache_creation_input_tokens : int option
  ; cache_read_input_tokens : int option
  ; scope : Runtime_usage_scope.t
  }

type request_wire_observation =
  { runtime_profile : string
  ; body_bytes : int
  }

type model_input_measurement =
  | Wire_shape
  | Durable_shape

let model_input_measurement_to_string = function
  | Wire_shape -> "wire_shape"
  | Durable_shape -> "durable_shape"
;;

let model_input_measurement_of_string = function
  | "wire_shape" -> Ok Wire_shape
  | "durable_shape" -> Ok Durable_shape
  | other ->
    Error
      (Printf.sprintf "turn_record: unknown model_input_measurement %S" other)
;;

type model_input_window =
  { transmitted_atoms : int
  ; total_atoms : int
  ; measurement : model_input_measurement
  }

type turn_kind =
  | Autonomous
  | Direct

type raw_trace_run_ref =
  { worker_run_id : string
  ; path : string
  ; start_seq : int
  ; end_seq : int
  ; agent_name : string
  ; session_id : string
  }

type t =
  { execution_ids : Ids.Execution_id.t list
  ; keeper : string
  ; agent_name : string
  ; turn_kind : turn_kind
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; blocks : prompt_block list
  ; input_components : input_component list option
  ; runtime_profile : string
  ; selected_model : string option
  ; finish_reason : string option
  ; tool_surface_ref : string option
  ; context_window : int option
  ; price_input_per_million : float option
  ; price_output_per_million : float option
  ; request_latency_ms : int option
  ; ttfrc_ms : float option
  ; request_wire_observation : request_wire_observation option
  ; model_input_window : model_input_window option
  ; raw_trace_run_ref : raw_trace_run_ref option
  ; sampling : sampling
  ; usage : usage
  ; ts : float
  }

(* ── Codec ─────────────────────────────────────────────── *)

let opt_field name to_json = function
  | Some value -> [ (name, to_json value) ]
  | None -> []

let prompt_block_to_json (b : prompt_block) : Yojson.Safe.t =
  `Assoc
    [ ("block", `String (Prompt_block_id.to_string b.block))
    ; ("bytes", `Int b.bytes)
    ; ("digest", `String b.digest)
    ]

let input_component_id_to_string = function
  | Prompt_block block -> "prompt." ^ Prompt_block_id.to_string block
  | Tool_schemas -> "tool_schemas"
  | Message_user -> "message_user"
  | Message_system -> "message_system"
  | Message_assistant_text -> "message_assistant_text"
  | Message_thinking -> "message_thinking"
  | Message_redacted_thinking -> "message_redacted_thinking"
  | Message_tool_use -> "message_tool_use"
  | Message_tool_result -> "message_tool_result"
  | Message_image -> "message_image"
  | Message_document -> "message_document"
  | Message_audio -> "message_audio"

let input_component_to_json (component : input_component) : Yojson.Safe.t =
  `Assoc
    [ "component", `String (input_component_id_to_string component.component)
    ; "bytes", `Int component.bytes
    ]

let turn_kind_to_string = function
  | Autonomous -> "autonomous"
  | Direct -> "direct"

let turn_kind_of_string = function
  | "autonomous" -> Ok Autonomous
  | "direct" -> Ok Direct
  | value -> Error (Printf.sprintf "turn_record: unknown turn_kind %S" value)

let raw_trace_run_ref_to_json (run_ref : raw_trace_run_ref) : Yojson.Safe.t =
  `Assoc
    [ "worker_run_id", `String run_ref.worker_run_id
    ; "path", `String run_ref.path
    ; "start_seq", `Int run_ref.start_seq
    ; "end_seq", `Int run_ref.end_seq
    ; "agent_name", `String run_ref.agent_name
    ; "session_id", `String run_ref.session_id
    ]

let to_json (r : t) : Yojson.Safe.t =
  let request_runtime_profile, request_body_bytes =
    match r.request_wire_observation with
    | Some observation ->
      `String observation.runtime_profile, `Int observation.body_bytes
    | None -> `Null, `Null
  in
  let transmitted_atoms, total_atoms, model_input_measurement =
    match r.model_input_window with
    | Some window ->
      ( `Int window.transmitted_atoms
      , `Int window.total_atoms
      , `String (model_input_measurement_to_string window.measurement) )
    | None -> `Null, `Null, `Null
  in
  `Assoc
    ([ ( "execution_ids"
       , `List (List.map Ids.Execution_id.to_yojson r.execution_ids) )
     ; ("keeper", `String r.keeper)
     ; ("agent_name", `String r.agent_name)
     ; ("turn_kind", `String (turn_kind_to_string r.turn_kind))
     ; ("trace_id", `String r.trace_id)
     ; ("absolute_turn", `Int r.absolute_turn)
     ; ("turn_ref", Ids.Turn_ref.to_yojson r.turn_ref)
     ; ("blocks", `List (List.map prompt_block_to_json r.blocks))
     ; ( "input_components"
       , match r.input_components with
         | Some components ->
           `List (List.map input_component_to_json components)
         | None -> `Null )
     ; ("runtime_profile", `String r.runtime_profile)
     ; "request_runtime_profile", request_runtime_profile
     ; "request_body_bytes", request_body_bytes
     ; "transmitted_atoms", transmitted_atoms
     ; "total_atoms", total_atoms
     ; "model_input_measurement", model_input_measurement
     ; ( "raw_trace_run_ref"
       , match r.raw_trace_run_ref with
         | Some run_ref -> raw_trace_run_ref_to_json run_ref
         | None -> `Null )
     ]
    @ opt_field "selected_model" (fun v -> `String v) r.selected_model
    @ opt_field "finish_reason" (fun v -> `String v) r.finish_reason
    @ opt_field "tool_surface_ref" (fun v -> `String v) r.tool_surface_ref
    @ opt_field "context_window" (fun v -> `Int v) r.context_window
    @ opt_field "price_input_per_million" (fun v -> `Float v) r.price_input_per_million
    @ opt_field "price_output_per_million" (fun v -> `Float v) r.price_output_per_million
    @ opt_field "request_latency_ms" (fun v -> `Int v) r.request_latency_ms
    @ opt_field "ttfrc_ms" (fun v -> `Float v) r.ttfrc_ms
    @ opt_field "temperature" (fun v -> `Float v) r.sampling.temperature
    @ opt_field "top_p" (fun v -> `Float v) r.sampling.top_p
    @ opt_field "max_tokens" (fun v -> `Int v) r.sampling.max_tokens
    @ opt_field "thinking_budget" (fun v -> `Int v) r.sampling.thinking_budget
    @ opt_field "enable_thinking" (fun v -> `Bool v) r.sampling.enable_thinking
    @ opt_field "input_tokens" (fun v -> `Int v) r.usage.input_tokens
    @ opt_field "cache_creation_input_tokens" (fun v -> `Int v)
        r.usage.cache_creation_input_tokens
    @ opt_field "cache_read_input_tokens" (fun v -> `Int v)
        r.usage.cache_read_input_tokens
     @ opt_field "output_tokens" (fun v -> `Int v) r.usage.output_tokens
    @ [ ("usage_scope", `String (Runtime_usage_scope.to_string r.usage.scope)) ]
    @ [ ("ts", `Float r.ts) ])

let ( let* ) = Result.bind

let member name fields = List.assoc_opt name fields

let fields_are_unique_known known fields =
  let names = List.map fst fields in
  List.for_all (fun name -> List.mem name known) names
  && List.length names
     = List.length (List.sort_uniq String.compare names)
;;

let require name fields =
  match member name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "turn_record: missing field %S" name)

let as_string name = function
  | `String s -> Ok s
  | _ -> Error (Printf.sprintf "turn_record: field %S is not a string" name)

let as_nonempty_string name json =
  let* value = as_string name json in
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "turn_record: field %S is empty" name)
  else Ok value

let as_int name = function
  | `Int i -> Ok i
  | _ -> Error (Printf.sprintf "turn_record: field %S is not an int" name)

let as_nonnegative_int name json =
  let* value = as_int name json in
  if value < 0
  then Error (Printf.sprintf "turn_record: field %S is negative" name)
  else Ok value

let as_sha256_digest name json =
  let* value = as_string name json in
  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  if String.length value = 64 && String.for_all is_lower_hex value
  then Ok value
  else
    Error
      (Printf.sprintf
         "turn_record: field %S is not a lowercase sha256 digest"
         name)

let as_float name = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error (Printf.sprintf "turn_record: field %S is not a number" name)

let opt_member name fields decode =
  match member name fields with
  | None -> Ok None
  | Some value ->
      let* decoded = decode name value in
      Ok (Some decoded)

let nullable name fields decode =
  let* value = require name fields in
  match value with
  | `Null -> Ok None
  | value ->
      let* decoded = decode name value in
      Ok (Some decoded)

let as_bool name = function
  | `Bool b -> Ok b
  | _ -> Error (Printf.sprintf "turn_record: field %S is not a bool" name)

let as_turn_ref name json =
  match Ids.Turn_ref.of_yojson json with
  | Ok t -> Ok t
  | Error e -> Error (Printf.sprintf "turn_record: field %S: %s" name e)

let prompt_block_of_json (json : Yojson.Safe.t) : (prompt_block, string) result =
  match json with
  | `Assoc fields ->
      let* () =
        if fields_are_unique_known [ "block"; "bytes"; "digest" ] fields
        then Ok ()
        else Error "turn_record: prompt block fields are not exact"
      in
      let* block_json = require "block" fields in
      let* block_name = as_string "block" block_json in
      let* bytes_json = require "bytes" fields in
      let* bytes = as_nonnegative_int "bytes" bytes_json in
      let* digest_json = require "digest" fields in
      let* digest = as_sha256_digest "digest" digest_json in
      let* block = Prompt_block_id.of_string block_name in
      Ok { block; bytes; digest }
  | _ -> Error "turn_record: block entry is not an object"

let input_component_id_of_string token =
  match token with
  | "tool_schemas" -> Ok Tool_schemas
  | "message_user" -> Ok Message_user
  | "message_system" -> Ok Message_system
  | "message_assistant_text" -> Ok Message_assistant_text
  | "message_thinking" -> Ok Message_thinking
  | "message_redacted_thinking" -> Ok Message_redacted_thinking
  | "message_tool_use" -> Ok Message_tool_use
  | "message_tool_result" -> Ok Message_tool_result
  | "message_image" -> Ok Message_image
  | "message_document" -> Ok Message_document
  | "message_audio" -> Ok Message_audio
  | token ->
    let prefix = "prompt." in
    if String.starts_with ~prefix token
    then
      let name =
        String.sub
          token
          (String.length prefix)
          (String.length token - String.length prefix)
      in
      (match Prompt_block_id.of_string name with
       | Ok block -> Ok (Prompt_block block)
       | Error _ ->
         Error
           (Printf.sprintf "turn_record: unknown input component %S" token))
    else
      Error
        (Printf.sprintf "turn_record: unknown input component %S" token)

let input_component_of_json
    (json : Yojson.Safe.t) : (input_component, string) result =
  match json with
  | `Assoc fields ->
      let expected_fields = [ "component"; "bytes" ] in
      let* () =
        if fields_are_unique_known expected_fields fields
        then Ok ()
        else Error "turn_record: input component fields are not exact"
      in
      let* component_json = require "component" fields in
      let* component_name = as_string "component" component_json in
      let* component = input_component_id_of_string component_name in
      let* bytes_json = require "bytes" fields in
      let* bytes = as_nonnegative_int "bytes" bytes_json in
      Ok { component; bytes }
  | _ -> Error "turn_record: input component entry is not an object"

let raw_trace_run_ref_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let expected_fields =
      [ "worker_run_id"; "path"; "start_seq"; "end_seq"; "agent_name"; "session_id" ]
    in
    let* () =
      if fields_are_unique_known expected_fields fields
      then Ok ()
      else Error "turn_record: raw_trace_run_ref fields are not exact"
    in
    let* worker_run_id_json = require "worker_run_id" fields in
    let* worker_run_id = as_nonempty_string "worker_run_id" worker_run_id_json in
    let* path_json = require "path" fields in
    let* path = as_nonempty_string "path" path_json in
    let* start_seq_json = require "start_seq" fields in
    let* start_seq = as_nonnegative_int "start_seq" start_seq_json in
    let* end_seq_json = require "end_seq" fields in
    let* end_seq = as_nonnegative_int "end_seq" end_seq_json in
    let* () =
      if end_seq >= start_seq
      then Ok ()
      else Error "turn_record: raw_trace_run_ref end_seq precedes start_seq"
    in
    let* agent_name_json = require "agent_name" fields in
    let* agent_name = as_nonempty_string "agent_name" agent_name_json in
    let* session_id_json = require "session_id" fields in
    let* session_id = as_nonempty_string "session_id" session_id_json in
    Ok { worker_run_id; path; start_seq; end_seq; agent_name; session_id }
  | _ -> Error "turn_record: raw_trace_run_ref is not an object"

let rec collect_results acc = function
  | [] -> Ok (List.rev acc)
  | item :: rest -> (
      match item with
      | Ok value -> collect_results (value :: acc) rest
      | Error _ as e -> e)

let ensure_unique_blocks blocks =
  let rec loop seen = function
    | [] -> Ok blocks
    | (block : prompt_block) :: rest ->
      if
        List.exists
          (fun (seen_block : prompt_block) ->
            Prompt_block_id.equal seen_block.block block.block)
          seen
      then
        Error
          (Printf.sprintf
             "turn_record: duplicate block %S"
             (Prompt_block_id.to_string block.block))
      else loop (block :: seen) rest
  in
  loop [] blocks

let ensure_unique_input_components components =
  let rec loop seen = function
    | [] -> Ok components
    | (component : input_component) :: rest ->
      if
        List.exists
          (fun (seen_component : input_component) ->
            seen_component.component = component.component)
          seen
      then
        Error
          (Printf.sprintf
             "turn_record: duplicate input component %S"
             (input_component_id_to_string component.component))
      else loop (component :: seen) rest
  in
  loop [] components

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match json with
  | `Assoc fields ->
      let* () =
        if
          fields_are_unique_known
            [ "execution_ids"
            ; "keeper"
            ; "agent_name"
            ; "turn_kind"
            ; "trace_id"
            ; "absolute_turn"
            ; "turn_ref"
            ; "blocks"
            ; "input_components"
            ; "runtime_profile"
            ; "request_runtime_profile"
            ; "request_body_bytes"
            ; "transmitted_atoms"
            ; "total_atoms"
            ; "model_input_measurement"
            ; "raw_trace_run_ref"
            ; "selected_model"
            ; "finish_reason"
            ; "tool_surface_ref"
            ; "context_window"
            ; "price_input_per_million"
            ; "price_output_per_million"
            ; "request_latency_ms"
            ; "ttfrc_ms"
            ; "temperature"
            ; "top_p"
            ; "max_tokens"
            ; "thinking_budget"
            ; "enable_thinking"
            ; "input_tokens"
            ; "cache_creation_input_tokens"
            ; "cache_read_input_tokens"
            ; "output_tokens"
            ; "usage_scope"
            ; "ts"
            ]
            fields
        then Ok ()
        else Error "turn_record: fields are not exact"
      in
      let* ids_json = require "execution_ids" fields in
      let* execution_ids =
        match ids_json with
        | `List items ->
            collect_results [] (List.map Ids.Execution_id.of_yojson items)
        | _ -> Error "turn_record: execution_ids is not a list"
      in
      let* keeper_json = require "keeper" fields in
      let* keeper = as_nonempty_string "keeper" keeper_json in
      let* agent_name_json = require "agent_name" fields in
      let* agent_name = as_nonempty_string "agent_name" agent_name_json in
      let* turn_kind_json = require "turn_kind" fields in
      let* turn_kind_string = as_string "turn_kind" turn_kind_json in
      let* turn_kind = turn_kind_of_string turn_kind_string in
      let* trace_json = require "trace_id" fields in
      let* trace_id = as_nonempty_string "trace_id" trace_json in
      let* turn_json = require "absolute_turn" fields in
      let* absolute_turn = as_int "absolute_turn" turn_json in
      let* turn_ref_json = require "turn_ref" fields in
      let* turn_ref = as_turn_ref "turn_ref" turn_ref_json in
      let expected_turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn in
      let* () =
        if Ids.Turn_ref.equal turn_ref expected_turn_ref
        then Ok ()
        else
          Error
             "turn_record: field \"turn_ref\" does not match trace_id and \
              absolute_turn"
      in
      let* blocks_json = require "blocks" fields in
      let* blocks =
        match blocks_json with
        | `List items ->
          let* blocks =
            collect_results [] (List.map prompt_block_of_json items)
          in
          ensure_unique_blocks blocks
        | _ -> Error "turn_record: blocks is not a list"
      in
      let* input_components_json = require "input_components" fields in
      let* input_components =
        match input_components_json with
        | `List items ->
          let* components =
            collect_results [] (List.map input_component_of_json items)
          in
          let* components = ensure_unique_input_components components in
          Ok (Some components)
        | `Null -> Ok None
        | _ -> Error "turn_record: input_components is not a list or null"
      in
      let* profile_json = require "runtime_profile" fields in
      let* runtime_profile = as_string "runtime_profile" profile_json in
      let* request_runtime_profile =
        nullable "request_runtime_profile" fields as_nonempty_string
      in
      let* request_body_bytes =
        nullable "request_body_bytes" fields as_nonnegative_int
      in
      let* request_wire_observation =
        match request_runtime_profile, request_body_bytes with
        | Some runtime_profile, Some body_bytes ->
          Ok (Some { runtime_profile; body_bytes })
        | None, None -> Ok None
        | Some _, None | None, Some _ ->
          Error
            "turn_record: request_runtime_profile and request_body_bytes must \
             both be present or both be null"
      in
      let* transmitted_atoms =
        nullable "transmitted_atoms" fields as_nonnegative_int
      in
      let* total_atoms = nullable "total_atoms" fields as_nonnegative_int in
      let* measurement =
        nullable "model_input_measurement" fields (fun name json ->
          let* raw = as_nonempty_string name json in
          model_input_measurement_of_string raw)
      in
      let* model_input_window =
        match transmitted_atoms, total_atoms, measurement with
        | Some transmitted_atoms, Some total_atoms, Some measurement ->
          if transmitted_atoms > total_atoms
          then Error "turn_record: transmitted_atoms cannot exceed total_atoms"
          else Ok (Some { transmitted_atoms; total_atoms; measurement })
        | None, None, None -> Ok None
        | _ ->
          Error
            "turn_record: transmitted_atoms, total_atoms and \
             model_input_measurement must all be present or all be null"
      in
      let* raw_trace_run_ref_json = require "raw_trace_run_ref" fields in
      let* raw_trace_run_ref =
        match raw_trace_run_ref_json with
        | `Null -> Ok None
        | json ->
          let* run_ref = raw_trace_run_ref_of_json json in
          let* () =
            if String.equal run_ref.session_id trace_id
            then Ok ()
            else Error "turn_record: raw trace session_id does not match trace_id"
          in
          Ok (Some run_ref)
      in
      let* selected_model = opt_member "selected_model" fields as_nonempty_string in
      let* finish_reason = opt_member "finish_reason" fields as_string in
      let* tool_surface_ref =
        opt_member "tool_surface_ref" fields as_nonempty_string
      in
      let* context_window = opt_member "context_window" fields as_int in
      let* price_input_per_million = opt_member "price_input_per_million" fields as_float in
      let* price_output_per_million = opt_member "price_output_per_million" fields as_float in
      let* request_latency_ms = opt_member "request_latency_ms" fields as_int in
      let* ttfrc_ms = opt_member "ttfrc_ms" fields as_float in
      let* temperature = opt_member "temperature" fields as_float in
      let* top_p = opt_member "top_p" fields as_float in
      let* max_tokens = opt_member "max_tokens" fields as_int in
      let* thinking_budget = opt_member "thinking_budget" fields as_int in
      let* enable_thinking = opt_member "enable_thinking" fields as_bool in
      let* input_tokens = opt_member "input_tokens" fields as_int in
      let* cache_creation_input_tokens =
        opt_member "cache_creation_input_tokens" fields as_int
      in
      let* cache_read_input_tokens =
        opt_member "cache_read_input_tokens" fields as_int
      in
      let* output_tokens = opt_member "output_tokens" fields as_int in
      let* usage_scope =
        match List.assoc_opt "usage_scope" fields with
        | None -> Ok Runtime_usage_scope.Usage_scope_unavailable
        | Some (`String value) ->
          (match Runtime_usage_scope.of_string value with
           | Some scope -> Ok scope
           | None ->
             Error (Printf.sprintf "turn_record: unknown usage_scope %S" value))
        | Some _ -> Error "turn_record: usage_scope is not a string"
      in
      let* ts_json = require "ts" fields in
      let* ts = as_float "ts" ts_json in
      Ok
        { execution_ids
        ; keeper
        ; agent_name
        ; turn_kind
        ; trace_id
        ; absolute_turn
        ; turn_ref
        ; blocks
        ; input_components
        ; tool_surface_ref
        ; runtime_profile
        ; selected_model
        ; finish_reason
        ; context_window
        ; price_input_per_million
        ; price_output_per_million
        ; request_latency_ms
        ; ttfrc_ms
        ; request_wire_observation
        ; model_input_window
        ; raw_trace_run_ref
        ; sampling = { temperature; top_p; max_tokens; thinking_budget; enable_thinking }
        ; usage =
            { input_tokens
            ; output_tokens
            ; cache_creation_input_tokens
            ; cache_read_input_tokens
            ; scope = usage_scope
            }
        ; ts
        }
  | _ -> Error "turn_record: row is not an object"

(* ── Block diff ────────────────────────────────────────── *)

type block_diff =
  { added : prompt_block list
  ; removed : prompt_block list
  ; changed : (prompt_block * prompt_block) list
  }

let find_block blocks id =
  List.find_opt (fun (b : prompt_block) -> Prompt_block_id.equal b.block id) blocks

let diff_blocks ~(prev : t) ~(next : t) : block_diff =
  let prev_blocks = prev.blocks in
  let next_blocks = next.blocks in
  let added =
    List.filter
      (fun (b : prompt_block) -> find_block prev_blocks b.block = None)
      next_blocks
  in
  let removed =
    List.filter
      (fun (b : prompt_block) -> find_block next_blocks b.block = None)
      prev_blocks
  in
  let changed =
    List.filter_map
      (fun (next_b : prompt_block) ->
        match find_block prev_blocks next_b.block with
        | Some prev_b when not (String.equal prev_b.digest next_b.digest) ->
            Some (prev_b, next_b)
        | Some _ | None -> None)
      next_blocks
  in
  { added; removed; changed }

let entries_with_diffs (records : t list) : (t * block_diff option) list =
  (* A diff is only meaningful against the previous record of the SAME
     trace: a generation boundary legitimately replaces the whole
     assembly, and that diff would be noise rather than signal. *)
  let rec walk prev = function
    | [] -> []
    | record :: rest ->
        let diff =
          match prev with
          | Some p when String.equal p.trace_id record.trace_id ->
              Some (diff_blocks ~prev:p ~next:record)
          | Some _ | None -> None
        in
        (record, diff) :: walk (Some record) rest
  in
  walk None records
