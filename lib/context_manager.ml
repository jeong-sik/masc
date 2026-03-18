(** Context_manager — 3-tier memory with progressive compaction.

    Implements the working memory tier (Tier 1) with in-process
    operations and session persistence (Tier 2) via JSONL files.
    Tier 3 (semantic/pgvector) is accessed externally.

    Compaction pipeline:
    1. PruneToolOutputs — truncate verbose tool results
    2. MergeContiguous  — collapse consecutive same-role messages
    3. DropLowImportance — remove low-scored messages
    4. SummarizeOld — LLM-compress oldest messages (most aggressive)

    @since 2.61.0 *)

open Printf

let text_of_message = Llm_client.text_of_message

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type working_context = {
  system_prompt : string;
  messages : Llm_client.message list;
  token_count : int;
  max_tokens : int;
  importance_scores : (int * float) list;
  oas_context : Agent_sdk.Context.t;
}

type checkpoint = {
  checkpoint_id : string;
  timestamp : float;
  generation : int;
  message_count : int;
  token_count : int;
  serialized : string;
}

type session_context = {
  session_id : string;
  session_dir : string;
  mutable full_history : Llm_client.message list;
  mutable checkpoints : checkpoint list;
}

(** Re-export from [Compaction_types] for backward compatibility.
    All consumers that used [Context_manager.PruneToolOutputs] etc.
    continue to work without changes. *)
type compaction_strategy = Compaction_types.compaction_strategy =
  | PruneToolOutputs
  | MergeContiguous
  | DropLowImportance
  | SummarizeOld

type compaction_result = {
  context : working_context;
  offloaded_path : string option;
}

(* ================================================================ *)
(* Memory Formats                                                  *)
(* ================================================================ *)

let memory_summary_prefix = Context_scoring.memory_summary_prefix
let goal_prefix = Context_scoring.goal_prefix

let state_block_start = "[STATE]"
let state_block_end = "[/STATE]"

let starts_with = Context_scoring.starts_with

let find_substring ~needle haystack ~from =
  let n_len = String.length needle in
  let h_len = String.length haystack in
  let rec loop i =
    if i < 0 || i + n_len > h_len then None
    else if String.sub haystack i n_len = needle then Some i
    else loop (i + 1)
  in
  loop from

let extract_state_blocks (s : string) : string list =
  let rec loop from acc =
    match find_substring ~needle:state_block_start s ~from with
    | None -> List.rev acc
    | Some i ->
      let j_from = i + String.length state_block_start in
      (match find_substring ~needle:state_block_end s ~from:j_from with
       | None -> List.rev acc
       | Some j ->
         let body = String.sub s j_from (j - j_from) |> String.trim in
         let next_from = j + String.length state_block_end in
         loop next_from (body :: acc))
  in
  loop 0 []

(* ================================================================ *)
(* Filesystem Utilities                                             *)
(* ================================================================ *)

let ensure_dir path =
  Fs_compat.mkdir_p path

(* ================================================================ *)
(* Token Estimation                                                 *)
(* ================================================================ *)

(** Count tokens in a message (~4 chars/token + role overhead). *)
let msg_tokens (m : Llm_client.message) =
  (String.length (text_of_message m) / 4) + 4

let count_tokens (system_prompt : string) (msgs : Llm_client.message list) =
  let sys_tokens = (String.length system_prompt / 4) + 4 in
  List.fold_left (fun acc m -> acc + msg_tokens m) sys_tokens msgs

(* ================================================================ *)
(* Context Ratio                                                    *)
(* ================================================================ *)

let context_ratio (ctx : working_context) : float =
  if ctx.max_tokens = 0 then 0.0
  else float_of_int ctx.token_count /. float_of_int ctx.max_tokens

let exceeds_threshold ctx threshold =
  context_ratio ctx >= threshold

(* ================================================================ *)
(* Working Context Operations                                       *)
(* ================================================================ *)

let create ~system_prompt ~max_tokens =
  let token_count = (String.length system_prompt / 4) + 4 in
  let oas_context = Agent_sdk.Context.create () in
  { system_prompt; messages = []; token_count; max_tokens;
    importance_scores = []; oas_context }

