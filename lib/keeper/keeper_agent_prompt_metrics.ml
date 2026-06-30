(** Prompt metrics and adaptive inference helpers for keeper Agent.run turns. *)

module Canonical_tool = Agent_sdk.Canonical_tool

let adaptive_thinking_budget
      ~enabled
      ~is_retry
      ~last_tool_results
      ~current_budget
  =
  if not enabled
  then current_budget
  else (
    let had_error =
      List.exists
        (fun (r : Agent_sdk.Types.tool_result) ->
           match r with
           | Error _ -> true
           | Ok _ -> false)
        last_tool_results
    in
    if is_retry || had_error
    then Some 1500
    else current_budget)
;;

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] contains hard constraints (identity, policy guards,
    tool guidance, direct-reply mode) that must stay in the system prompt.
    [dynamic_context] contains soft context (continuity, skill route,
    worktree changes, turn instructions) injected via OAS
    [extra_system_context] — prepended as a User message after reduction. *)
type turn_prompt =
  { system_prompt : string
  ; dynamic_context : string
  }

(** Prompt segment metrics for effective keeper input attribution.
    Bytes are stored rather than character counts because prompts are UTF-8. *)
type prompt_segment_metrics =
  { bytes : int
  ; estimated_tokens : int
  ; fingerprint : string option
  }

(** Effective prompt metrics for a keeper turn.
    [estimated_cacheable_tokens] tracks the system prompt portion only because
    OAS prompt caching is enabled via [cache_system_prompt:true]. *)
type prompt_metrics =
  { fingerprint : string
  ; estimated_total_tokens : int
  ; estimated_cacheable_tokens : int
  ; system_prompt_segment : prompt_segment_metrics
  ; dynamic_context_segment : prompt_segment_metrics
  ; user_message_segment : prompt_segment_metrics
  }

type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; display_total_tokens : int
  ; estimated_known_tokens : int
  ; segments : (string * prompt_segment_metrics) list
  }

let empty_prompt_segment_metrics =
  { bytes = 0; estimated_tokens = 0; fingerprint = None }

let prompt_segment_metrics_of_text (text : string) : prompt_segment_metrics =
  let text = Inference_utils.sanitize_text_utf8 text in
  {
    bytes = String.length text;
    estimated_tokens =
      (if text = "" then 0 else Agent_sdk.Context_reducer.estimate_char_tokens text);
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
    estimated_total_tokens =
      (system_prompt_metrics.estimated_tokens
       + dynamic_context_metrics.estimated_tokens
       + user_message_metrics.estimated_tokens);
    estimated_cacheable_tokens = system_prompt_metrics.estimated_tokens;
    system_prompt_segment = system_prompt_metrics;
    dynamic_context_segment = dynamic_context_metrics;
    user_message_segment = user_message_metrics;
  }

let prompt_segment_metrics_to_json (segment : prompt_segment_metrics) :
    Yojson.Safe.t =
  `Assoc
    [
      ("bytes", `Int segment.bytes);
      ("estimated_tokens", `Int segment.estimated_tokens);
      ("fingerprint", Json_util.string_opt_to_json segment.fingerprint);
    ]

let prompt_metrics_to_json (metrics : prompt_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("fingerprint", `String metrics.fingerprint);
      ("estimated_total_tokens", `Int metrics.estimated_total_tokens);
      ("estimated_cacheable_tokens", `Int metrics.estimated_cacheable_tokens);
      ("system_prompt", prompt_segment_metrics_to_json metrics.system_prompt_segment);
      ("dynamic_context", prompt_segment_metrics_to_json metrics.dynamic_context_segment);
      ("user_message", prompt_segment_metrics_to_json metrics.user_message_segment);
    ]

let synthetic_prompt_segment_metrics ~estimated_tokens : prompt_segment_metrics =
  { bytes = 0; estimated_tokens; fingerprint = None }

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
      estimated_tokens = prev.estimated_tokens + metric.estimated_tokens;
      fingerprint = None;
    }

let metric_of_block
    ~(role : Agent_sdk.Types.role)
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
  let msg : Agent_sdk.Types.message = Agent_sdk.Types.make_message ~role [ block ] in
  {
    bytes;
    estimated_tokens = Keeper_context_core.msg_tokens msg;
    fingerprint = None;
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
      | Agent_sdk.Types.Assistant | Agent_sdk.Types.System ->
          "history_assistant_text"
      | Agent_sdk.Types.Tool -> "history_tool_result")
  | Agent_sdk.Types.Thinking _ | Agent_sdk.Types.ReasoningDetails _ ->
      "history_thinking"
  | Agent_sdk.Types.RedactedThinking _ -> "history_redacted_thinking"
  | Agent_sdk.Types.Image _ -> "history_image"
  | Agent_sdk.Types.Document _ -> "history_document"
  | Agent_sdk.Types.Audio _ -> "history_audio"

let build_ctx_composition_metrics
    ~(system_prompt : string)
    ~(dynamic_context : string)
    ~(memory_context : string)
    ~(temporal_context : string)
    ~(user_message : string)
    ~(history_messages : Agent_sdk.Types.message list)
    ~(actual_input_tokens : int option) : ctx_composition_metrics =
  let totals : (string, prompt_segment_metrics) Hashtbl.t = Hashtbl.create 16 in
  let add_text_segment bucket text =
    let metric = prompt_segment_metrics_of_text text in
    if metric.estimated_tokens > 0 then add_segment_metric totals ~bucket metric
  in
  add_text_segment "system_prompt" system_prompt;
  add_text_segment "dynamic_context" dynamic_context;
  add_text_segment "memory_context" memory_context;
  add_text_segment "temporal_context" temporal_context;
  add_text_segment "user_message" user_message;
  List.iter
    (fun (message : Agent_sdk.Types.message) ->
      List.iter
        (fun block ->
          let bucket = history_bucket_of_block ~role:message.role block in
          let metric = metric_of_block ~role:message.role block in
          if metric.estimated_tokens > 0 then add_segment_metric totals ~bucket metric)
        message.content)
    history_messages;
  let segments =
    Hashtbl.to_seq totals
    |> List.of_seq
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let estimated_known_tokens =
    List.fold_left
      (fun acc (_, metric) -> acc + metric.estimated_tokens)
      0 segments
  in
  let actual_input_tokens =
    match actual_input_tokens with
    | Some n when n > 0 -> Some n
    | Some _ | None -> None
  in
  let display_total_tokens =
    match actual_input_tokens with
    | Some actual -> max actual estimated_known_tokens
    | None -> estimated_known_tokens
  in
  let segments =
    if display_total_tokens > estimated_known_tokens then
      segments
      @ [ ( "unattributed",
            synthetic_prompt_segment_metrics
              ~estimated_tokens:(display_total_tokens - estimated_known_tokens) ) ]
    else segments
  in
  {
    actual_input_tokens;
    display_total_tokens;
    estimated_known_tokens;
    segments;
  }

let ctx_composition_to_json (metrics : ctx_composition_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("actual_input_tokens", Json_util.int_opt_to_json metrics.actual_input_tokens);
      ("display_total_tokens", `Int metrics.display_total_tokens);
      ("estimated_known_tokens", `Int metrics.estimated_known_tokens);
      ( "segments",
        `Assoc
          (List.map
             (fun (key, value) -> (key, prompt_segment_metrics_to_json value))
             metrics.segments) );
    ]
