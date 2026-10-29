(** Pure byte-size and role-count observation for keeper wake-time payloads.

    Extracted from [Keeper_agent_run] so the arithmetic is unit-testable
    without standing up a live keeper. The functions here operate purely
    on [Agent_core] values and return plain records/ints; they never
    touch stores, logs, or side effects. Callers (currently
    [Keeper_agent_run]) feed every result to
    [Dashboard_harness_health.record_wake_payload].

    Invariant: [result.message_count =
      List.fold_left (fun a (_, n) -> a + n) 0 result.role_counts].
    Both include the pending user turn that AGENT_CORE will synthesize from
    [~goal_blocks] when present, or [~goal] otherwise. *)


type sizes = {
  system_prompt_bytes : int;
  tool_schema_json_bytes : int;
  message_content_bytes : int;
  message_count : int;
  role_counts : (string * int) list;
  tool_count : int;
}

let role_key : Agent_core.Types.role -> string = Agent_core.Types.role_to_string

let bytes_of_content_block (block : Agent_core.Types.content_block) : int =
  match block with
  | Agent_core.Types.ToolResult { tool_use_id; content; _ } ->
    String.length tool_use_id + String.length content
  | Agent_core.Types.ToolUse { id; name; input } ->
    String.length id + String.length name + String.length (Yojson.Safe.to_string input)
  | Agent_core.Types.Text s -> String.length s
  | Agent_core.Types.Thinking { content; _ } -> String.length content
  | Agent_core.Types.ReasoningDetails { reasoning_content; details } ->
    Agent_core.Types.reasoning_details_text ~reasoning_content ~details |> String.length
  | Agent_core.Types.RedactedThinking s -> String.length s
  | Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _ ->
    Agent_core.History.media_wire_length block

let bytes_of_message_content (m : Agent_core.Types.message) : int =
  List.fold_left
    (fun acc b -> acc + bytes_of_content_block b)
    0 m.content

let bytes_of_tool_schema_json (tools : Agent_core.Tool.t list) : int =
  List.fold_left
    (fun acc t ->
      acc
      + Agent_core.Tool.wire_bytes_of_schema t.Agent_core.Tool.schema)
    0 tools

(** Count role occurrences across [history_messages], then add [+1] to
    the "user" slot for the pending turn AGENT_CORE will synthesize from
    [~goal]. Returned as a stable-sorted assoc list for deterministic
    JSON output. *)
let role_counts_with_pending_user
    (history_messages : Agent_core.Types.message list) :
    (string * int) list =
  let tbl = Hashtbl.create 5 in
  let increment_role key =
    match Hashtbl.find_opt tbl key with
    | None -> Hashtbl.add tbl key 1
    | Some count -> Hashtbl.replace tbl key (count + 1)
  in
  List.iter
    (fun (m : Agent_core.Types.message) ->
      increment_role (role_key m.role))
    history_messages;
  increment_role (role_key Agent_core.Types.User);
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let compute_sizes
    ~(system_prompt : string)
    ~(tools : Agent_core.Tool.t list)
    ~(history_messages : Agent_core.Types.message list)
    ?user_blocks
    ~(user_message : string)
    () : sizes =
  let system_prompt_bytes = String.length system_prompt in
  let tool_schema_json_bytes = bytes_of_tool_schema_json tools in
  let history_content_bytes =
    List.fold_left
      (fun acc m -> acc + bytes_of_message_content m)
      0 history_messages
  in
  let pending_user_blocks =
    match user_blocks with
    | Some blocks -> blocks
    | None -> [ Agent_core.Types.Text user_message ]
  in
  let pending_user_content_bytes =
    List.fold_left
      (fun acc block -> acc + bytes_of_content_block block)
      0 pending_user_blocks
  in
  let message_content_bytes = history_content_bytes + pending_user_content_bytes in
  let role_counts = role_counts_with_pending_user history_messages in
  let message_count = List.length history_messages + 1 in
  {
    system_prompt_bytes;
    tool_schema_json_bytes;
    message_content_bytes;
    message_count;
    role_counts;
    tool_count = List.length tools;
  }
