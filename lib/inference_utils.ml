(** Inference_utils — inference utility functions.

    Usage helpers, UTF-8 sanitization, and
    concurrency diagnostics.  Extracted from the former [Runtime]
    module during the Runtime deletion refactor.

    @since 2.125.0 — extracted from Runtime *)

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

(* Delegation to the canonical clamped reader (RFC-0371 B7); this was one of
   four raw copies of the same helper. *)
let int_of_env_default name ~default ~min_v ~max_v =
  Env_config_core.get_int_clamped ~default ~min_v ~max_v name

(* ================================================================ *)
(* Usage helpers                                                     *)
(* ================================================================ *)

(** Total tokens — delegates to AGENT_CORE [Agent_core.Types.total_tokens] (F12 canonical
    projection consumption: AGENT_CORE owns api_usage arithmetic, MASC consumes). *)
let total_tokens = Agent_core.Types.total_tokens

(** Zero usage marker — delegates to AGENT_CORE [Agent_core.Types.zero_api_usage] (F4
    canonical projection consumption: removes re-spelled record literal).
    @since 2.123.0 — delegated to AGENT_CORE *)
let zero_usage = Agent_core.Types.zero_api_usage

(** Extract usage from an api_response, defaulting to zero.
    @since 2.123.0 *)
let usage_of_response (resp : Agent_core.Types.api_response) : Agent_core.Types.api_usage =
  match resp.usage with Some u -> u | None -> zero_usage

(** Convert elapsed seconds to integer milliseconds for telemetry. *)
let elapsed_duration_ms elapsed_s =
  let elapsed_ms = elapsed_s *. 1000.0 in
  if (not (Float.is_finite elapsed_ms)) || Float.compare elapsed_ms 0.0 <= 0
  then 0
  else max 1 (int_of_float elapsed_ms)

(** Measure wall-clock latency of a thunk in milliseconds. *)
let timed (f : unit -> 'a) : 'a * int =
  let t0 = Time_compat.now () in
  let result = f () in
  let ms = elapsed_duration_ms (Time_compat.now () -. t0) in
  (result, ms)

(* ================================================================ *)
(* UTF-8 Sanitization                                               *)
(* ================================================================ *)

let sanitize_text_utf8 = Safe_ops.sanitize_text_utf8

let sanitize_json_utf8 = Safe_ops.sanitize_json_utf8

let rec sanitize_content_blocks_utf8
    (blocks : Agent_core.Types.content_block list)
  : Agent_core.Types.content_block list =
  match blocks with
  | [] -> blocks
  | block :: rest ->
      let sanitized_block =
        match block with
        | Agent_core.Types.Text s ->
            let sanitized = sanitize_text_utf8 s in
            if sanitized == s then block else Agent_core.Types.Text sanitized
        | Agent_core.Types.ReasoningDetails { reasoning_content; details } ->
            let sanitized_reasoning_content, reasoning_content_changed =
              match reasoning_content with
              | None -> (None, false)
              | Some content ->
                  let sanitized = sanitize_text_utf8 content in
                  (Some sanitized, sanitized != content)
            in
            let sanitize_detail (detail : Agent_core.Types.reasoning_detail) =
              let sanitized_raw = sanitize_json_utf8 detail.raw in
              let sanitized_text, text_changed =
                match detail.text with
                | None -> (None, false)
                | Some text ->
                    let sanitized = sanitize_text_utf8 text in
                    (Some sanitized, sanitized != text)
              in
              ( { Agent_core.Types.raw = sanitized_raw; text = sanitized_text }
              , sanitized_raw != detail.raw || text_changed )
            in
            let sanitized_details, details_changed =
              List.fold_right
                (fun detail (details, changed) ->
                  let sanitized, detail_changed = sanitize_detail detail in
                  sanitized :: details, changed || detail_changed)
                details
                ([], false)
            in
            if (not reasoning_content_changed) && not details_changed
            then block
            else
              Agent_core.Types.ReasoningDetails
                {
                  reasoning_content = sanitized_reasoning_content;
                  details = sanitized_details;
                }
        | Agent_core.Types.ToolUse { id; name; input } ->
            let sanitized_id = sanitize_text_utf8 id in
            let sanitized_name = sanitize_text_utf8 name in
            let sanitized_input = sanitize_json_utf8 input in
            if sanitized_id == id
               && sanitized_name == name
               && sanitized_input == input
            then block
            else
              Agent_core.Types.ToolUse
                {
                  id = sanitized_id;
                  name = sanitized_name;
                  input = sanitized_input;
                }
        | Agent_core.Types.ToolResult
            {
              tool_use_id;
              content;
              outcome;
              json;
              content_blocks;
            } ->
            let sanitized_tool_use_id = sanitize_text_utf8 tool_use_id in
            let sanitized_content = sanitize_text_utf8 content in
            let sanitized_json, json_changed =
              match json with
              | None -> (None, false)
              | Some value ->
                  let sanitized = sanitize_json_utf8 value in
                  (Some sanitized, sanitized != value)
            in
            if sanitized_tool_use_id == tool_use_id
               && sanitized_content == content
               && not json_changed
            then block
            else
              Agent_core.Types.ToolResult {
                tool_use_id = sanitized_tool_use_id;
                content = sanitized_content;
                outcome;
                json = sanitized_json;
                content_blocks;
              }
        | _ -> block
      in
      let sanitized_rest = sanitize_content_blocks_utf8 rest in
      if sanitized_block == block && sanitized_rest == rest then blocks
      else sanitized_block :: sanitized_rest

let sanitize_message_utf8 (m : Agent_core.Types.message) : Agent_core.Types.message =
  let sanitized_content = sanitize_content_blocks_utf8 m.content in
  if sanitized_content == m.content then m
  else { m with content = sanitized_content }

(* ================================================================ *)
(* Concurrency diagnostics (observability only, no throttling)       *)
(* ================================================================ *)

(** Maximum concurrent model calls — retained for diagnostics/dashboard.
    No longer enforced via semaphore: llama-server handles slot-based
    parallelism internally, and cloud APIs return rate-limit errors. *)
let max_concurrent_models =
  int_of_env_default "MASC_MAX_CONCURRENT_MODELS" ~default:8 ~min_v:1 ~max_v:128
