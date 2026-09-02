(** Prompt metrics for keeper Agent.run turns. *)

module Canonical_tool = Agent_core.Canonical_tool

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] contains hard constraints (identity, policy guards,
    tool guidance, direct-reply mode) that must stay in the system prompt.
    [dynamic_context] contains soft context (continuity, skill route,
    worktree changes, turn instructions) injected via AGENT_CORE
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
  ; segments : (Turn_record.input_component_id * prompt_segment_metrics) list
  }

let rec split_at count rev_prefix values =
  if count = 0
  then Some (List.rev rev_prefix, values)
  else
    match values with
    | value :: rest -> split_at (count - 1) (value :: rev_prefix) rest
    | [] -> None
;;

type provenance_failure =
  | Input_prefix_dropped of
      { projection_input_messages : int
      ; projected_messages : int
      }
  | Input_prefix_rewritten of { first_divergent_index : int }
  | Prompt_context_carrier_metadata_invalid
  | Prompt_context_carrier_metadata_duplicate
  | Prompt_context_carrier_repeated
  | Prompt_context_presence_mismatch of
      { carrier_observed : bool
      ; prompt_context_present : bool
      }

let provenance_failure_reason = function
  | Input_prefix_dropped _ -> "projection_dropped_input_prefix"
  | Input_prefix_rewritten _ -> "projection_rewrote_input_prefix"
  | Prompt_context_carrier_metadata_invalid ->
    "prompt_context_carrier_metadata_invalid"
  | Prompt_context_carrier_metadata_duplicate ->
    "prompt_context_carrier_metadata_duplicate"
  | Prompt_context_carrier_repeated -> "prompt_context_carrier_repeated"
  | Prompt_context_presence_mismatch _ -> "prompt_context_presence_mismatch"
;;

(* [None] rather than [""]: a failure that carries no measured value and one
   whose value is legitimately empty are different facts, and a sentinel makes
   the second silently read as the first. *)
let provenance_failure_detail = function
  | Input_prefix_dropped { projection_input_messages; projected_messages } ->
    Some
      (Printf.sprintf "handed=%d returned=%d" projection_input_messages
         projected_messages)
  | Input_prefix_rewritten { first_divergent_index } ->
    Some (Printf.sprintf "first_divergent_index=%d" first_divergent_index)
  | Prompt_context_carrier_metadata_invalid
  | Prompt_context_carrier_metadata_duplicate
  | Prompt_context_carrier_repeated -> None
  | Prompt_context_presence_mismatch { carrier_observed; prompt_context_present }
    ->
    Some
      (Printf.sprintf "carrier_observed=%b prompt_context_present=%b"
         carrier_observed prompt_context_present)
;;

(* The one place the two halves are joined. It used to live at the call site,
   which left the no-detail branch untested: a test that rebuilds the line
   itself agrees with whatever it rebuilt, not with what the keeper logs. *)
let provenance_failure_summary failure =
  let reason = provenance_failure_reason failure in
  match provenance_failure_detail failure with
  | None -> reason
  | Some detail -> reason ^ " " ^ detail
;;

(* The index is reported rather than a bare "not equal" because the two
   rewrites this separates need different fixes: a carrier the assembler
   inserted lands at a low index, a reordered tail lands near the end. *)
let first_divergent_index prefix input =
  let rec walk index prefix input =
    match prefix, input with
    | [], [] -> None
    | prefix_head :: prefix_rest, input_head :: input_rest ->
      if prefix_head = input_head
      then walk (index + 1) prefix_rest input_rest
      else Some index
    | [], _ :: _ | _ :: _, [] -> Some index
  in
  walk 0 prefix input
;;

