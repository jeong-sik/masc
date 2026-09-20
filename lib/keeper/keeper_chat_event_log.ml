(** Versioned JSON codec and per-operation JSONL journal for
    [Keeper_chat_events.keeper_chat_event] (RFC-0412 §4.1).

    Stage 1 is dual-write only: read paths are unchanged, and the journal is
    fail-open — a journal failure must never break the live turn. *)

open Keeper_chat_events

let codec_version = 1

(* One page of the journal over the wire (RFC-0412 §3.2): what a read
   returns when it names no count, and the most it may ask for. The server
   admits [1..page_max_limit]; the TUI pages at [page_max_limit]. One
   definition so the two cannot drift into a 400. *)
let page_default_limit = 500
let page_max_limit = 2000

let json_opt key value =
  match value with
  | None -> []
  | Some value -> [ key, value ]
;;

let type_tag tag fields = `Assoc (("type", `String tag) :: fields)

let role_to_json = function
  | User -> `String "user"
  | Assistant -> `String "assistant"
;;

let role_of_json json =
  match json with
  | `String "user" -> Ok User
  | `String "assistant" -> Ok Assistant
  | other ->
    Error
      (Printf.sprintf
         "role: expected \"user\"|\"assistant\", got %s"
         (Yojson.Safe.to_string other))
;;

(* Journal-native occurrence shape (snake_case). Used by the Tool_call_*
   family. *)
let occurrence_to_json (o : tool_stream_occurrence) =
  `Assoc
    ([ "stream_scope", `Int o.stream_scope
     ; "block_index", `Int o.block_index
     ]
     @ json_opt "provider_message_id"
         (Option.map (fun value -> `String value) o.provider_message_id))
;;

let occurrence_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { stream_scope = json |> member "stream_scope" |> to_int
      ; provider_message_id = json |> member "provider_message_id" |> to_string_option
      ; block_index = json |> member "block_index" |> to_int
      }
  with
  | Type_error (message, _) -> Error ("tool_stream_occurrence: " ^ message)
;;

(* Decode-side companion for the occurrence nested inside
   [stream_protocol_error_to_json], whose shape is the AG-UI wire shape
   (camelCase) — the encoder is reused verbatim, so this decoder must match
   it. *)
let occurrence_of_wire_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { stream_scope = json |> member "toolStreamScope" |> to_int
      ; provider_message_id = json |> member "providerMessageId" |> to_string_option
      ; block_index = json |> member "toolCallBlockIndex" |> to_int
      }
  with
  | Type_error (message, _) -> Error ("tool_stream_occurrence(wire): " ^ message)
;;

(* [api_usage_to_json] writes a derived [total_tokens]; decoding recomputes it
   via [Agent_core.Types.total_tokens], so it is intentionally not read back. *)
let api_usage_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { Agent_core.Types.input_tokens = json |> member "input_tokens" |> to_int
      ; output_tokens = json |> member "output_tokens" |> to_int
      ; cache_creation_input_tokens =
          json |> member "cache_creation_input_tokens" |> to_int
      ; cache_read_input_tokens = json |> member "cache_read_input_tokens" |> to_int
      ; cost_usd = json |> member "cost_usd" |> to_float_option
      }
  with
  | Type_error (message, _) -> Error ("api_usage: " ^ message)
;;

let delta_usage_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { Agent_core.Types.input_tokens = json |> member "input_tokens" |> to_int_option
      ; output_tokens = json |> member "output_tokens" |> to_int_option
      ; cache_creation_input_tokens =
          json |> member "cache_creation_input_tokens" |> to_int_option
      ; cache_read_input_tokens =
          json |> member "cache_read_input_tokens" |> to_int_option
      }
  with
  | Type_error (message, _) -> Error ("delta_usage: " ^ message)
;;

let opt_member json key decode =
  match Yojson.Safe.Util.member key json with
  | `Null -> Ok None
  | value -> Result.map (fun decoded -> Some decoded) (decode value)
;;

let stream_protocol_error_of_json json =
  let open Yojson.Safe.Util in
  try
    let kind_raw = json |> member "kind" |> to_string in
    match stream_protocol_error_kind_of_string kind_raw with
    | None ->
      Error (Printf.sprintf "stream_protocol_error: unknown kind %S" kind_raw)
    | Some kind ->
      let quarantined_occurrence =
        match json |> member "quarantined_occurrence" with
        | `Null -> Ok None
        | occurrence_json ->
          Result.map
            (fun occurrence -> Some occurrence)
            (occurrence_of_wire_json occurrence_json)
      in
      Result.map
        (fun quarantined_occurrence ->
           { kind
           ; quarantined_occurrence
           ; index = json |> member "index" |> to_int_option
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; event_type = json |> member "event_type" |> to_string_option
           ; reason = json |> member "reason" |> to_string_option
           ; raw_bytes = json |> member "raw_bytes" |> to_int_option
           })
        quarantined_occurrence
  with
  | Type_error (message, _) -> Error ("stream_protocol_error: " ^ message)
;;