let set_system_prompt (ctx : working_context) ~system_prompt =
  (* Avoid leaking prior compaction summaries into the "system prompt" channel for providers
     that treat all system-role messages as instructions (notably Claude). *)
  let messages =
    List.map (fun (m : Llm_client.message) ->
      if m.role = Llm_client.System then { m with role = Llm_client.Assistant } else m
    ) ctx.messages
  in
  let token_count = count_tokens system_prompt messages in
  { ctx with system_prompt; messages; token_count; importance_scores = [] }

let append ctx (msg : Llm_client.message) =
  let new_tokens = msg_tokens msg in
  { ctx with
    messages = ctx.messages @ [msg];
    token_count = ctx.token_count + new_tokens;
  }

let append_many ctx msgs =
  List.fold_left append ctx msgs

(* ================================================================ *)
(* Importance Scoring                                               *)
(* ================================================================ *)

(** Score messages by importance using shared scoring logic.
    Delegates to [Context_scoring.score_messages] (SSOT). *)
let score_importance ctx =
  let scores = Context_scoring.score_messages ctx.messages in
  { ctx with importance_scores = scores }

(* ================================================================ *)
(* Compaction Strategies                                            *)
(* ================================================================ *)

(** Truncate tool output messages longer than max_len.
    Keeps first keep_len and last keep_len characters with "[...truncated...]". *)
let prune_tool_outputs ?(max_len=500) ?(keep_len=100) ctx =
  let messages = List.map (fun (m : Llm_client.message) ->
    match m.role with
    | Llm_client.Tool when String.length (text_of_message m) > max_len ->
      let mc = text_of_message m in
      let head = String.sub mc 0 keep_len in
      let tail_start = String.length mc - keep_len in
      let tail = String.sub mc tail_start keep_len in
      { m with content = [Agent_sdk.Types.Text (sprintf "%s\n[...truncated %d chars...]\n%s"
          head (String.length mc - 2 * keep_len) tail)] }
    | _ -> m
  ) ctx.messages in
  let token_count = count_tokens ctx.system_prompt messages in
  { ctx with messages; token_count }

(** Merge consecutive messages with the same role. *)
let merge_contiguous ctx =
  let rec merge = function
    | [] -> []
    | [m] -> [m]
    | (m1 : Llm_client.message) :: (m2 :: rest as tail) ->
      if m1.role = m2.role then
        let merged = { m1 with content = [Agent_sdk.Types.Text (text_of_message m1 ^ "\n" ^ text_of_message m2)] } in
        merge (merged :: rest)
      else
        m1 :: merge tail
  in
  let messages = merge ctx.messages in
  let token_count = count_tokens ctx.system_prompt messages in
  { ctx with messages; token_count; importance_scores = [] }

(** Drop messages with importance score below threshold. *)
let drop_low_importance ?(threshold=0.3) ctx =
  let scored = if ctx.importance_scores = [] then
    (score_importance ctx).importance_scores
  else ctx.importance_scores in
  let messages = List.filteri (fun i _m ->
    match List.assoc_opt i scored with
    | Some score -> score >= threshold
    | None -> true  (* Keep if no score *)
  ) ctx.messages in
  let token_count = count_tokens ctx.system_prompt messages in
  { ctx with messages; token_count; importance_scores = [] }

(** Summarize oldest N% of messages into a single summary message.
    This is the most aggressive strategy — uses token estimation
    rather than actual LLM call (LLM summarization done externally). *)