let provider_content_messages
      ~prompt_context_present
      ~(projection_input : Agent_core.Types.message list)
      ~(projected_messages : Agent_core.Types.message list)
  =
  let projection_input_count = List.length projection_input in
  match split_at projection_input_count [] projected_messages with
  | None ->
    Error
      (Input_prefix_dropped
         { projection_input_messages = projection_input_count
         ; projected_messages = List.length projected_messages
         })
  | Some (projected_prefix, projection_suffix) ->
    (match first_divergent_index projected_prefix projection_input with
     | Some first_divergent_index ->
       Error (Input_prefix_rewritten { first_divergent_index })
     | None ->
       let rec remove_prompt_context seen rev_retained = function
         | [] ->
           if Bool.equal seen prompt_context_present
           then Ok (List.rev rev_retained)
           else
             Error
               (Prompt_context_presence_mismatch
                  { carrier_observed = seen; prompt_context_present })
         | (message : Agent_core.Types.message) :: rest ->
           (match
            Agent_core.Types.Extra_system_context_provenance.classify
                message.metadata
            with
            | Agent_core.Types.Extra_system_context_provenance.Absent ->
              remove_prompt_context seen (message :: rev_retained) rest
            | Agent_core.Types.Extra_system_context_provenance.Present
              when prompt_context_present && not seen ->
              remove_prompt_context true rev_retained rest
            | Agent_core.Types.Extra_system_context_provenance.Present ->
              if seen
              then Error Prompt_context_carrier_repeated
              else
                Error
                  (Prompt_context_presence_mismatch
                     { carrier_observed = true; prompt_context_present })
            | Agent_core.Types.Extra_system_context_provenance.Invalid ->
              Error Prompt_context_carrier_metadata_invalid
            | Agent_core.Types.Extra_system_context_provenance.Duplicate ->
              Error Prompt_context_carrier_metadata_duplicate)
       in
       Result.map
         (fun retained_input -> retained_input @ projection_suffix)
         (remove_prompt_context false [] projection_input))
;;

let empty_prompt_segment_metrics =
  { bytes = 0; fingerprint = None }

let prompt_segment_metrics_of_sanitized_text (text : string) : prompt_segment_metrics =
  {
    bytes = String.length text;
    fingerprint =
      (if text = ""
       then None
       else Some Digestif.SHA256.(digest_string text |> to_hex));
  }

let build_prompt_metrics_with_sanitizer ~sanitize
    ~(system_prompt : string) ~(dynamic_context : string)
    ~(user_message : string) : prompt_metrics =
  let system_prompt = sanitize system_prompt in
  let dynamic_context = sanitize dynamic_context in
  let user_message = sanitize user_message in
  (* These values were sanitized above for the fingerprint input. Reusing that
     exact text avoids scanning every prompt segment a second time merely to
     compute byte lengths and per-segment digests. *)
  let system_prompt_metrics =
    prompt_segment_metrics_of_sanitized_text system_prompt
  in
  let dynamic_context_metrics =
    prompt_segment_metrics_of_sanitized_text dynamic_context
  in
  let user_message_metrics =
    prompt_segment_metrics_of_sanitized_text user_message
  in
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

let build_prompt_metrics ~system_prompt ~dynamic_context ~user_message =
  build_prompt_metrics_with_sanitizer
    ~sanitize:Inference_utils.sanitize_text_utf8
    ~system_prompt
    ~dynamic_context
    ~user_message

module For_testing = struct
  let build_prompt_metrics_with_sanitizer = build_prompt_metrics_with_sanitizer
end

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

(* A bucket that receives one contribution keeps its fingerprint; a bucket
   that receives several loses it. Summing bytes is arithmetic, but there is
   no digest of two digests that names the concatenation, and answering with
   the first contribution's would name a part while the row says the whole.
   [Tool_schemas] is the single-contribution case the tool array needs: it is
   the provider's cache prefix, and only a fingerprint over the whole array in
   the order sent says whether two turns could share one. *)
let add_segment_metric
    (totals : (Turn_record.input_component_id, prompt_segment_metrics) Hashtbl.t)
    ~(bucket : Turn_record.input_component_id)
    (metric : prompt_segment_metrics) : unit =
  match Hashtbl.find_opt totals bucket with
  | None -> Hashtbl.replace totals bucket metric
  | Some prev ->
    Hashtbl.replace totals bucket
      { bytes = prev.bytes + metric.bytes; fingerprint = None }

let metric_of_block
    ~role:(_ : Agent_core.Types.role)
    (block : Agent_core.Types.content_block) : prompt_segment_metrics =
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
          | Agent_core.Types.Text text ->
              String.length (Inference_utils.sanitize_text_utf8 text)
          | Agent_core.Types.Thinking { content; _ } ->
              String.length (Inference_utils.sanitize_text_utf8 content)
          | Agent_core.Types.ReasoningDetails { reasoning_content; details } ->
              Agent_core.Types.reasoning_details_text ~reasoning_content ~details
              |> Inference_utils.sanitize_text_utf8
              |> String.length
          | Agent_core.Types.RedactedThinking text ->
              String.length (Inference_utils.sanitize_text_utf8 text)
          | Agent_core.Types.Image { data; _ }
          | Agent_core.Types.Document { data; _ }
          | Agent_core.Types.Audio { data; _ } -> String.length data
          | Agent_core.Types.ToolResult _ ->
              invalid_arg
                "keeper_agent_prompt_metrics: AGENT_CORE canonical tool-result projection unavailable"
          | Agent_core.Types.ToolUse _ ->
              invalid_arg
                "keeper_agent_prompt_metrics: AGENT_CORE canonical tool-call projection unavailable"))
  in
  { bytes; fingerprint = None }