let keeper_chat_event_to_json event =
  match event with
  | Batch_bound { operation_id; execution_id } ->
    type_tag "batch_bound" ["operation_id", `String (Keeper_chat_operation.Operation_id.to_string operation_id);
      "execution_id", `String (Keeper_chat_operation.Operation_id.to_string execution_id)]
  | Run_started { run_id; thread_id } ->
    type_tag "run_started" [ "run_id", `String run_id; "thread_id", `String thread_id ]
  | Text_message_start { message_id; role } ->
    type_tag
      "text_message_start"
      [ "message_id", `String message_id; "role", role_to_json role ]
  | Text_delta delta -> type_tag "text_delta" [ "delta", `String delta ]
  | Text_message_end -> type_tag "text_message_end" []
  | External_effect_completed { target } ->
    type_tag
      "external_effect_completed"
      [ "target", Keeper_surface_post.delivery_target_to_yojson target ]
  | Run_finished { run_id } -> type_tag "run_finished" [ "run_id", `String run_id ]
  | Event_error { message } -> type_tag "event_error" [ "message", `String message ]
  | Reply_details { reply; turn_outcome; turn_ref } ->
    type_tag
      "reply_details"
      [ "reply", `String reply
      ; "turn_outcome", `String (Keeper_turn_outcome.to_label turn_outcome)
      ; "turn_ref", `String (Ids.Turn_ref.to_string turn_ref)
      ]
  | Continuation_checkpoint { message; request_id } ->
    type_tag
      "continuation_checkpoint"
      ([ "message", `String message ]
       @ json_opt "request_id" (Option.map (fun value -> `String value) request_id))
  | Agent_core_stream_connected -> type_tag "agent_core_stream_connected" []
  | Agent_core_runtime_attempt_started { runtime_id; attempt_index } ->
    type_tag
      "agent_core_runtime_attempt_started"
      (json_opt "runtime_id" (Option.map (fun value -> `String value) runtime_id)
       @ json_opt "attempt_index"
           (Option.map (fun value -> `Int value) attempt_index))
  | Agent_core_stream_message_start { provider_message_id; model; usage } ->
    type_tag
      "agent_core_stream_message_start"
      ([ "provider_message_id", `String provider_message_id; "model", `String model ]
       @ json_opt "usage" (Option.map api_usage_to_json usage))
  | Agent_core_stream_message_delta { stop_reason; usage } ->
    type_tag
      "agent_core_stream_message_delta"
      (json_opt
         "stop_reason"
         (Option.map
            (fun reason -> `String (Agent_core.Types.stop_reason_to_string reason))
            stop_reason)
       @ json_opt "usage" (Option.map delta_usage_to_json usage))
  | Agent_core_stream_message_stop -> type_tag "agent_core_stream_message_stop" []
  | Agent_core_stream_ping -> type_tag "agent_core_stream_ping" []
  | Agent_core_content_block_start { index; content_type; tool_call_id; tool_call_name }
    ->
    type_tag
      "agent_core_content_block_start"
      ([ "index", `Int index; "content_type", `String content_type ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id)
       @ json_opt
           "tool_call_name"
           (Option.map (fun value -> `String value) tool_call_name))
  | Agent_core_content_block_stop { index } ->
    type_tag "agent_core_content_block_stop" [ "index", `Int index ]
  | Agent_core_thinking_delta { index; delta } ->
    type_tag "agent_core_thinking_delta" [ "index", `Int index; "delta", `String delta ]
  | Agent_core_thinking_signature_delta { index; signature_bytes } ->
    (* [signature_bytes] is a byte COUNT (int), not payload bytes. *)
    type_tag
      "agent_core_thinking_signature_delta"
      [ "index", `Int index; "signature_bytes", `Int signature_bytes ]
  | Agent_core_media_delta { index; media_type; source_type; media_ref } ->
    type_tag
      "agent_core_media_delta"
      [ "index", `Int index
      ; "media_type", `String media_type
      ; "source_type", `String (Agent_core.Types.media_source_kind_to_string source_type)
      ; "media_ref", `String media_ref
      ]
  | Agent_core_stream_protocol_error error ->
    type_tag
      "agent_core_stream_protocol_error"
      [ "error", stream_protocol_error_to_json error ]
  | Tool_call_start { occurrence; tool_call_id; tool_call_name } ->
    type_tag
      "tool_call_start"
      ([ "occurrence", occurrence_to_json occurrence
       ; "tool_call_name", `String tool_call_name
       ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_call_args { occurrence; tool_call_id; delta } ->
    type_tag
      "tool_call_args"
      ([ "occurrence", occurrence_to_json occurrence; "delta", `String delta ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_call_args_snapshot { occurrence; tool_call_id; snapshot } ->
    type_tag
      "tool_call_args_snapshot"
      ([ "occurrence", occurrence_to_json occurrence; "snapshot", `String snapshot ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_call_end { occurrence; tool_call_id } ->
    type_tag
      "tool_call_end"
      ([ "occurrence", occurrence_to_json occurrence ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Tool_approval_requested { tool_call_id; tool_call_name; args; question; because } ->
    type_tag
      "tool_approval_requested"
      [ "tool_call_id", `String tool_call_id
      ; "tool_call_name", `String tool_call_name
      ; "args", `String args
      ; "question", `String question
      ; "because", `String because
      ]
  | Tool_approval_settled { tool_call_id; outcome } ->
    type_tag
      "tool_approval_settled"
      [ "tool_call_id", `String tool_call_id; "outcome", `String outcome ]
  | Tool_result_ready { occurrence; tool_call_id; execution_id } ->
    type_tag
      "tool_result_ready"
      ([ "occurrence", occurrence_to_json occurrence
       ; "execution_id", `String (Ids.Execution_id.to_string execution_id)
       ]
       @ json_opt "tool_call_id" (Option.map (fun value -> `String value) tool_call_id))
  | Link_block { url; title; description; image } ->
    type_tag
      "link_block"
      ([ "url", `String url; "title", `String title ]
       @ json_opt "description" (Option.map (fun value -> `String value) description)
       @ json_opt "image" (Option.map (fun value -> `String value) image))
  | Image_block { url; caption } ->
    type_tag
      "image_block"
      ([ "url", `String url ]
       @ json_opt "caption" (Option.map (fun value -> `String value) caption))
  | Status_block { kind } ->
    type_tag
      "status_block"
      [ "kind", `String (Keeper_chat_blocks.status_kind_to_label kind) ]
  | Audio_block { token; mime; message_text; duration_sec } ->
    type_tag
      "audio_block"
      ([ "token", `String token
       ; "mime", `String mime
       ; "message_text", `String message_text
       ]
       @ json_opt "duration_sec" (Option.map (fun value -> `Float value) duration_sec))
  | Tool_context_block { tool_call_id; name; args_summary; result_summary } ->
    type_tag
      "tool_context_block"
      ([ "tool_call_id", `String tool_call_id
       ; "name", `String name
       ; "args_summary", `String args_summary
       ]
       @ json_opt
           "result_summary"
           (Option.map (fun value -> `String value) result_summary))
;;

let keeper_chat_event_of_json json =
  let open Yojson.Safe.Util in
  let ( let* ) = Result.bind in
  try
    let tag = json |> member "type" |> to_string in
    match tag with
    | "run_started" ->
      Ok
        (Run_started
           { run_id = json |> member "run_id" |> to_string
           ; thread_id = json |> member "thread_id" |> to_string
           })
    | "text_message_start" ->
      let* role = role_of_json (json |> member "role") in
      Ok
        (Text_message_start
           { message_id = json |> member "message_id" |> to_string; role })
    | "text_delta" -> Ok (Text_delta (json |> member "delta" |> to_string))
    | "text_message_end" -> Ok Text_message_end
    | "external_effect_completed" ->
      let* target =
        Keeper_surface_post.delivery_target_of_yojson (json |> member "target")
      in
      Ok (External_effect_completed { target })
    | "run_finished" ->
      Ok (Run_finished { run_id = json |> member "run_id" |> to_string })
    | "event_error" ->
      Ok (Event_error { message = json |> member "message" |> to_string })
    | "reply_details" ->
      let outcome_label = json |> member "turn_outcome" |> to_string in
      let* turn_outcome =
        match Keeper_turn_outcome.of_label outcome_label with
        | Some outcome -> Ok outcome
        | None ->
          Error (Printf.sprintf "reply_details: unknown turn_outcome %S" outcome_label)
      in
      let turn_ref_raw = json |> member "turn_ref" |> to_string in
      let* turn_ref =
        match Ids.Turn_ref.of_string turn_ref_raw with
        | Some turn_ref -> Ok turn_ref
        | None ->
          Error (Printf.sprintf "reply_details: malformed turn_ref %S" turn_ref_raw)
      in
      Ok
        (Reply_details
           { reply = json |> member "reply" |> to_string; turn_outcome; turn_ref })
    | "batch_bound" ->
      let* operation_id = Keeper_chat_operation.Operation_id.of_string (json |> member "operation_id" |> to_string) in
      let* execution_id = Keeper_chat_operation.Operation_id.of_string (json |> member "execution_id" |> to_string) in
      Ok (Batch_bound {operation_id; execution_id})
    | "continuation_checkpoint" ->
      Ok
        (Continuation_checkpoint
           { message = json |> member "message" |> to_string
           ; request_id = json |> member "request_id" |> to_string_option
           })
    | "agent_core_stream_connected" -> Ok Agent_core_stream_connected
    | "agent_core_runtime_attempt_started" ->
      let runtime_id = json |> member "runtime_id" |> to_string_option in
      let attempt_index = json |> member "attempt_index" |> to_int_option in
      Ok (Agent_core_runtime_attempt_started { runtime_id; attempt_index })
    | "agent_core_stream_message_start" ->
      let* usage = opt_member json "usage" api_usage_of_json in
      Ok
        (Agent_core_stream_message_start
           { provider_message_id = json |> member "provider_message_id" |> to_string
           ; model = json |> member "model" |> to_string
           ; usage
           })
    | "agent_core_stream_message_delta" ->
      let stop_reason_raw = json |> member "stop_reason" |> to_string_option in
      let* usage = opt_member json "usage" delta_usage_of_json in
      Ok
        (Agent_core_stream_message_delta
           { stop_reason =
               Option.map Agent_core.Types.stop_reason_of_string stop_reason_raw
           ; usage
           })
    | "agent_core_stream_message_stop" -> Ok Agent_core_stream_message_stop
    | "agent_core_stream_ping" -> Ok Agent_core_stream_ping
    | "agent_core_content_block_start" ->
      Ok
        (Agent_core_content_block_start
           { index = json |> member "index" |> to_int
           ; content_type = json |> member "content_type" |> to_string
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; tool_call_name = json |> member "tool_call_name" |> to_string_option
           })
    | "agent_core_content_block_stop" ->
      Ok (Agent_core_content_block_stop { index = json |> member "index" |> to_int })
    | "agent_core_thinking_delta" ->
      Ok
        (Agent_core_thinking_delta
           { index = json |> member "index" |> to_int
           ; delta = json |> member "delta" |> to_string
           })
    | "agent_core_thinking_signature_delta" ->
      Ok
        (Agent_core_thinking_signature_delta
           { index = json |> member "index" |> to_int
           ; signature_bytes = json |> member "signature_bytes" |> to_int
           })
    | "agent_core_media_delta" ->
      let source_raw = json |> member "source_type" |> to_string in
      let* source_type =
        match Agent_core.Types.media_source_kind_of_string source_raw with
        | Some kind -> Ok kind
        | None ->
          Error
            (Printf.sprintf "agent_core_media_delta: unknown source_type %S" source_raw)
      in
      Ok
        (Agent_core_media_delta
           { index = json |> member "index" |> to_int
           ; media_type = json |> member "media_type" |> to_string
           ; source_type
           ; media_ref = json |> member "media_ref" |> to_string
           })
    | "agent_core_stream_protocol_error" ->
      let* error = stream_protocol_error_of_json (json |> member "error") in
      Ok (Agent_core_stream_protocol_error error)
    | "tool_call_start" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_start
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; tool_call_name = json |> member "tool_call_name" |> to_string
           })
    | "tool_call_args" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_args
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; delta = json |> member "delta" |> to_string
           })
    | "tool_call_args_snapshot" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_args_snapshot
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; snapshot = json |> member "snapshot" |> to_string
           })
    | "tool_call_end" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_call_end
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           })
    | "tool_approval_requested" ->
      Ok
        (Tool_approval_requested
           { tool_call_id = json |> member "tool_call_id" |> to_string
           ; tool_call_name = json |> member "tool_call_name" |> to_string
           ; args = json |> member "args" |> to_string
           ; question = json |> member "question" |> to_string
           ; because = json |> member "because" |> to_string
           })
    | "tool_approval_settled" ->
      Ok
        (Tool_approval_settled
           { tool_call_id = json |> member "tool_call_id" |> to_string
           ; outcome = json |> member "outcome" |> to_string
           })
    | "tool_result_ready" ->
      let* occurrence = occurrence_of_json (json |> member "occurrence") in
      Ok
        (Tool_result_ready
           { occurrence
           ; tool_call_id = json |> member "tool_call_id" |> to_string_option
           ; execution_id =
               Ids.Execution_id.of_string (json |> member "execution_id" |> to_string)
           })
    | "link_block" ->
      Ok
        (Link_block
           { url = json |> member "url" |> to_string
           ; title = json |> member "title" |> to_string
           ; description = json |> member "description" |> to_string_option
           ; image = json |> member "image" |> to_string_option
           })
    | "image_block" ->
      Ok
        (Image_block
           { url = json |> member "url" |> to_string
           ; caption = json |> member "caption" |> to_string_option
           })
    | "status_block" ->
      let kind_raw = json |> member "kind" |> to_string in
      let* kind =
        match Keeper_chat_blocks.status_kind_of_label kind_raw with
        | Some kind -> Ok kind
        | None ->
          Error (Printf.sprintf "status_block: unknown kind %S" kind_raw)
      in
      Ok (Status_block { kind })
    | "audio_block" ->
      Ok
        (Audio_block
           { token = json |> member "token" |> to_string
           ; mime = json |> member "mime" |> to_string
           ; message_text = json |> member "message_text" |> to_string
           ; duration_sec = json |> member "duration_sec" |> to_float_option
           })
    | "tool_context_block" ->
      Ok
        (Tool_context_block
           { tool_call_id = json |> member "tool_call_id" |> to_string
           ; name = json |> member "name" |> to_string
           ; args_summary = json |> member "args_summary" |> to_string
           ; result_summary = json |> member "result_summary" |> to_string_option
           })
    | unknown ->
      Error (Printf.sprintf "keeper_chat_event: unknown type %S" unknown)
  with
  | Type_error (message, _) -> Error ("keeper_chat_event: " ^ message)
;;

type journaled_event =
  { seq : int
  ; ts : float
  ; event : keeper_chat_event
  }

let journaled_event_to_json { seq; ts; event } =
  `Assoc
    [ "v", `Int codec_version
    ; "seq", `Int seq
    ; "ts", `Float ts
    ; "event", keeper_chat_event_to_json event
    ]
;;

let journaled_event_of_json json =
  let open Yojson.Safe.Util in
  try
    let version = json |> member "v" |> to_int in
    if version <> codec_version
    then
      Error
        (Printf.sprintf
           "journaled_event: unsupported version %d (codec v%d)"
           version
           codec_version)
    else
      Result.map
        (fun event ->
           { seq = json |> member "seq" |> to_int
           ; ts = json |> member "ts" |> to_float
           ; event
           })
        (keeper_chat_event_of_json (json |> member "event"))
  with
  | Type_error (message, _) -> Error ("journaled_event: " ^ message)
;;

(* String-level framing: the single place where JSONL line conversion and
   [Yojson.Json_error] handling live. *)
let journaled_event_to_string journaled =
  Yojson.Safe.to_string (journaled_event_to_json journaled)
;;

(** Strict decode of one journal line. [Yojson.Json_error] is caught and
    returned as [Error]. *)
let journaled_event_of_string line =
  try journaled_event_of_json (Yojson.Safe.from_string line) with
  | Yojson.Json_error message -> Error ("journaled_event: invalid JSON: " ^ message)
;;

(** {1 Journal} *)

type journal = { path : string }

let sanitize_segment = Workspace_utils_backend_setup.sanitize_namespace_segment

(* The single spelling of the store's directory name: the journal writer, the
   consistency audit's sweep, and the retention pruner all derive their paths
   from it. *)
let events_dirname = "keeper_chat_events"

let events_dir ~base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) events_dirname
;;

let journal_path ~base_dir ~keeper_name ~operation_id =
  Filename.concat
    (Filename.concat (events_dir ~base_dir) (sanitize_segment keeper_name))
    (sanitize_segment operation_id ^ ".jsonl")
;;

(* Fail-open at construction too: a directory we cannot create must not abort
   the turn; the per-event append below then logs each failure. *)
let open_journal ~base_dir ~keeper_name ~operation_id () =
  let path = journal_path ~base_dir ~keeper_name ~operation_id in
  (try Fs_compat.mkdir_p (Filename.dirname path) with
   | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
   | exn ->
     Log.Keeper.error
       "keeper_chat_event_log: journal directory creation failed path=%s: %s"
       path
       (Printexc.to_string exn));
  { path }
;;

(* A non-finite float (NaN/inf) would serialize to a bare NaN/Infinity token —
   invalid JSON. Reject at the writer boundary: log and skip the line. *)
let float_is_finite value =
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true
;;

let event_floats_are_finite = function
  | Agent_core_stream_message_start
      { usage = Some { Agent_core.Types.cost_usd = Some cost_usd; _ }; _ } ->
    float_is_finite cost_usd
  | Audio_block { duration_sec = Some duration_sec; _ } ->
    float_is_finite duration_sec
  | _ -> true
;;

(* Fail-open by contract: stage 1 dual-writes next to keeper_chat_store, which
   remains the durable record of record. A journal failure is logged, never
   raised into the live path. The umbrella is required: the Fs_compat result
   type covers only torn-tail cut/write/fsync/rollback failures, while mkdir,
   openfile, fchmod, fsync_parent_directory, and lockf raise raw
   [Unix.Unix_error]. *)
let append journal ~seq ~ts event =
  try
    if (not (float_is_finite ts)) || not (event_floats_are_finite event)
    then
      Log.Keeper.error
        "keeper_chat_event_log: refusing to journal non-finite float path=%s seq=%d"
        journal.path
        seq
    else begin
      let line = journaled_event_to_string { seq; ts; event } ^ "\n" in
      match Fs_compat.append_private_jsonl_durable_locked_result journal.path line with
      | Fs_compat.Private_file_succeeded () -> ()
      | Fs_compat.Private_file_succeeded_with_cleanup_failure
          { value = (); cleanup_failure } ->
        Log.Keeper.error
          "keeper_chat_event_log: append succeeded with descriptor settlement failure path=%s: %s"
          journal.path
          (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
      | Fs_compat.Private_file_failed error ->
        Log.Keeper.error
          "keeper_chat_event_log: journal append failed path=%s: %s"
          journal.path
          (Fs_compat.private_jsonl_append_error_to_string error)
      | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
        Log.Keeper.error
          "keeper_chat_event_log: journal append failed path=%s: %s; descriptor settlement failed: %s"
          journal.path
          (Fs_compat.private_jsonl_append_error_to_string error)
          (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
    end
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exn ->
    Log.Keeper.error
      "keeper_chat_event_log: journal append raised path=%s seq=%d: %s"
      journal.path
      seq
      (Printexc.to_string exn)
;;

type read_failure =
  | Journal_missing
  | Journal_unreadable of string
  | Journal_corrupt of string

(* Strict decode of the complete rows: the first line that is not an envelope
   makes the whole read [Journal_corrupt]. Blank rows are skipped, as the
   writer never emits one and a reader must not invent an event for one. *)
let decode_rows ~path rows =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      if String.equal (String.trim line) ""
      then loop acc rest
      else begin
        match journaled_event_of_string line with
        | Ok journaled -> loop (journaled :: acc) rest
        | Error detail ->
          Error
            (Journal_corrupt
               (Printf.sprintf
                  "keeper_chat_event_log: corrupt journal line path=%s: %s"
                  path
                  detail))
      end
  in
  loop [] (String.split_on_char '\n' rows)
;;

let log_settlement_failure ~path cleanup_failure =
  Log.Keeper.error
    "keeper_chat_event_log: journal read succeeded with descriptor settlement failure path=%s: %s"
    path
    (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
;;

(* Serving readers (stream replay, the v2 events endpoint) and the
   consistency audit read through the writer's lock and framing
   ([Fs_compat.read_private_jsonl_rows_locked_result]): the shared lock waits
   out an append in progress, so the bytes are never a write in flight, and a
   fragment after the last '\n' — the rows an append left when the process
   died between its write and its rollback — is not a row. Such a fragment
   is logged and the complete rows are served; the next append cuts it before
   writing, so any later row follows exactly those rows. The three
   failure shapes stay apart: a missing journal is the normal state of a
   queued operation, an unreadable one is an operator problem, a corrupt one
   is a codec problem. *)
let read_complete_rows ~allow_torn_tail path =
  let of_rows = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Error Journal_missing
    | Fs_compat.Private_jsonl_rows.Rows_present { rows_end; end_offset; _ }
      when rows_end < end_offset && not allow_torn_tail ->
      Error (Journal_corrupt "cannot resume a journal with an incomplete final row")
    | Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset } ->
      if rows_end < end_offset
      then
        Log.Keeper.warn
          "keeper_chat_event_log: journal has a torn tail path=%s rows_end=%d end_offset=%d: bytes after the last row are an append that never completed; serving the complete rows"
          path
          rows_end
          end_offset;
      Ok rows
  in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded rows -> of_rows rows
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
    log_settlement_failure ~path cleanup_failure;
    of_rows value
  | Fs_compat.Private_file_failed (Fs_compat.Private_jsonl_rows.Io_failed exn) ->
    Error (Journal_unreadable (Printexc.to_string exn))
  | Fs_compat.Private_file_failed_with_cleanup_failure
      { error = Fs_compat.Private_jsonl_rows.Io_failed exn; cleanup_failure } ->
    log_settlement_failure ~path cleanup_failure;
    Error (Journal_unreadable (Printexc.to_string exn))
;;

let read_journal_path ~allow_torn_tail path =
  Result.bind (read_complete_rows ~allow_torn_tail path) (decode_rows ~path)
;;

let read_journal_rows_path path = read_complete_rows ~allow_torn_tail:true path
let read_journal_path_result path = read_journal_path ~allow_torn_tail:true path
let read_journal journal = read_journal_path_result journal.path

let next_sequence ?(require_existing = false) journal =
  match read_journal_path ~allow_torn_tail:false journal.path with
  | Error Journal_missing when not require_existing -> Ok 0
  | Error (Journal_missing | Journal_unreadable _ | Journal_corrupt _) as error -> error
  | Ok entries ->
    let rec last previous = function
      | [] -> Ok previous
      | entry :: rest ->
        (match previous with
         | Some prior when entry.seq <= prior.seq ->
           Error (Journal_corrupt "operation journal sequences are not increasing")
         | Some _ | None -> last (Some entry) rest) in
    (match last None entries with
     | Error _ as error -> error
     | Ok latest ->
       let complete = match latest with
         | Some { event = (Keeper_chat_events.Run_finished _ | Event_error _); _ } -> true
         | Some _ | None -> false in
       if require_existing && not complete then
         Error (Journal_corrupt "continuation journal has no durable terminal segment boundary")
       else
         let highest = Option.fold ~none:(-1) ~some:(fun entry -> entry.seq) latest in
         if highest = max_int then Error (Journal_corrupt "journal sequence space exhausted")
         else Ok (highest + 1))
;;

(** {1 Replay position} *)

type replay_position =
  | Whole_turn
  | After_seq of int

(* The wire spells the position as an optional non-negative integer: absent
   is the whole turn, [n >= 0] is the last seq held. A negative integer is no
   position at all. Decoded here once; the handlers and the fold see only the
   sum type. *)
let replay_position_of_wire = function
  | None -> Some Whole_turn
  | Some raw -> if raw >= 0 then Some (After_seq raw) else None
;;

let replay_position_to_wire = function
  | Whole_turn -> None
  | After_seq seq -> Some seq
;;

let replay_position_to_string = function
  | Whole_turn -> "whole_turn"
  | After_seq seq -> string_of_int seq
;;

(* A response field cannot be absent the way a request field can, so a
   response spells the whole turn as [null]. *)
let replay_position_to_yojson position : Yojson.Safe.t =
  match replay_position_to_wire position with
  | None -> `Null
  | Some seq -> `Int seq
;;

let replay_position_of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Null -> replay_position_of_wire None
  | `Int raw -> replay_position_of_wire (Some raw)
  | `Assoc _ | `Bool _ | `Float _ | `Intlit _ | `List _ | `String _ -> None
;;

let seq_is_after position seq =
  match position with
  | Whole_turn -> true
  | After_seq held -> seq > held
;;

let replay_position_advance position seq =
  if seq_is_after position seq then After_seq seq else position
;;

(** {1 Page} *)

type page_start =
  | From_first_row
  | From_offset of int

let first_row = From_first_row

let page_start_of_wire = function
  | None -> Some From_first_row
  | Some offset -> if offset >= 0 then Some (From_offset offset) else None
;;

let page_start_to_wire = function
  | From_first_row -> None
  | From_offset offset -> Some offset
;;

let page_start_offset = function
  | From_first_row -> 0
  | From_offset offset -> offset
;;

type page =
  { events : journaled_event list
  ; has_more : bool
  ; next_offset : int
  }

type cursor_refusal =
  | Offset_past_rows
  | Offset_inside_row
  | Cursor_pair_mismatch

let cursor_refusal_to_wire = function
  | Offset_past_rows -> "since_offset_past_rows"
  | Offset_inside_row -> "since_offset_inside_row"
  | Cursor_pair_mismatch -> "cursor_mismatch"
;;

let cursor_refusal_of_wire = function
  | "since_offset_past_rows" -> Some Offset_past_rows
  | "since_offset_inside_row" -> Some Offset_inside_row
  | "cursor_mismatch" -> Some Cursor_pair_mismatch
  | _ -> None
;;

type cursor_mismatch =
  | Offset_without_held_seq of int
  | Row_before_offset_past_held_seq of
      { offset : int
      ; since_seq : int
      ; row_seq : int
      }
  | Row_at_offset_not_past_held_seq of
      { offset : int
      ; since_seq : int
      ; row_seq : int
      }

type page_failure =
  | Page_offset_past_rows of
      { offset : int
      ; rows_end : int
      }
  | Page_offset_inside_row of int
  | Page_cursor_mismatch of cursor_mismatch
  | Page_limit_not_positive of int
  | Page_corrupt of string

let cursor_mismatch_to_string = function
  | Offset_without_held_seq offset ->
    Printf.sprintf
      "since_offset %d was sent without a since_seq: an offset only places a page \
       beside the seq the page before handed back"
      offset
  | Row_before_offset_past_held_seq { offset; since_seq; row_seq } ->
    Printf.sprintf
      "the row before since_offset %d has seq %d, which is already past since_seq \
       %d: the two cursors did not come from the same page, and the rows between \
       them would never be served"
      offset
      row_seq
      since_seq
  | Row_at_offset_not_past_held_seq { offset; since_seq; row_seq } ->
    Printf.sprintf
      "the row at since_offset %d has seq %d, which is not after since_seq %d: the \
       two cursors did not come from the same page"
      offset
      row_seq
      since_seq
;;

let page_failure_to_string = function
  | Page_offset_past_rows { offset; rows_end } ->
    Printf.sprintf
      "since_offset %d lies past the journal's complete rows, which end at %d"
      offset
      rows_end
  | Page_offset_inside_row offset ->
    Printf.sprintf "since_offset %d does not start a row" offset
  | Page_cursor_mismatch mismatch -> cursor_mismatch_to_string mismatch
  | Page_limit_not_positive limit ->
    Printf.sprintf "a page of %d rows serves nothing and never advances" limit
  | Page_corrupt detail -> detail
;;

let empty_page start = { events = []; has_more = false; next_offset = page_start_offset start }

(* The row that ends at [row_end], skipping blank ones backwards. [row_end] is
   always just past a ['\n'], so the row before it starts after the previous
   one. *)
let rec row_ending_at rows ~row_end =
  if row_end <= 0
  then None
  else (
    let line_end = row_end - 1 in
    let row_start =
      match String.rindex_from_opt rows (line_end - 1) '\n' with
      | Some newline -> newline + 1
      | None -> 0
    in
    let line = String.sub rows row_start (line_end - row_start) in
    if String.equal (String.trim line) ""
    then row_ending_at rows ~row_end:row_start
    else Some (row_start, line))
;;

let corrupt_row ~path ~offset detail =
  Page_corrupt
    (Printf.sprintf
       "keeper_chat_event_log: corrupt journal line path=%s offset=%d: %s"
       path
       offset
       detail)
;;

(* A held offset and a held seq have to be the two halves of one page's answer.
   The page that handed them out ended on the row before the offset, and seqs
   increase down the journal, so the row before the offset is at or before the
   held seq and the row at the offset is past it. An offset ahead of its seq
   would silently skip the rows between them, which is why both ends are
   checked. Offset zero is the first row, which places no pair. *)
let cursor_pair_failure ~path ~since_seq ~start rows =
  match start with
  | From_first_row -> None
  | From_offset offset when offset <= 0 -> None
  | From_offset offset ->
    (match since_seq with
     | Whole_turn -> Some (Page_cursor_mismatch (Offset_without_held_seq offset))
     | After_seq held ->
       (match row_ending_at rows ~row_end:offset with
        | None -> None
        | Some (row_start, line) ->
          (match journaled_event_of_string line with
           | Error detail -> Some (corrupt_row ~path ~offset:row_start detail)
           | Ok (journaled : journaled_event) ->
             if journaled.seq > held
             then
               Some
                 (Page_cursor_mismatch
                    (Row_before_offset_past_held_seq
                       { offset; since_seq = held; row_seq = journaled.seq }))
             else None)))
;;

(* The first row served from a held offset lies past the held seq; from the
   first row nothing is held to compare. *)
let first_row_failure ~since_seq ~start (journaled : journaled_event) =
  match start, since_seq with
  | From_offset offset, After_seq held when offset > 0 && journaled.seq <= held ->
    Some
      (Page_cursor_mismatch
         (Row_at_offset_not_past_held_seq
            { offset; since_seq = held; row_seq = journaled.seq }))
  | From_offset _, (After_seq _ | Whole_turn) | From_first_row, (After_seq _ | Whole_turn)
    ->
    None
;;

(* The first non-blank row that starts at or after [position], which need not
   be a row boundary, as (row start, line end, row end). *)
let non_blank_row_from rows ~position =
  let rows_end = String.length rows in
  let first_start =
    if position <= 0 || Char.equal rows.[position - 1] '\n'
    then position
    else (
      match String.index_from_opt rows position '\n' with
      | Some newline -> newline + 1
      | None -> rows_end)
  in
  let rec from row_start =
    if row_start >= rows_end
    then None
    else (
      let line_end, row_end =
        match String.index_from_opt rows row_start '\n' with
        | Some newline -> newline, newline + 1
        | None -> rows_end, rows_end
      in
      let line = String.sub rows row_start (line_end - row_start) in
      if String.equal (String.trim line) ""
      then from row_end
      else Some (row_start, line, row_end))
  in
  from first_start
;;

(* Where a page from the first row starts reading when a seq is held. Skipping
   to it one row at a time decoded every row at or before the held seq: the
   TUI resumes a turn it partly holds that way, with no offset, so resuming
   near the end of a 43,000-row journal decoded nearly all of it to serve a
   few rows. Seqs increase down the journal, so the byte range is bisected
   instead, decoding one row per step.

   Rows starting before [low] are at or before the held seq, and rows
   starting at or after [high] are past it. When the two meet, [low] is the
   end of the last row at or before the seq, or 0, which is the offset such a
   page hands back. A probed row that does not decode cannot say which side
   of the seq it is on, so the bisection stops there and the page reads on
   from [low] one row at a time: the corrupt row fails the page only if the
   page reaches it. The rows skipped below [low] are not decoded, as rows
   before a held offset are not. *)
let offset_past_held_seq ~held rows =
  let rec bisect ~low ~high =
    if low >= high
    then low
    else (
      let middle = low + ((high - low) / 2) in
      match non_blank_row_from rows ~position:middle with
      | None -> bisect ~low ~high:middle
      | Some (row_start, _, _) when row_start >= high -> bisect ~low ~high:middle
      | Some (row_start, line, row_end) ->
        (match journaled_event_of_string line with
         | Error _ -> low
         | Ok (journaled : journaled_event) ->
           if journaled.seq > held
           then bisect ~low ~high:row_start
           else bisect ~low:row_end ~high))
  in
  bisect ~low:0 ~high:(String.length rows)
;;

(* Rows are decoded one at a time from [start] (from the first row with a held
   seq, from where [offset_past_held_seq] puts it), and only until the page is
   full and one more row past [since_seq] has shown whether another page
   follows. A request used to decode every row of the journal to serve at most
   [limit] of them, so reading a whole journal page by page decoded it once
   per page. A corrupt row is found when a page reaches it. A row skipped for
   lying at or before [since_seq] moves the offset handed back with it: an
   empty page's two cursors have to be a pair this same reader accepts once
   the journal grows. *)
let page_of_rows ~path ~since_seq ~start ~limit rows =
  let rows_end = String.length rows in
  let offset = page_start_offset start in
  if limit < 1
  then Error (Page_limit_not_positive limit)
  else if offset > rows_end
  then Error (Page_offset_past_rows { offset; rows_end })
  else if offset > 0 && not (Char.equal rows.[offset - 1] '\n')
  then Error (Page_offset_inside_row offset)
  else (
    match cursor_pair_failure ~path ~since_seq ~start rows with
    | Some failure -> Error failure
    | None ->
      let finish ~served ~has_more ~next_offset =
        Ok { events = List.rev served; has_more; next_offset }
      in
      let rec loop ~row_start ~first ~served ~count ~next_offset =
        if row_start >= rows_end
        then finish ~served ~has_more:false ~next_offset
        else (
          let line_end, row_end =
            match String.index_from_opt rows row_start '\n' with
            | Some newline -> newline, newline + 1
            | None -> rows_end, rows_end
          in
          let line = String.sub rows row_start (line_end - row_start) in
          if String.equal (String.trim line) ""
          then loop ~row_start:row_end ~first ~served ~count ~next_offset
          else (
            match journaled_event_of_string line with
            | Error detail -> Error (corrupt_row ~path ~offset:row_start detail)
            | Ok journaled ->
              (match
                 if first then first_row_failure ~since_seq ~start journaled else None
               with
               | Some failure -> Error failure
               | None ->
                 if not (seq_is_after since_seq journaled.seq)
                 then
                   loop
                     ~row_start:row_end
                     ~first:false
                     ~served
                     ~count
                     ~next_offset:row_end
                 else if count >= limit
                 then finish ~served ~has_more:true ~next_offset
                 else
                   loop
                     ~row_start:row_end
                     ~first:false
                     ~served:(journaled :: served)
                     ~count:(count + 1)
                     ~next_offset:row_end)))
      in
      (match since_seq, offset with
       | After_seq held, 0 ->
         let row_start = offset_past_held_seq ~held rows in
         loop ~row_start ~first:false ~served:[] ~count:0 ~next_offset:row_start
       | (After_seq _ | Whole_turn), _ ->
         loop ~row_start:offset ~first:true ~served:[] ~count:0 ~next_offset:offset))
;;