let summarize_old ?(oldest_pct=0.3) ctx =
  let n = List.length ctx.messages in
  let split_at = max 1 (int_of_float (float_of_int n *. oldest_pct)) in
  if n <= 2 then ctx  (* Not enough messages to summarize *)
  else
    let old_msgs, recent_msgs = List.filteri (fun i _ -> i < split_at) ctx.messages,
                                 List.filteri (fun i _ -> i >= split_at) ctx.messages in
    (* Prefer structured continuity: keep recent [STATE] snapshots if present.
       Important: do NOT emit this as a System message. For Claude, system-role
       messages are concatenated into the system prompt, turning summaries into
       "instructions" and breaking behavior. *)
    let blocks =
      old_msgs
      |> List.concat_map (fun (m : Llm_client.message) -> extract_state_blocks (text_of_message m))
    in
    let take_last n lst =
      let len = List.length lst in
      if len <= n then lst
      else List.filteri (fun i _ -> i >= (len - n)) lst
    in
    let blocks_tail = take_last 3 blocks in
    let summary =
      if blocks_tail <> [] then
        let rendered =
          blocks_tail
          |> List.map (fun b -> sprintf "%s\n%s\n%s" state_block_start b state_block_end)
          |> String.concat "\n\n"
        in
        sprintf "%s\n(Extracted continuity snapshots; reference only.)\n\n%s"
          memory_summary_prefix rendered
      else
        (* Fallback heuristic: role-tagged truncation. *)
        let summary_parts = List.map (fun (m : Llm_client.message) ->
          let role_str = match m.role with
            | System -> "SYS" | User -> "USR"
            | Assistant -> "AST" | Tool -> "TOOL"
          in
          let mc = text_of_message m in
          let truncated = if String.length mc > 80
            then String.sub mc 0 80 ^ "..."
            else mc in
          sprintf "[%s] %s" role_str truncated
        ) old_msgs in
        sprintf "%s\n(Fallback summary of %d earlier messages; reference only.)\n%s"
          memory_summary_prefix (List.length old_msgs) (String.concat "\n" summary_parts)
    in
    let summary_msg = Llm_client.assistant_msg summary in
    let messages = summary_msg :: recent_msgs in
    let token_count = count_tokens ctx.system_prompt messages in
    { ctx with messages; token_count; importance_scores = [] }

(* ================================================================ *)
(* Compaction Pipeline                                              *)
(* ================================================================ *)

let apply_strategy ctx = function
  | PruneToolOutputs -> prune_tool_outputs ctx
  | MergeContiguous -> merge_contiguous ctx
  | DropLowImportance -> drop_low_importance ctx
  | SummarizeOld -> summarize_old ctx

(** Sync working context stats into OAS Context scoped keys.
    Called after compaction so OAS consumers see current state. *)
