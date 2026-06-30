(** Pure byte-size and role-count estimation for keeper wake-time
    payload telemetry.

    Extracted from [Keeper_agent_run] so the arithmetic is unit-testable
    without standing up a live keeper. The functions here operate purely
    on [Agent_sdk] values and return plain records/ints; they never
    touch stores, logs, or side effects. Callers (currently
    [Keeper_agent_run]) feed the result to
    [Dashboard_harness_health.record_wake_payload] when
    [MASC_PAYLOAD_TELEMETRY] is on.

    Invariant: [result.message_count =
      List.fold_left (fun a (_, n) -> a + n) 0 result.role_counts].
    Both include the pending user turn that OAS will synthesize from
    [~goal], so downstream p95 analysis matches the wire-level view
    the LLM actually receives. *)

module Canonical_tool = Agent_sdk.Canonical_tool

type sizes = {
  system_prompt_bytes : int;
  tool_defs_bytes : int;
  messages_bytes : int;
  approx_body_bytes : int;
  message_count : int;
  role_counts : (string * int) list;
  tool_count : int;
}

let role_key : Agent_sdk.Types.role -> string = Agent_sdk.Types.role_to_string

let bytes_of_content_block (block : Agent_sdk.Types.content_block) : int =
  match Canonical_tool.tool_result_of_block block with
  | Some result ->
    String.length result.Canonical_tool.call_id
    + String.length result.Canonical_tool.content
  | None -> (
    match Canonical_tool.tool_call_of_block block with
    | Some call ->
      String.length call.Canonical_tool.call_id
      + String.length call.Canonical_tool.name
      + String.length (Yojson.Safe.to_string call.Canonical_tool.input)
    | None -> (
      match block with
      | Agent_sdk.Types.Text s -> String.length s
      | Agent_sdk.Types.Thinking { content; _ } -> String.length content
      | Agent_sdk.Types.ReasoningDetails { reasoning_content; details } ->
        Agent_sdk.Types.reasoning_details_text ~reasoning_content ~details
        |> String.length
      | Agent_sdk.Types.RedactedThinking s -> String.length s
      | Agent_sdk.Types.ToolResult _ ->
        invalid_arg
          "keeper_wake_telemetry: OAS canonical tool-result projection unavailable"
      | Agent_sdk.Types.ToolUse _ ->
        invalid_arg
          "keeper_wake_telemetry: OAS canonical tool-call projection unavailable"
      | Agent_sdk.Types.Image { data; _ }
      | Agent_sdk.Types.Document { data; _ }
      | Agent_sdk.Types.Audio { data; _ } -> String.length data))

let bytes_of_message (m : Agent_sdk.Types.message) : int =
  List.fold_left
    (fun acc b -> acc + bytes_of_content_block b)
    0 m.content

let estimate_tool_defs_bytes (tools : Agent_sdk.Tool.t list) : int =
  List.fold_left
    (fun acc t ->
      acc
      + String.length (Yojson.Safe.to_string (Agent_sdk.Tool.schema_to_json t)))
    0 tools

(** Count role occurrences across [history_messages], then add [+1] to
    the "user" slot for the pending turn OAS will synthesize from
    [~goal]. Returned as a stable-sorted assoc list for deterministic
    JSON output. *)
let role_counts_with_pending_user
    (history_messages : Agent_sdk.Types.message list) :
    (string * int) list =
  let tbl = Hashtbl.create 5 in
  List.iter
    (fun (m : Agent_sdk.Types.message) ->
      let key = role_key m.role in
      let cur = Hashtbl.find_opt tbl key |> Option.value ~default:0 in
      Hashtbl.replace tbl key (cur + 1))
    history_messages;
  let cur = Hashtbl.find_opt tbl "user" |> Option.value ~default:0 in
  Hashtbl.replace tbl "user" (cur + 1);
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let compute_sizes
    ~(system_prompt : string)
    ~(tools : Agent_sdk.Tool.t list)
    ~(history_messages : Agent_sdk.Types.message list)
    ~(user_message : string) : sizes =
  let system_prompt_bytes = String.length system_prompt in
  let tool_defs_bytes = estimate_tool_defs_bytes tools in
  let history_bytes =
    List.fold_left
      (fun acc m -> acc + bytes_of_message m)
      0 history_messages
  in
  let user_message_bytes = String.length user_message in
  let messages_bytes = history_bytes + user_message_bytes in
  let approx_body_bytes =
    system_prompt_bytes + tool_defs_bytes + messages_bytes
  in
  let role_counts = role_counts_with_pending_user history_messages in
  let message_count = List.length history_messages + 1 in
  {
    system_prompt_bytes;
    tool_defs_bytes;
    messages_bytes;
    approx_body_bytes;
    message_count;
    role_counts;
    tool_count = List.length tools;
  }