let input_component_of_block
    ~(role : Agent_core.Types.role)
    (block : Agent_core.Types.content_block) : Turn_record.input_component_id =
  if Option.is_some (Canonical_tool.tool_call_of_block block)
  then Turn_record.Message_tool_use
  else
    match Canonical_tool.tool_result_of_block block with
    | Some _ -> Turn_record.Message_tool_result
    | None ->
      (match block with
  | Agent_core.Types.ToolResult _ -> Turn_record.Message_tool_result
  | Agent_core.Types.ToolUse _ ->
      invalid_arg
        "keeper_agent_prompt_metrics: AGENT_CORE canonical tool-call projection unavailable"
  | Agent_core.Types.Text _ -> (
      match role with
      | Agent_core.Types.User -> Turn_record.Message_user
      | Agent_core.Types.System -> Turn_record.Message_system
      | Agent_core.Types.Assistant -> Turn_record.Message_assistant_text
      | Agent_core.Types.Tool -> Turn_record.Message_tool_result)
  | Agent_core.Types.Thinking _ | Agent_core.Types.ReasoningDetails _ ->
      Turn_record.Message_thinking
  | Agent_core.Types.RedactedThinking _ -> Turn_record.Message_redacted_thinking
  | Agent_core.Types.Image _ -> Turn_record.Message_image
  | Agent_core.Types.Document _ -> Turn_record.Message_document
  | Agent_core.Types.Audio _ -> Turn_record.Message_audio)

let build_ctx_composition_metrics
    ~(prompt_blocks : Turn_record.prompt_block list)
    ~(tools : Agent_core.Tool.t list)
    ~(input_messages : Agent_core.Types.message list)
    ~(actual_input_tokens : int option) : ctx_composition_metrics =
  let totals :
      (Turn_record.input_component_id, prompt_segment_metrics) Hashtbl.t =
    Hashtbl.create 16
  in
  List.iter
    (fun (block : Turn_record.prompt_block) ->
      if block.bytes > 0
      then
        add_segment_metric totals
          ~bucket:(Turn_record.Prompt_block block.block)
          { bytes = block.bytes; fingerprint = Some block.digest })
    prompt_blocks;
  (* The tool array is the first segment of the provider's cache prefix, and
     what makes it reusable is byte-for-byte sameness including order. The
     digest is taken over the schemas as they are sent, so a reordering reads
     as a different tool surface here even when the same tools are present:
     two turns of one keeper whose fingerprints differ are two turns that
     could not share a cached prefix. *)
  let tool_schema_json =
    List.map (fun tool -> Yojson.Safe.to_string (Agent_core.Tool.schema_to_json tool)) tools
  in
  let tool_schema_bytes =
    List.fold_left (fun total json -> total + String.length json) 0 tool_schema_json
  in
  if tool_schema_bytes > 0
  then
    add_segment_metric totals
      ~bucket:Turn_record.Tool_schemas
      { bytes = tool_schema_bytes
      ; fingerprint =
          Some
            Digestif.SHA256.(
              digest_string (String.concat "\n" tool_schema_json) |> to_hex)
      };
  List.iter
    (fun (message : Agent_core.Types.message) ->
      List.iter
        (fun block ->
          let bucket = input_component_of_block ~role:message.role block in
          let metric = metric_of_block ~role:message.role block in
          if metric.bytes > 0 then add_segment_metric totals ~bucket metric)
        message.content)
    input_messages;
  let segments =
    Hashtbl.to_seq totals
    |> List.of_seq
    |> List.sort (fun (left, _) (right, _) ->
      String.compare
        (Turn_record.input_component_id_to_string left)
        (Turn_record.input_component_id_to_string right))
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
    segments;
  }

let ctx_composition_to_json (metrics : ctx_composition_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("actual_input_tokens", Json_util.int_opt_to_json metrics.actual_input_tokens);
      ("attributed_bytes", `Int metrics.attributed_bytes);
      ( "segments",
        `Assoc
          (List.map
             (fun (key, value) ->
               ( Turn_record.input_component_id_to_string key
               , prompt_segment_metrics_to_json value ))
             metrics.segments) );
    ]