let sync_oas_context (ctx : working_context) : working_context =
  let oas = ctx.oas_context in
  Agent_sdk.Context.set_scoped oas Agent_sdk.Context.Session
    "message_count" (`Int (List.length ctx.messages));
  Agent_sdk.Context.set_scoped oas Agent_sdk.Context.Session
    "token_count" (`Int ctx.token_count);
  Agent_sdk.Context.set_scoped oas Agent_sdk.Context.Session
    "context_ratio" (`Float (context_ratio ctx));
  ctx

let compact ctx strategies =
  let oas_strategies = List.map (fun (s : compaction_strategy) : Context_compact_oas.strategy -> s) strategies in
  let messages, token_count =
    Context_compact_oas.compact
      ~system_prompt:ctx.system_prompt
      ~messages:ctx.messages
      ~strategies:oas_strategies
  in
  let ctx = { ctx with messages; token_count; importance_scores = [] } in
  sync_oas_context ctx

(* ================================================================ *)
(* Conversation History Offload                                     *)
(* ================================================================ *)

(** Format a single message as human-readable text: "role: content". *)
let format_message_readable (m : Llm_client.message) : string =
  let role_str = match m.role with
    | Llm_client.System -> "system"
    | Llm_client.User -> "user"
    | Llm_client.Assistant -> "assistant"
    | Llm_client.Tool -> "tool"
  in
  let tool_suffix = match m.role with
    | Llm_client.Tool ->
      let tool_id = List.find_map (function
        | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
        | _ -> None) m.content in
      (match tool_id with Some id -> Printf.sprintf " (%s)" id | None -> "")
    | _ -> ""
  in
  sprintf "%s%s: %s" role_str tool_suffix (text_of_message m)

(** Offload messages to a markdown file for later retrieval.
    Returns [Some path] on success, [None] on failure (fail-safe). *)
let offload_messages
    ~(session_dir : string)
    ~(compaction_count : int)
    (messages : Llm_client.message list) : string option =
  try
    let offload_dir = Filename.concat session_dir "offloaded" in
    ensure_dir offload_dir;
    let path = Filename.concat offload_dir
      (sprintf "%d.md" compaction_count) in
    let timestamp =
      let t = Time_compat.now () in
      (* ISO 8601 UTC: manual formatting to avoid external dependency *)
      let open Unix in
      let tm = gmtime t in
      sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
        (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
        tm.tm_hour tm.tm_min tm.tm_sec
    in
    let rendered =
      messages
      |> List.map format_message_readable
      |> String.concat "\n\n"
    in
    let content = sprintf "## Compacted at %s\n\n%s\n\n" timestamp rendered in
    let fd = Unix.openfile path
      [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let _ = Unix.write_substring fd content 0 (String.length content) in ());
    Some path
  with exn ->
    Printf.eprintf "[context_manager] offload_messages failed: %s\n%!"
      (Printexc.to_string exn);
    None

(** Apply compaction with history offload.
    Messages that would be removed by compaction are saved to a markdown file
    before compaction runs. The summary message is annotated with the offload path.
    If offload fails, compaction proceeds normally. *)
let compact_with_offload
    ~(session_ctx : session_context)
    ~(compaction_count : int)
    (ctx : working_context)
    (strategies : compaction_strategy list) : compaction_result =
  (* Capture pre-compaction messages for offload *)
  let pre_messages = ctx.messages in
  let offloaded_path =
    offload_messages
      ~session_dir:session_ctx.session_dir
      ~compaction_count
      pre_messages
  in
  (* Run the compaction pipeline via OAS adapter *)
  let compacted =
    let oas_strategies = List.map (fun (s : compaction_strategy) : Context_compact_oas.strategy -> s) strategies in
    let messages, token_count =
      Context_compact_oas.compact
        ~system_prompt:ctx.system_prompt
        ~messages:ctx.messages
        ~strategies:oas_strategies
    in
    { ctx with messages; token_count; importance_scores = [] }
  in
  (* If offload succeeded and SummarizeOld produced a summary, annotate it *)
  let compacted = match offloaded_path with
    | Some path ->
      let annotation = sprintf "[Full conversation history saved to %s]\n\n" path in
      let messages = List.map (fun (m : Llm_client.message) ->
        let mt = text_of_message m in
        if starts_with ~prefix:memory_summary_prefix mt then
          { m with content = [Agent_sdk.Types.Text (annotation ^ mt)] }
        else m
      ) compacted.messages in
      let token_count = count_tokens compacted.system_prompt messages in
      { compacted with messages; token_count }
    | None -> compacted
  in
  let compacted = sync_oas_context compacted in
  { context = compacted; offloaded_path }

(* ================================================================ *)
(* OAS Context_reducer Integration                                  *)
(* ================================================================ *)

(** Role tag sentinel: uses \x00 prefix to prevent collision with user content.
    No valid UTF-8 user text starts with a null byte. *)
let system_role_tag = "\x00__MASC_ROLE:system__\x00"
let tool_role_tag = "\x00__MASC_ROLE:tool__\x00"

let masc_msg_to_oas_tagged (m : Llm_client.message) : Agent_sdk.Types.message =
  let role, tag = match m.role with
    | Llm_client.System -> Agent_sdk.Types.User, Some system_role_tag
    | Llm_client.Tool -> Agent_sdk.Types.User, Some tool_role_tag
    | Llm_client.User -> Agent_sdk.Types.User, None
    | Llm_client.Assistant -> Agent_sdk.Types.Assistant, None
  in
  let text = match tag with
    | Some t -> t ^ text_of_message m
    | None -> text_of_message m
  in
  let content = match m.role with
    | Llm_client.Tool ->
      let tool_use_id =
        List.find_map (function Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id | _ -> None) m.content
        |> Option.value ~default:"masc-tool"
      in
      [Agent_sdk.Types.ToolResult { tool_use_id; content = text; is_error = false }]
    | _ -> [Agent_sdk.Types.Text text]
  in
  { Agent_sdk.Types.role; content }

let oas_msg_to_masc_tagged (m : Agent_sdk.Types.message) : Llm_client.message =
  (* Extract text and tool_use_id from content blocks *)
  let text, tool_id =
    let parts = List.filter_map (fun (block : Agent_sdk.Types.content_block) ->
      match block with
      | Agent_sdk.Types.Text s -> Some (s, None)
      | Agent_sdk.Types.ToolResult { tool_use_id; content; _ } ->
        Some (content, Some tool_use_id)
      | _ -> None
    ) m.content in
    let texts = List.map fst parts in
    let ids = List.filter_map snd parts in
    (String.concat "\n" texts, List.nth_opt ids 0)
  in
  let role, content =
    if starts_with ~prefix:system_role_tag text then
      Llm_client.System,
      String.sub text (String.length system_role_tag)
        (String.length text - String.length system_role_tag)
    else if starts_with ~prefix:tool_role_tag text then
      Llm_client.Tool,
      String.sub text (String.length tool_role_tag)
        (String.length text - String.length tool_role_tag)
    else
      (match m.role with
       | Agent_sdk.Types.User -> Llm_client.User
       | Agent_sdk.Types.Assistant -> Llm_client.Assistant
       | Agent_sdk.Types.System -> Llm_client.System
       | Agent_sdk.Types.Tool -> Llm_client.Tool),
      text
  in
  let content_blocks = match role with
    | Llm_client.Tool ->
      let tool_use_id = Option.value ~default:"masc-tool" tool_id in
      [Agent_sdk.Types.ToolResult { tool_use_id; content; is_error = false }]
    | _ -> [Agent_sdk.Types.Text content]
  in
  { Agent_sdk.Types.role; content = content_blocks }

let oas_strategy_of_compaction (s : compaction_strategy) : Agent_sdk.Context_reducer.strategy =
  match s with
  | PruneToolOutputs ->
    Agent_sdk.Context_reducer.Prune_tool_outputs { max_output_len = 500 }
  | MergeContiguous ->
    Agent_sdk.Context_reducer.Merge_contiguous
  | DropLowImportance ->
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let masc_msgs = List.map oas_msg_to_masc_tagged oas_msgs in
      let dummy_ctx = {
        system_prompt = ""; messages = masc_msgs;
        token_count = 0; max_tokens = 0;
        importance_scores = []; oas_context = Agent_sdk.Context.create ()
      } in
      let result = drop_low_importance dummy_ctx in
      List.map masc_msg_to_oas_tagged result.messages)
  | SummarizeOld ->
    Agent_sdk.Context_reducer.Custom (fun oas_msgs ->
      let masc_msgs = List.map oas_msg_to_masc_tagged oas_msgs in
      let dummy_ctx = {
        system_prompt = ""; messages = masc_msgs;
        token_count = 0; max_tokens = 0;
        importance_scores = []; oas_context = Agent_sdk.Context.create ()
      } in
      let result = summarize_old dummy_ctx in
      List.map masc_msg_to_oas_tagged result.messages)

let compact_via_oas ctx strategies =
  let oas_strategies = List.map oas_strategy_of_compaction strategies in
  let reducer = Agent_sdk.Context_reducer.compose
    (List.map (fun s -> { Agent_sdk.Context_reducer.strategy = s }) oas_strategies) in
  let oas_msgs = List.map masc_msg_to_oas_tagged ctx.messages in
  let reduced = Agent_sdk.Context_reducer.reduce reducer oas_msgs in
  let messages = List.map oas_msg_to_masc_tagged reduced in
  let token_count = count_tokens ctx.system_prompt messages in
  let ctx = { ctx with messages; token_count; importance_scores = [] } in
  sync_oas_context ctx

(* ================================================================ *)
(* Checkpointing                                                    *)
(* ================================================================ *)

let generate_checkpoint_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  sprintf "ckpt-%d" ts

let role_to_string (r : Llm_client.role) = match r with
  | System -> "system" | User -> "user"
  | Assistant -> "assistant" | Tool -> "tool"

let role_of_string = function
  | "system" -> Llm_client.System | "user" -> Llm_client.User
  | "assistant" -> Llm_client.Assistant | _ -> Llm_client.Tool

let message_to_json (m : Llm_client.message) : Yojson.Safe.t =
  let m = Llm_client.sanitize_message_utf8 m in
  let base = [
    ("role", `String (role_to_string m.role));
    ("content", `String (text_of_message m));
  ] in
  (* Preserve tool_use_id for backward compat with old "tool_call_id" JSON field *)
  let with_tool_id = match m.role with
    | Llm_client.Tool ->
      let tool_id = List.find_map (function
        | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
        | _ -> None) m.content in
      (match tool_id with Some id -> ("tool_call_id", `String id) :: base | None -> base)
    | _ -> base
  in
  `Assoc with_tool_id

let message_of_json (json : Yojson.Safe.t) : Llm_client.message =
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string |> role_of_string in
  let text = json |> member "content" |> to_string |> Llm_client.sanitize_text_utf8 in
  match role with
  | Llm_client.Tool ->
    let tool_use_id = json |> member "tool_call_id" |> to_string_option |> Option.value ~default:"masc-tool" in
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.ToolResult { tool_use_id; content = text; is_error = false }] }
  | _ ->
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.Text text] }

let serialize_context (ctx : working_context) : string =
  let json = `Assoc [
    ("system_prompt", `String (Llm_client.sanitize_text_utf8 ctx.system_prompt));
    ("messages", `List (List.map message_to_json ctx.messages));
    ("token_count", `Int ctx.token_count);
    ("max_tokens", `Int ctx.max_tokens);
  ] in
  Yojson.Safe.to_string json

