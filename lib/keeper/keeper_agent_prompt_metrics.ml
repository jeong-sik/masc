(** Prompt metrics for keeper Agent.run turns. *)

module Canonical_tool = Agent_sdk.Canonical_tool

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] contains hard constraints (identity, policy guards,
    tool guidance, direct-reply mode) that must stay in the system prompt.
    [dynamic_context] contains soft context (continuity, skill route,
    worktree changes, turn instructions) injected via OAS
    [extra_system_context] at request assembly. *)
type turn_prompt =
  { system_prompt : string
  ; dynamic_context : string
  }

(** Prompt segment metrics for effective keeper input attribution.
    Bytes are stored rather than character counts because prompts are UTF-8. *)
type prompt_segment_metrics =
  { bytes : int
  ; fingerprint : string option
  }

(** Effective byte metrics for a keeper turn. *)
type prompt_metrics =
  { fingerprint : string
  ; total_bytes : int
  ; cacheable_bytes : int
  ; system_prompt_segment : prompt_segment_metrics
  ; dynamic_context_segment : prompt_segment_metrics
  ; user_message_segment : prompt_segment_metrics
  }

type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; sdk_turn : int
  ; prepared_component_bytes : int
  ; request_body_bytes : int option
  ; request_body_sha256 : string option
  ; origin_segments : (string * prompt_segment_metrics) list
  ; content_segments : (string * prompt_segment_metrics) list
  ; context_block_segments : (string * prompt_segment_metrics) list
  }

type prepared_input_snapshot =
  { sdk_turn : int
  ; messages : Agent_sdk.Agent.prepared_message list
  ; context_blocks : Turn_record.prompt_block list
  }

type request_wire_snapshot =
  { sdk_turn : int
  ; observation : Agent_sdk.Llm_provider.Request_wire_observer.observation
  }

let empty_prompt_segment_metrics =
  { bytes = 0; fingerprint = None }

let prompt_segment_metrics_of_text (text : string) : prompt_segment_metrics =
  let text = Inference_utils.sanitize_text_utf8 text in
  {
    bytes = String.length text;
    fingerprint =
      (if text = ""
       then None
       else Some Digestif.SHA256.(digest_string text |> to_hex));
  }

let build_prompt_metrics ~(system_prompt : string) ~(dynamic_context : string)
    ~(user_message : string) : prompt_metrics =
  let system_prompt = Inference_utils.sanitize_text_utf8 system_prompt in
  let dynamic_context = Inference_utils.sanitize_text_utf8 dynamic_context in
  let user_message = Inference_utils.sanitize_text_utf8 user_message in
  let system_prompt_metrics = prompt_segment_metrics_of_text system_prompt in
  let dynamic_context_metrics = prompt_segment_metrics_of_text dynamic_context in
  let user_message_metrics = prompt_segment_metrics_of_text user_message in
  let fingerprint_input =
    `Assoc
      [
        ("system_prompt", `String system_prompt);
        ("dynamic_context", `String dynamic_context);
        ("user_message", `String user_message);
      ]
    |> Yojson.Safe.to_string
  in
  {
    fingerprint = Digestif.SHA256.(digest_string fingerprint_input |> to_hex);
    total_bytes =
      (system_prompt_metrics.bytes
       + dynamic_context_metrics.bytes
       + user_message_metrics.bytes);
    cacheable_bytes = system_prompt_metrics.bytes;
    system_prompt_segment = system_prompt_metrics;
    dynamic_context_segment = dynamic_context_metrics;
    user_message_segment = user_message_metrics;
  }

let prompt_segment_metrics_to_json (segment : prompt_segment_metrics) :
    Yojson.Safe.t =
  `Assoc
    [
      ("bytes", `Int segment.bytes);
      ("fingerprint", Json_util.string_opt_to_json segment.fingerprint);
    ]

