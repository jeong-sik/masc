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
  ; attributed_bytes : int
  ; request_boundary_observed : bool
  ; segments : (string * prompt_segment_metrics) list
  }

type request_boundary_attribution =
  { extra_system_context_blocks : (Prompt_block_id.t * string) list
  ; current_user_message_index : int option
  ; extra_system_context_message_index : int option
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
  { bytes = Keeper_wake_telemetry.bytes_of_content_block block
  ; fingerprint = None
  }

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
      | Agent_sdk.Types.Assistant -> "history_assistant_text"
      | Agent_sdk.Types.System -> "history_system"
      | Agent_sdk.Types.Tool -> "history_tool_result")
  | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.ReasoningDetails _ ->
      "history_thinking"
  | Agent_sdk.Types.RedactedThinking _ -> "history_redacted_thinking"
  | Agent_sdk.Types.Image _ -> "history_image"
  | Agent_sdk.Types.Document _ -> "history_document"
  | Agent_sdk.Types.Audio _ -> "history_audio"

let build_ctx_composition_metrics
      ~(system_prompt : string)
      ~(attribution : request_boundary_attribution)
      ~(messages : Agent_sdk.Types.message list)
      ~(tools : Agent_sdk.Tool.t list)
      ~(actual_input_tokens : int option)
  : ctx_composition_metrics
  =
  let totals : (string, prompt_segment_metrics) Hashtbl.t = Hashtbl.create 16 in
  let add_text_segment bucket text =
    let metric = prompt_segment_metrics_of_text text in
    if metric.bytes > 0 then add_segment_metric totals ~bucket metric
  in
  add_text_segment "system_prompt" system_prompt;
  let block_bytes =
    List.fold_left
      (fun total (_, text) -> total + String.length text)
      0
      attribution.extra_system_context_blocks
  in
  let extra_system_context_message_bytes = ref 0 in
  List.iteri
    (fun message_index (message : Agent_sdk.Types.message) ->
      match attribution.extra_system_context_message_index with
      | Some index when Int.equal index message_index ->
        extra_system_context_message_bytes :=
          List.fold_left
            (fun total block ->
               total + (metric_of_block ~role:message.role block).bytes)
            0
            message.content
      | Some _ | None ->
        List.iter
          (fun block ->
            let bucket =
              match attribution.current_user_message_index, message.role with
              | Some index, Agent_sdk.Types.User when Int.equal index message_index ->
                "current_user"
              | (Some _ | None), _ ->
                history_bucket_of_block ~role:message.role block
            in
            let metric = metric_of_block ~role:message.role block in
            if metric.bytes > 0 then add_segment_metric totals ~bucket metric)
          message.content)
    messages;
  let extra_system_context_message_bytes =
    !extra_system_context_message_bytes
  in
  if extra_system_context_message_bytes >= block_bytes
  then (
    List.iter
      (fun (block, text) ->
         add_text_segment (Prompt_block_id.to_string block) text)
      attribution.extra_system_context_blocks;
    let existing_or_joiner_bytes =
      extra_system_context_message_bytes - block_bytes
    in
    if existing_or_joiner_bytes > 0
    then
      add_segment_metric totals
        ~bucket:"extra_system_context_existing_or_joiners"
        { bytes = existing_or_joiner_bytes; fingerprint = None })
  else if extra_system_context_message_bytes > 0
  then
    add_segment_metric totals
      ~bucket:"extra_system_context_existing_or_joiners"
      { bytes = extra_system_context_message_bytes; fingerprint = None };
  let tool_schema_bytes =
    Keeper_wake_telemetry.bytes_of_tool_schema_json tools
  in
  if tool_schema_bytes > 0
  then
    add_segment_metric totals ~bucket:"tool_schemas"
      { bytes = tool_schema_bytes; fingerprint = None };
  let segments =
    Hashtbl.to_seq totals
    |> List.of_seq
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let attributed_bytes =
    List.fold_left
      (fun acc (_, metric) -> acc + metric.bytes)
      0 segments
  in
  let actual_input_tokens =
    match actual_input_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> None
  in
  {
    actual_input_tokens;
    attributed_bytes;
    request_boundary_observed = true;
    segments;
  }

let with_actual_input_tokens metrics actual_input_tokens =
  let actual_input_tokens =
    match actual_input_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> None
  in
  { metrics with actual_input_tokens }

let unavailable_ctx_composition ~actual_input_tokens =
  { actual_input_tokens
  ; attributed_bytes = 0
  ; request_boundary_observed = false
  ; segments = []
  }

let ctx_composition_to_json (metrics : ctx_composition_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("actual_input_tokens", Json_util.int_opt_to_json metrics.actual_input_tokens);
      ("attributed_bytes", `Int metrics.attributed_bytes);
      ("request_boundary_observed", `Bool metrics.request_boundary_observed);
      ( "segments",
        `Assoc
          (List.map
             (fun (key, value) -> (key, prompt_segment_metrics_to_json value))
             metrics.segments) );
    ]