let deserialize_context (s : string) ~max_tokens : working_context =
  let json = Yojson.Safe.from_string (Llm_client.sanitize_text_utf8 s) in
  let open Yojson.Safe.Util in
  let system_prompt =
    json |> member "system_prompt" |> to_string |> Llm_client.sanitize_text_utf8
  in
  let messages = json |> member "messages" |> to_list |> List.map message_of_json in
  let token_count = json |> member "token_count" |> to_int in
  { system_prompt; messages; token_count; max_tokens; importance_scores = [];
    oas_context = Agent_sdk.Context.create () }

let create_checkpoint ctx ~generation =
  {
    checkpoint_id = generate_checkpoint_id ();
    timestamp = Time_compat.now ();
    generation;
    message_count = List.length ctx.messages;
    token_count = ctx.token_count;
    serialized = serialize_context ctx |> Llm_client.sanitize_text_utf8;
  }

let restore_checkpoint ckpt ~max_tokens =
  deserialize_context ckpt.serialized ~max_tokens

(* ================================================================ *)
(* Session Persistence                                              *)
(* ================================================================ *)

let create_session ~session_id ~base_dir =
  let session_dir = Filename.concat base_dir session_id in
  ensure_dir session_dir;
  { session_id; session_dir; full_history = []; checkpoints = [] }

