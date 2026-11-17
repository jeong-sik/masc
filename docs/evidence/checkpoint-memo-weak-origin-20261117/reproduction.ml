open Agent_core
module O = Objects_under_test
let checkpoint messages : Checkpoint.t =
  { provider_binding = None
  ; version = Checkpoint.checkpoint_version
  ; session_id = "objects-session"
  ; agent_name = "objects-agent"
  ; model = "objects-model"
  ; system_prompt = Some "be brief"
  ; messages
  ; usage = Types.empty_usage
  ; turn_count = List.length messages
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Types.Off
  ; reasoning_effort = None
  ; cache_system_prompt = false
  ; context = Context.create_sync ()
  ; pending_input = None
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let require = function Ok x -> x | Error _ -> failwith "checkpoint refused"
let memo_slot : O.memo option ref = ref None
let cycles () = for _ = 1 to 8 do Gc.full_major () done
let[@inline never] setup () =
  let payload = String.make (16 * 1024 * 1024) 'p' in
  let message = Types.make_message ~role:Types.Tool
    [Types.ToolResult {tool_use_id="call-retention";content="small persisted result";
      outcome=Llm_provider.Types.Tool_succeeded;json=Some (`String payload);content_blocks=None}] in
  let payload_weak = Weak.create 1 and message_weak = Weak.create 1 in
  Weak.set payload_weak 0 (Some payload); Weak.set message_weak 0 (Some message);
  let memo = O.create_memo () in
  let plan = require (O.plan_save memo O.Turn_closes (checkpoint [message])) in
  let encoded_bytes = O.memo_encoded_bytes memo in
  memo_slot := Some memo;
  plan.decoded, payload_weak, message_weak, encoded_bytes
let () =
  let decoded, payload, original, encoded_bytes = setup () in
  let omitted_json = match decoded.messages with
    | [message] -> List.exists (function
      | Types.ToolResult {json;_} -> Option.is_none json
      | Types.Text _ | Types.Thinking _ | Types.ReasoningDetails _
      | Types.RedactedThinking _ | Types.ToolUse _ | Types.Image _
      | Types.Document _ | Types.Audio _ -> false) message.content
    | [] | _ :: _ -> false in
  if not omitted_json then failwith "fixture json was not omitted by writer";
  cycles ();
  let payload_with_memo = Weak.check payload 0 and original_with_memo = Weak.check original 0 in
  memo_slot := None;
  cycles ();
  let payload_after_memo_release = Weak.check payload 0 and original_after_memo_release = Weak.check original 0 in
  ignore (Sys.opaque_identity decoded);
  Printf.printf "{\"payload_bytes\":%d,\"memo_encoded_bytes\":%d,\"writer_omitted_json\":%b,\"payload_alive_with_memo\":%b,\"original_alive_with_memo\":%b,\"payload_alive_after_memo_release\":%b,\"original_alive_after_memo_release\":%b,\"full_major_cycles_per_phase\":8}\n"
    (16*1024*1024) encoded_bytes omitted_json payload_with_memo original_with_memo payload_after_memo_release original_after_memo_release