let prompt_metrics_to_json (metrics : prompt_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("fingerprint", `String metrics.fingerprint);
      ("total_bytes", `Int metrics.total_bytes);
      ("cacheable_bytes", `Int metrics.cacheable_bytes);
      ("system_prompt", prompt_segment_metrics_to_json metrics.system_prompt_segment);
      ("dynamic_context", prompt_segment_metrics_to_json metrics.dynamic_context_segment);
      ("user_message", prompt_segment_metrics_to_json metrics.user_message_segment);
    ]

let add_segment_metric
    (totals : (string, prompt_segment_metrics) Hashtbl.t)
    ~(bucket : string)
    (metric : prompt_segment_metrics) : unit =
  let prev =
    match Hashtbl.find_opt totals bucket with
    | Some existing -> existing
    | None -> empty_prompt_segment_metrics
  in
  Hashtbl.replace totals bucket
    {
      bytes = prev.bytes + metric.bytes;
      fingerprint = None;
    }

let metric_of_block
    ~role:(_ : Agent_sdk.Types.role)
    (block : Agent_sdk.Types.content_block) : prompt_segment_metrics =
  let bytes =
    match Canonical_tool.tool_result_of_block block with
    | Some result ->
        String.length
          (Inference_utils.sanitize_text_utf8 result.Canonical_tool.call_id)
        + String.length
            (Inference_utils.sanitize_text_utf8 result.Canonical_tool.content)
        + (match result.Canonical_tool.structured_content with
           | Some value -> String.length (Yojson.Safe.to_string value)
           | None -> 0)
    | None -> (
        match Canonical_tool.tool_call_of_block block with
        | Some call ->
            String.length
              (Inference_utils.sanitize_text_utf8 call.Canonical_tool.call_id)
            + String.length
                (Inference_utils.sanitize_text_utf8 call.Canonical_tool.name)
            + String.length (Yojson.Safe.to_string call.Canonical_tool.input)
        | None -> (
          match block with
          | Agent_sdk.Types.Text text ->
              String.length (Inference_utils.sanitize_text_utf8 text)
          | Agent_sdk.Types.ToolResult _ ->
              invalid_arg
                "keeper_agent_prompt_metrics: OAS canonical tool-result projection unavailable"
          | Agent_sdk.Types.ToolUse _ ->
              invalid_arg
                "keeper_agent_prompt_metrics: OAS canonical tool-call projection unavailable"
          | _ -> 0))
  in
  { bytes; fingerprint = None }

let history_bucket_of_block
    ~(role : Agent_sdk.Types.role)
    (block : Agent_sdk.Types.content_block) : string =
  if Option.is_some (Canonical_tool.tool_call_of_block block) then
    "history_tool_use"
  else
    match block with
  | Agent_sdk.Types.ToolResult _ -> "history_tool_result"
  | Agent_sdk.Types.ToolUse _ ->
      invalid_arg
        "keeper_agent_prompt_metrics: OAS canonical tool-call projection unavailable"
  | Agent_sdk.Types.Text _ -> (
      match role with
      | Agent_sdk.Types.User -> "history_user"
      | Agent_sdk.Types.Assistant | Agent_sdk.Types.System ->
          "history_assistant_text"
      | Agent_sdk.Types.Tool -> "history_tool_result")
  | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.ReasoningDetails _ ->
      "history_thinking"
  | Agent_sdk.Types.RedactedThinking _ -> "history_redacted_thinking"
  | Agent_sdk.Types.Image _ -> "history_image"
  | Agent_sdk.Types.Document _ -> "history_document"
  | Agent_sdk.Types.Audio _ -> "history_audio"

let prepared_origin_name = function
  | Agent_sdk.Agent.Canonical_history -> "canonical_history"
  | Agent_sdk.Agent.Current_user -> "current_user"
  | Agent_sdk.Agent.Extra_system_context -> "extra_system_context"
  | Agent_sdk.Agent.Caller_projection { source } ->
    "caller_projection." ^ source
;;

let content_kind = function
  | Agent_sdk.Types.Text _ -> "text"
  | Agent_sdk.Types.Thinking _ -> "thinking"
  | Agent_sdk.Types.ReasoningDetails _ -> "reasoning_details"
  | Agent_sdk.Types.RedactedThinking _ -> "redacted_thinking"
  | Agent_sdk.Types.ToolUse _ -> "tool_use"
  | Agent_sdk.Types.ToolResult _ -> "tool_result"
  | Agent_sdk.Types.Image _ -> "image"
  | Agent_sdk.Types.Document _ -> "document"
  | Agent_sdk.Types.Audio _ -> "audio"
;;

let serialized_json_metric json =
  prompt_segment_metrics_of_text (Yojson.Safe.to_string json)
;;

let sorted_segments totals =
  Hashtbl.to_seq totals
  |> List.of_seq
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
;;

let sum_segments segments =
  List.fold_left (fun acc (_, metric) -> acc + metric.bytes) 0 segments
;;

let build_ctx_composition_metrics
    ~(sdk_turn : int)
    ~(system_prompt : string)
    ~(tools : Agent_sdk.Tool.t list)
    ~(prepared_messages : Agent_sdk.Agent.prepared_message list)
    ~(context_blocks : Turn_record.prompt_block list)
    ~(request_wire :
        Agent_sdk.Llm_provider.Request_wire_observer.observation option)
    ~(actual_input_tokens : int option) : ctx_composition_metrics =
  let origin_totals : (string, prompt_segment_metrics) Hashtbl.t =
    Hashtbl.create 8
  in
  let content_totals : (string, prompt_segment_metrics) Hashtbl.t =
    Hashtbl.create 16
  in
  let system_prompt_metric = prompt_segment_metrics_of_text system_prompt in
  if system_prompt_metric.bytes > 0
  then add_segment_metric origin_totals ~bucket:"system_prompt" system_prompt_metric;
  let tools_metric =
    tools
    |> List.map Agent_sdk.Tool.schema_to_json
    |> fun schemas -> serialized_json_metric (`List schemas)
  in
  if tools_metric.bytes > 0
  then add_segment_metric origin_totals ~bucket:"tool_schemas" tools_metric;
  List.iter
    (fun prepared ->
       let origin =
         Agent_sdk.Agent.prepared_message_origin prepared
         |> prepared_origin_name
       in
       let message = Agent_sdk.Agent.prepared_message_value prepared in
       let message_metric =
         Agent_sdk.Llm_provider.Api_common.message_to_json message
         |> serialized_json_metric
       in
       add_segment_metric origin_totals ~bucket:origin message_metric;
       List.iter
         (fun block ->
            let bucket = origin ^ "." ^ content_kind block in
            let metric =
              Agent_sdk.Llm_provider.Api_common.content_block_to_json block
              |> serialized_json_metric
            in
            add_segment_metric content_totals ~bucket metric)
         message.content)
    prepared_messages;
  let origin_segments = sorted_segments origin_totals in
  let content_segments = sorted_segments content_totals in
  let context_block_segments =
    context_blocks
    |> List.filter_map (fun (block : Turn_record.prompt_block) ->
      if Prompt_block_id.equal block.block Prompt_block_id.Persona
      then None
      else
        Some
          ( Prompt_block_id.to_string block.block
          , { bytes = block.bytes; fingerprint = Some block.digest } ))
  in
  let request_body_bytes, request_body_sha256 =
    match request_wire with
    | Some observation ->
      Some observation.body_bytes, Some observation.body_sha256
    | None -> None, None
  in
  let actual_input_tokens =
    match actual_input_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> None
  in
  {
    actual_input_tokens;
    sdk_turn;
    prepared_component_bytes = sum_segments origin_segments;
    request_body_bytes;
    request_body_sha256;
    origin_segments;
    content_segments;
    context_block_segments;
  }

let ctx_composition_to_json (metrics : ctx_composition_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("actual_input_tokens", Json_util.int_opt_to_json metrics.actual_input_tokens);
      ("sdk_turn", `Int metrics.sdk_turn);
      ("prepared_component_bytes", `Int metrics.prepared_component_bytes);
      ("request_body_bytes", Json_util.int_opt_to_json metrics.request_body_bytes);
      ("request_body_sha256", Json_util.string_opt_to_json metrics.request_body_sha256);
      ( "origin_segments",
        `Assoc
          (List.map
             (fun (key, value) -> (key, prompt_segment_metrics_to_json value))
             metrics.origin_segments) );
      ( "content_segments",
        `Assoc
          (List.map
             (fun (key, value) -> (key, prompt_segment_metrics_to_json value))
             metrics.content_segments) );
      ( "context_block_segments",
        `Assoc
          (List.map
             (fun (key, value) -> (key, prompt_segment_metrics_to_json value))
             metrics.context_block_segments) );
    ]