let persist_message session msg =
  let msg = Llm_client.sanitize_message_utf8 msg in
  session.full_history <- session.full_history @ [msg];
  let path = Filename.concat session.session_dir "history.jsonl" in
  let now_ts = Time_compat.now () in
  let payload =
    match message_to_json msg with
    | `Assoc fields ->
      `Assoc (("timestamp", `Float now_ts) :: ("ts_unix", `Float now_ts) :: fields)
    | j -> j
  in
  let line =
    (Yojson.Safe.to_string payload |> Llm_client.sanitize_text_utf8) ^ "\n"
  in
  Fs_compat.append_file path line

let save_checkpoint session ckpt =
  let ckpt =
    { ckpt with serialized = Llm_client.sanitize_text_utf8 ckpt.serialized }
  in
  session.checkpoints <- session.checkpoints @ [ckpt];
  let path = Filename.concat session.session_dir
    (sprintf "%s.json" ckpt.checkpoint_id) in
  let json = `Assoc [
    ("checkpoint_id", `String ckpt.checkpoint_id);
    ("timestamp", `Float ckpt.timestamp);
    ("generation", `Int ckpt.generation);
    ("message_count", `Int ckpt.message_count);
    ("token_count", `Int ckpt.token_count);
    ("serialized", `String ckpt.serialized);
  ] in
  let content = Yojson.Safe.to_string json |> Llm_client.sanitize_text_utf8 in
  Fs_compat.save_file path content

let load_latest_checkpoint session =
  let dir = session.session_dir in
  if not (Sys.file_exists dir) then None
  else
    let files = Sys.readdir dir |> Array.to_list in
    let ckpt_files = List.filter (fun f ->
      let len = String.length f in
      len > 5 && String.sub f 0 5 = "ckpt-" &&
      String.sub f (len - 5) 5 = ".json"
    ) files in
    match List.sort (fun a b -> compare b a) ckpt_files with
    | [] -> None
    | latest :: _ ->
      let path = Filename.concat dir latest in
      let content = Fs_compat.load_file path in
      let json =
        content
        |> Llm_client.sanitize_text_utf8
        |> Yojson.Safe.from_string
      in
      let open Yojson.Safe.Util in
      Some {
        checkpoint_id = json |> member "checkpoint_id" |> to_string;
        timestamp = json |> member "timestamp" |> to_number;
        generation = json |> member "generation" |> to_int;
        message_count = json |> member "message_count" |> to_int;
        token_count = json |> member "token_count" |> to_int;
        serialized =
          json |> member "serialized" |> to_string |> Llm_client.sanitize_text_utf8;
      }
