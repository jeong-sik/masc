(** Keeper_context_core — shared keeper context utilities: working context,
    checkpoint management, serialization, and OAS checkpoint operations.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are inlined below.

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

open Printf
open Keeper_types

module Message_json = Keeper_context_core_message_json

(* ================================================================ *)
(* Constants                                                         *)
(* ================================================================ *)

(** Default maximum messages to retain in checkpoints (load and save).
    Caps both load-time deserialization and save-time persistence to prevent
    unbounded memory growth.  The context_reducer (keep_last 30) trims
    further during Agent.run, so 120 gives the reducer room to operate.
    Per-keeper override via [compaction_policy.max_checkpoint_messages]. *)
let default_max_checkpoint_messages = 120

(** Hard caps for checkpoint payload hygiene.
    Message-count capping alone is insufficient when a single message
    accumulates hundreds of text blocks or multi-MB synthetic context. *)
let default_max_checkpoint_text_blocks_per_message = 32
let default_max_checkpoint_text_chars_per_message = 16 * 1024
let default_max_checkpoint_content_chars_total = 512 * 1024
let checkpoint_text_cap_marker = "\n[capped]"

(** ToolResult block caps — analogous to text block caps above.
    Without these, a single message with hundreds of ToolResult blocks
    (e.g. 280 blocks × 7K chars = 1.95M chars) passes through the
    sanitizer untouched, causing context window overflow on next load.
    Values aligned with Claude Code: 200K aggregate, per-result 8K. *)
let default_max_checkpoint_tool_result_chars = 8_000
let default_max_checkpoint_tool_results_per_message = 20
let default_max_checkpoint_tool_result_total_chars = 200_000

(* ================================================================ *)
(* Working Context Types (re-exported from Keeper_types)             *)
(* ================================================================ *)

type working_context = Keeper_types.working_context

type checkpoint = Keeper_types.checkpoint

type session_context = Keeper_types.session_context

(* ================================================================ *)
(* Working Context Operations (inlined from Keeper_working_context)  *)
(* ================================================================ *)

let text_of_message = Agent_sdk.Types.text_of_message

let ensure_dir path =
  ignore (Keeper_fs.ensure_dir path)

(** {1 Token Estimation Facade}

    All OAS Context_reducer estimation calls in MASC pass through this
    module.  Other keeper modules must NOT call
    [Agent_sdk.Context_reducer.estimate_*] directly for decision-making.

    @boundary-contract
    - MASC owns: observation (context_ratio for logging, compaction strategy
      selection, dashboard display). Token estimates are read-only signals.
    - OAS owns: authoritative token estimation (CJK-aware, ceil-based),
      context budget enforcement during Agent.run, compaction execution.
    - Neither may: MASC must not add safety buffers on top of OAS estimates
      (removed in #5053); OAS estimates must not be used as exact counts
      for billing or hard limits. *)

(** Estimate token count for a raw string (CJK-aware). *)
let estimate_char_tokens (s : string) : int =
  Agent_sdk.Context_reducer.estimate_char_tokens s

(** CJK-aware token estimate delegated to OAS Context_reducer.
    OAS estimator is already conservative (CJK-aware, ceil-based).
    Prior 15% buffer (#5053) removed — it caused premature compaction
    and masked the OAS estimator's actual accuracy. *)
let msg_tokens (m : Agent_sdk.Types.message) : int =
  Agent_sdk.Context_reducer.estimate_message_tokens m

let count_tokens (system_prompt : string) (msgs : Agent_sdk.Types.message list) =
  let sys_tokens = Agent_sdk.Context_reducer.estimate_char_tokens system_prompt in
  List.fold_left (fun acc m -> acc + msg_tokens m) sys_tokens msgs

let checkpoint_of_context (ctx : working_context) = ctx.checkpoint

let oas_context_of_context (ctx : working_context) = ctx.checkpoint.context

let max_tokens_of_context (ctx : working_context) =
  ctx.max_tokens

let with_max_tokens (ctx : working_context) max_tokens =
  let checkpoint =
    { ctx.checkpoint with max_total_tokens = Some max_tokens }
  in
  { max_tokens; checkpoint }

let system_prompt_of_context (ctx : working_context) =
  Option.value ~default:"" ctx.checkpoint.system_prompt

let messages_of_context (ctx : working_context) =
  ctx.checkpoint.messages

let empty_runtime_checkpoint ~system_prompt ~messages ~max_tokens
    ~(context : Agent_sdk.Context.t) : Agent_sdk.Checkpoint.t =
  {
    Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
    session_id = "";
    agent_name = "";
    model = "";
    system_prompt = Some system_prompt;
    messages;
    usage = Agent_sdk.Types.empty_usage;
    turn_count = 0;
    created_at = Time_compat.now ();
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens = Some max_tokens;
    context;
    mcp_sessions = [];
    working_context = None;
  }

let token_count (ctx : working_context) =
  count_tokens (system_prompt_of_context ctx) (messages_of_context ctx)

let message_count (ctx : working_context) =
  List.length (messages_of_context ctx)

let context_ratio (ctx : working_context) : float =
  let max_tokens = max_tokens_of_context ctx in
  if max_tokens = 0 then 0.0
  else float_of_int (token_count ctx) /. float_of_int max_tokens

let create ~system_prompt ~max_tokens =
  let context = Agent_sdk.Context.create () in
  let checkpoint =
    empty_runtime_checkpoint ~system_prompt ~messages:[] ~max_tokens ~context
  in
  { checkpoint; max_tokens }

let set_system_prompt (ctx : working_context) ~system_prompt =
  let messages =
    List.map
      (fun (m : Agent_sdk.Types.message) ->
        if m.role = Agent_sdk.Types.System
        then { m with role = Agent_sdk.Types.Assistant }
        else m)
      (messages_of_context ctx)
  in
  let checkpoint =
    { ctx.checkpoint with system_prompt = Some system_prompt; messages }
  in
  { ctx with checkpoint }

let append ctx (msg : Agent_sdk.Types.message) =
  let checkpoint =
    { ctx.checkpoint with messages = messages_of_context ctx @ [ msg ] }
  in
  { ctx with checkpoint }

let append_many ctx msgs =
  List.fold_left append ctx msgs

let sync_oas_context (ctx : working_context) : working_context =
  let context = oas_context_of_context ctx in
  let message_count = message_count ctx in
  let token_count = token_count ctx in
  let context_ratio =
    let max_tokens = max_tokens_of_context ctx in
    if max_tokens = 0 then 0.0
    else float_of_int token_count /. float_of_int max_tokens
  in
  Agent_sdk.Context.set_scoped context Agent_sdk.Context.Session
    "message_count" (`Int message_count);
  Agent_sdk.Context.set_scoped context Agent_sdk.Context.Session
    "token_count" (`Int token_count);
  Agent_sdk.Context.set_scoped context Agent_sdk.Context.Session
    "context_ratio" (`Float context_ratio);
  ctx

let generate_checkpoint_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  sprintf "ckpt-%d" ts

let role_to_string = Message_json.role_to_string
let role_of_string_opt = Message_json.role_of_string_opt
let role_of_string = Message_json.role_of_string
let content_blocks_to_json = Message_json.content_blocks_to_json
let content_blocks_of_json = Message_json.content_blocks_of_json
let legacy_content_text_of_json = Message_json.legacy_content_text_of_json
let string_field_opt = Message_json.string_field_opt
let metadata_of_json = Message_json.metadata_of_json
let message_to_json = Message_json.message_to_json
let message_of_json = Message_json.message_of_json
let text_of_history_jsonl_json = Message_json.text_of_history_jsonl_json

(* Tool use/result pair invariants extracted to
   [Keeper_context_tool_message_pairs] (godfile decomp). *)
let tool_use_ids_of_message = Keeper_context_tool_message_pairs.tool_use_ids_of_message
let tool_result_ids_of_message = Keeper_context_tool_message_pairs.tool_result_ids_of_message
let has_tool_result_block = Keeper_context_tool_message_pairs.has_tool_result_block
let trim_messages_preserving_pairs = Keeper_context_tool_message_pairs.trim_messages_preserving_pairs

let tool_result_text_of_block
    ~(tool_use_id : string)
    ~(content : string)
    ~(json : Yojson.Safe.t option) : string =
  let content = Inference_utils.sanitize_text_utf8 (String.trim content) in
  if content <> "" then content
  else
    match json with
    | Some value ->
        (* Stringify json only when it fits the per-result cap. Larger
           payloads collapse to a stub so a single orphan-repair pass
           cannot inflate one Text block to multi-MB and trigger the same
           escape-depth blow-up that motivated the artifact-store work
           (see [tool_blob_store] and the tool-output-washing series). *)
        let serialized = Yojson.Safe.to_string value in
        let len = String.length serialized in
        if len <= default_max_checkpoint_tool_result_chars then serialized
        else
          Printf.sprintf "[tool:json id:%s bytes:%d elided]" tool_use_id len
    | None -> Printf.sprintf "[tool result %s]" tool_use_id

let tool_use_text_of_block
    ~(tool_use_id : string)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t) : string =
  let tool_name = Inference_utils.sanitize_text_utf8 (String.trim tool_name) in
  let tool_use_id = Inference_utils.sanitize_text_utf8 (String.trim tool_use_id) in
  let tool_name =
    if tool_name = "" then "unknown_tool" else tool_name
  in
  let input_json = Yojson.Safe.to_string input |> Inference_utils.sanitize_text_utf8 in
  Printf.sprintf "[tool use %s %s input=%s]" tool_name tool_use_id input_json

type tool_pair_repair_stats =
  { downgraded_tool_uses : int
  ; downgraded_tool_results : int
  }

let empty_tool_pair_repair_stats =
  { downgraded_tool_uses = 0; downgraded_tool_results = 0 }

let add_tool_pair_repair_stats left right =
  { downgraded_tool_uses =
      left.downgraded_tool_uses + right.downgraded_tool_uses
  ; downgraded_tool_results =
      left.downgraded_tool_results + right.downgraded_tool_results
  }

let tool_pair_repair_stats_changed stats =
  stats.downgraded_tool_uses > 0 || stats.downgraded_tool_results > 0

let pair_repair_metadata_key = "masc.tool_pair_repair"

let pair_repair_metadata_keys =
  [ "was_fabricated"; "fabrication_source"; pair_repair_metadata_key ]

let with_pair_repair_metadata ~kind ~count (msg : Agent_sdk.Types.message) =
  let metadata =
    List.filter
      (fun (key, _) -> not (List.mem key pair_repair_metadata_keys))
      msg.metadata
  in
  { msg with
    metadata =
      [ "was_fabricated", `Bool true
      ; "fabrication_source", `String "tool_pair_repair"
      ; ( pair_repair_metadata_key
        , `Assoc
            [ "version", `Int 1
            ; "kind", `String kind
            ; "count", `Int count
            ] )
      ]
      @ metadata
  }

let repair_dangling_tool_use_messages_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let repair_with_next
      (current : Agent_sdk.Types.message)
      (next_opt : Agent_sdk.Types.message option) =
    let next_tool_result_ids =
      match next_opt with
      | Some next -> tool_result_ids_of_message next
      | None -> []
    in
    let has_dangling =
      List.exists
        (function
          | Agent_sdk.Types.ToolUse { id; _ } ->
              not (List.mem id next_tool_result_ids)
          (* Only [ToolUse] blocks can be dangling without a paired ToolResult. *)
          | Agent_sdk.Types.Text _
          | Agent_sdk.Types.Thinking _
          | Agent_sdk.Types.RedactedThinking _
          | Agent_sdk.Types.ToolResult _
          | Agent_sdk.Types.Image _
          | Agent_sdk.Types.Document _
          | Agent_sdk.Types.Audio _ -> false)
        current.content
    in
    if not has_dangling then (current, empty_tool_pair_repair_stats)
    else
      let downgraded_tool_uses = ref 0 in
      let content =
        List.map
          (function
            | Agent_sdk.Types.ToolUse { id; name; input }
              when not (List.mem id next_tool_result_ids) ->
                incr downgraded_tool_uses;
                Agent_sdk.Types.Text
                  (tool_use_text_of_block
                     ~tool_use_id:id ~tool_name:name ~input)
            | other -> other)
          current.content
      in
      ( { current with content }
        |> with_pair_repair_metadata
             ~kind:"downgraded_tool_use"
             ~count:!downgraded_tool_uses
      , { empty_tool_pair_repair_stats with
          downgraded_tool_uses = !downgraded_tool_uses
        } )
  in
  let rec loop acc_stats acc = function
    | [] -> List.rev acc, acc_stats
    | [ current ] ->
        let repaired, repair_stats = repair_with_next current None in
        List.rev (repaired :: acc), add_tool_pair_repair_stats acc_stats repair_stats
    | current :: ((next :: _) as rest) ->
        let repaired, repair_stats = repair_with_next current (Some next) in
        loop (add_tool_pair_repair_stats acc_stats repair_stats) (repaired :: acc) rest
  in
  loop empty_tool_pair_repair_stats [] messages

let repair_dangling_tool_use_messages messages =
  fst (repair_dangling_tool_use_messages_with_stats messages)

let repair_orphan_tool_result_messages_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let rec loop acc_stats prev acc = function
    | [] -> List.rev acc, acc_stats
    | msg :: rest ->
        let repaired, stats =
          if not (has_tool_result_block msg) then
            (msg, empty_tool_pair_repair_stats)
          else
            let prev_tool_use_ids =
              match prev with
              | Some previous -> tool_use_ids_of_message previous
              | None -> []
            in
            (* Anthropic validates ToolResult blocks against ToolUse blocks
               in the immediately previous message. If checkpoint capping
               drops that predecessor, the resumed history becomes invalid.
               Downgrade only the orphaned structured result blocks to
               plain text so the semantic output survives without replaying
               provider-specific tool metadata. *)
            let has_orphan =
              List.exists
                (function
                  | Agent_sdk.Types.ToolResult { tool_use_id; _ } ->
                      not (List.mem tool_use_id prev_tool_use_ids)
                  (* Only [ToolResult] can be orphaned w.r.t. prior ToolUse ids. *)
                  | Agent_sdk.Types.Text _
                  | Agent_sdk.Types.Thinking _
                  | Agent_sdk.Types.RedactedThinking _
                  | Agent_sdk.Types.ToolUse _
                  | Agent_sdk.Types.Image _
                  | Agent_sdk.Types.Document _
                  | Agent_sdk.Types.Audio _ -> false)
                msg.content
            in
            if not has_orphan then (msg, empty_tool_pair_repair_stats)
            else
              let downgraded_tool_results = ref 0 in
              let content =
                List.map
                  (function
                    | Agent_sdk.Types.ToolResult { tool_use_id; content; json; _ } ->
                        incr downgraded_tool_results;
                        Agent_sdk.Types.Text
                          (tool_result_text_of_block ~tool_use_id ~content ~json)
                    | other -> other)
                  msg.content
              in
              ( { msg with content }
                |> with_pair_repair_metadata
                     ~kind:"downgraded_tool_result"
                     ~count:!downgraded_tool_results
              , { empty_tool_pair_repair_stats with
                  downgraded_tool_results = !downgraded_tool_results
                } )
        in
        loop (add_tool_pair_repair_stats acc_stats stats) (Some repaired) (repaired :: acc) rest
  in
  loop empty_tool_pair_repair_stats None [] messages

let repair_orphan_tool_result_messages messages =
  fst (repair_orphan_tool_result_messages_with_stats messages)

let repair_broken_tool_call_pairs_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let messages, dangling_stats = repair_dangling_tool_use_messages_with_stats messages in
  let messages, orphan_stats = repair_orphan_tool_result_messages_with_stats messages in
  messages, add_tool_pair_repair_stats dangling_stats orphan_stats

let repair_broken_tool_call_pairs
    (messages : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  fst (repair_broken_tool_call_pairs_with_stats messages)

let serialize_context (ctx : working_context) : string =
  let json = `Assoc [
    ( "system_prompt",
      `String
        (Inference_utils.sanitize_text_utf8 (system_prompt_of_context ctx)) );
    ("messages", `List (List.map message_to_json (messages_of_context ctx)));
    ("token_count", `Int (token_count ctx));
    ("max_tokens", `Int (max_tokens_of_context ctx));
  ] in
  Yojson.Safe.to_string json

let deserialize_context (s : string) ~max_tokens : working_context =
  let json = Yojson.Safe.from_string s in
  let open Yojson.Safe.Util in
  let system_prompt = json |> member "system_prompt" |> to_string in
  let messages =
    json |> member "messages" |> to_list |> List.map message_of_json
    |> repair_broken_tool_call_pairs
  in
  let _legacy_token_count = json |> member "token_count" |> to_int_option in
  let context = Agent_sdk.Context.create () in
  let checkpoint =
    empty_runtime_checkpoint ~system_prompt ~messages ~max_tokens ~context
  in
  sync_oas_context
    { checkpoint; max_tokens }

let context_to_json (ctx : working_context) : Yojson.Safe.t =
  `Assoc [
    ( "system_prompt",
      `String
        (Inference_utils.sanitize_text_utf8 (system_prompt_of_context ctx)) );
    ("messages", `List (List.map message_to_json (messages_of_context ctx)));
    ("token_count", `Int (token_count ctx));
    ("max_tokens", `Int (max_tokens_of_context ctx));
  ]

let create_checkpoint ctx ~generation =
  {
    checkpoint_id = generate_checkpoint_id ();
    timestamp = Time_compat.now ();
    generation;
    message_count = message_count ctx;
    token_count = token_count ctx;
    serialized = serialize_context ctx;
  }

let restore_checkpoint ckpt ~max_tokens =
  deserialize_context ckpt.serialized ~max_tokens

let create_session ~session_id ~base_dir =
  let session_dir = Filename.concat base_dir session_id in
  ensure_dir session_dir;
  { session_id; session_dir; checkpoints = [] }

include Keeper_context_core_history

(* ================================================================ *)
(* End of inlined Keeper_working_context operations                  *)
(* ================================================================ *)

let timed = Inference_utils.timed
let zero_usage = Inference_utils.zero_usage
let usage_of_response = Inference_utils.usage_of_response
let total_tokens = Inference_utils.total_tokens

(* ================================================================ *)
(* Checkpoint Store Delegation                                        *)
(* ================================================================ *)

let save_session_checkpoint (session : session_context) ckpt =
  session.checkpoints <- session.checkpoints @ [ckpt];
  Keeper_checkpoint_store.save ~session_dir:session.session_dir ckpt

let load_latest_checkpoint (session : session_context) =
  Keeper_checkpoint_store.load_latest ~session_dir:session.session_dir

(* ================================================================ *)
(* Keeper Context Lifecycle                                          *)
(* ================================================================ *)

let log_keeper_exn ~label exn =
  let tag = match exn with
    | Sys_error _ | Failure _ | Not_found
    | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
    | _ -> "[UNEXPECTED] "
  in
  Log.Keeper.info "%s%s: %s" tag label (Printexc.to_string exn)

let checkpoint_generation_key = "keeper_generation"

type checkpoint_sanitize_stats = {
  dropped_messages : int;
  dropped_blocks : int;
  dropped_chars : int;
  truncated_blocks : int;
  truncated_chars : int;
}

let empty_checkpoint_sanitize_stats =
  {
    dropped_messages = 0;
    dropped_blocks = 0;
    dropped_chars = 0;
    truncated_blocks = 0;
    truncated_chars = 0;
  }

let checkpoint_sanitize_changed (stats : checkpoint_sanitize_stats) : bool =
  stats.dropped_messages > 0
  || stats.dropped_blocks > 0
  || stats.dropped_chars > 0
  || stats.truncated_blocks > 0
  || stats.truncated_chars > 0

let add_checkpoint_sanitize_stats
    (a : checkpoint_sanitize_stats)
    (b : checkpoint_sanitize_stats) : checkpoint_sanitize_stats =
  {
    dropped_messages = a.dropped_messages + b.dropped_messages;
    dropped_blocks = a.dropped_blocks + b.dropped_blocks;
    dropped_chars = a.dropped_chars + b.dropped_chars;
    truncated_blocks = a.truncated_blocks + b.truncated_blocks;
    truncated_chars = a.truncated_chars + b.truncated_chars;
  }

let truncate_checkpoint_text ~max_chars (text : string) : string * int =
  let len = String.length text in
  if len <= max_chars then (text, 0)
  else if max_chars <= 0 then ("", len)
  else
    let marker_len = String.length checkpoint_text_cap_marker in
    if max_chars <= marker_len then
      (String.sub checkpoint_text_cap_marker 0 max_chars, len)
    else
      let kept = max_chars - marker_len in
      ( String.sub text 0 kept ^ checkpoint_text_cap_marker,
        len - kept )

let find_substring_from
    ~(haystack : string)
    ~(needle : string)
    ~(start : int) : int option =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 || start < 0 || start >= hay_len || needle_len > hay_len
  then None
  else
    let rec loop idx =
      if idx + needle_len > hay_len then None
      else if String.sub haystack idx needle_len = needle then Some idx
      else loop (idx + 1)
    in
    loop start

let strip_world_state_segments (text : string) : string =
  let needle = "## Current World State" in
  let rec loop current =
    match find_substring_from ~haystack:current ~needle ~start:0 with
    | None -> String.trim current
    | Some idx ->
        let seg_start =
          match String.rindex_from_opt current idx '\n' with
          | Some newline_idx -> newline_idx + 1
          | None -> 0
        in
        let current_len = String.length current in
        let seg_end =
          let rec scan i =
            if i >= current_len - 1 then current_len
            else if current.[i] = '\n' && current.[i + 1] = '[' then i + 1
            else scan (i + 1)
          in
          scan idx
        in
        let before = String.sub current 0 seg_start in
        let after = String.sub current seg_end (current_len - seg_end) in
        let combined =
          if before = "" then after
          else if after = "" then before
          else before ^ "\n" ^ after
        in
        loop combined
  in
  loop text

let is_ephemeral_system_context_text (text : string) : bool =
  let trimmed = String.trim text in
  String.starts_with ~prefix:"[system context]" trimmed

let sanitize_checkpoint_text_block (text : string)
  : string option * checkpoint_sanitize_stats =
  if is_ephemeral_system_context_text text then
    ( None,
      {
        empty_checkpoint_sanitize_stats with
        dropped_blocks = 1;
        dropped_chars = String.length text;
      } )
  else if has_world_state_signature text then
    let stripped = strip_world_state_segments text in
    if stripped = "" then
      ( None,
        {
          empty_checkpoint_sanitize_stats with
          dropped_blocks = 1;
          dropped_chars = String.length text;
        } )
    else if String.equal stripped text then
      (Some text, empty_checkpoint_sanitize_stats)
    else
      ( Some stripped,
        {
          empty_checkpoint_sanitize_stats with
          truncated_blocks = 1;
          truncated_chars = String.length text - String.length stripped;
        } )
  else (Some text, empty_checkpoint_sanitize_stats)

let sanitize_checkpoint_message
    (msg : Agent_sdk.Types.message)
  : Agent_sdk.Types.message option * checkpoint_sanitize_stats =
  let kept_rev, _, _, _, _, stats =
    List.fold_left
      (fun (kept_rev, kept_text_blocks, kept_text_chars,
            kept_tool_results, kept_tool_result_chars, stats) block ->
         match block with
         | Agent_sdk.Types.Text text ->
             let sanitized_text, text_stats =
               sanitize_checkpoint_text_block text
             in
             (match sanitized_text with
              | None ->
                  ( kept_rev,
                    kept_text_blocks,
                    kept_text_chars,
                    kept_tool_results, kept_tool_result_chars,
                    add_checkpoint_sanitize_stats stats text_stats )
              | Some text ->
                  if kept_text_blocks
                     >= default_max_checkpoint_text_blocks_per_message
                  then
                    ( kept_rev,
                      kept_text_blocks,
                      kept_text_chars,
                      kept_tool_results, kept_tool_result_chars,
                      add_checkpoint_sanitize_stats
                        (add_checkpoint_sanitize_stats stats text_stats)
                        {
                          empty_checkpoint_sanitize_stats with
                          dropped_blocks = 1;
                          dropped_chars = String.length text;
                        } )
                  else
                    let remaining =
                      default_max_checkpoint_text_chars_per_message
                      - kept_text_chars
                    in
                    if remaining <= 0 then
                      ( kept_rev,
                        kept_text_blocks,
                        kept_text_chars,
                        kept_tool_results, kept_tool_result_chars,
                        add_checkpoint_sanitize_stats
                          (add_checkpoint_sanitize_stats stats text_stats)
                          {
                            empty_checkpoint_sanitize_stats with
                            dropped_blocks = 1;
                            dropped_chars = String.length text;
                          } )
                    else
                      let capped_text, truncated_chars =
                        truncate_checkpoint_text ~max_chars:remaining text
                      in
                      let block_stats =
                        if truncated_chars > 0 then
                          {
                            empty_checkpoint_sanitize_stats with
                            truncated_blocks = 1;
                            truncated_chars;
                          }
                        else empty_checkpoint_sanitize_stats
                      in
                      ( Agent_sdk.Types.Text capped_text :: kept_rev,
                        kept_text_blocks + 1,
                        kept_text_chars + String.length capped_text,
                        kept_tool_results, kept_tool_result_chars,
                        add_checkpoint_sanitize_stats
                          (add_checkpoint_sanitize_stats stats text_stats)
                          block_stats ))
         | Agent_sdk.Types.Thinking { content; _ } ->
             ( kept_rev,
               kept_text_blocks,
               kept_text_chars,
               kept_tool_results, kept_tool_result_chars,
               add_checkpoint_sanitize_stats stats
                 {
                   empty_checkpoint_sanitize_stats with
                   dropped_blocks = 1;
                   dropped_chars = String.length content;
                 } )
         | Agent_sdk.Types.RedactedThinking text ->
             ( kept_rev,
               kept_text_blocks,
               kept_text_chars,
               kept_tool_results, kept_tool_result_chars,
               add_checkpoint_sanitize_stats stats
                 {
                   empty_checkpoint_sanitize_stats with
                   dropped_blocks = 1;
                   dropped_chars = String.length text;
                 } )
         | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error; _ } ->
             let tool_chars = String.length content in
             if kept_tool_results
                >= default_max_checkpoint_tool_results_per_message
                || kept_tool_result_chars + tool_chars
                   > default_max_checkpoint_tool_result_total_chars
             then
               (* Over count or aggregate byte budget: stub the result.
                  The two triggers are split into separate [reason]
                  labels (and named in [stub_content]) so operators
                  reading the Prometheus rate or inspecting a stubbed
                  checkpoint know which cap to revisit, and so an
                  LLM that later reads the checkpoint can tell that a
                  payload was removed (and why) rather than silently
                  reasoning over the placeholder. *)
               let stub_reason =
                 if kept_tool_results
                    >= default_max_checkpoint_tool_results_per_message
                 then "over_count"
                 else "over_aggregate_bytes"
               in
               let stub_content =
                 Printf.sprintf
                   "[tool result cleared: reason=%s tool_use_id=%s \
                    original_bytes=%d; removed by \
                    Keeper_context_core.sanitize_checkpoint_message \
                    to fit checkpoint budget]"
                   stub_reason
                   tool_use_id
                   tool_chars
               in
               let () =
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_context_tool_result_compacted
                   ~labels:[ "action", "stubbed"; "reason", stub_reason ]
                   ()
               in
               let stub =
                 Agent_sdk.Types.ToolResult
                   { tool_use_id;
                     content = stub_content;
                     is_error;
                     json = None }
               in
               ( stub :: kept_rev,
                 kept_text_blocks, kept_text_chars,
                 kept_tool_results + 1,
                 kept_tool_result_chars + String.length stub_content,
                 add_checkpoint_sanitize_stats stats
                   { empty_checkpoint_sanitize_stats with
                     dropped_blocks = 1;
                     dropped_chars = tool_chars } )
             else if tool_chars > default_max_checkpoint_tool_result_chars
             then
               (* Individual result too large: truncate.  The cap
                  marker already advertises truncation in the content
                  itself; the counter increment is what surfaces the
                  rate to operators without log scraping. *)
               let () =
                 Prometheus.inc_counter
                   Prometheus.metric_keeper_context_tool_result_compacted
                   ~labels:
                     [ "action", "truncated"; "reason", "over_single_byte" ]
                   ()
               in
               let capped =
                 String.sub content 0
                   default_max_checkpoint_tool_result_chars
                 ^ checkpoint_text_cap_marker
               in
               let block =
                 Agent_sdk.Types.ToolResult
                   { tool_use_id; content = capped; is_error; json = None }
               in
               ( block :: kept_rev,
                 kept_text_blocks, kept_text_chars,
                 kept_tool_results + 1,
                 kept_tool_result_chars
                 + default_max_checkpoint_tool_result_chars,
                 add_checkpoint_sanitize_stats stats
                   { empty_checkpoint_sanitize_stats with
                     truncated_blocks = 1;
                     truncated_chars =
                       tool_chars
                       - default_max_checkpoint_tool_result_chars } )
             else
               (* Within budget: keep as-is *)
               ( block :: kept_rev,
                 kept_text_blocks, kept_text_chars,
                 kept_tool_results + 1,
                 kept_tool_result_chars + tool_chars,
                 stats )
         | _ ->
             ( block :: kept_rev,
               kept_text_blocks, kept_text_chars,
               kept_tool_results, kept_tool_result_chars,
               stats ))
      ([], 0, 0, 0, 0, empty_checkpoint_sanitize_stats)
      msg.content
  in
  let kept = List.rev kept_rev in
  if kept = [] then
    ( None,
      add_checkpoint_sanitize_stats stats
        { empty_checkpoint_sanitize_stats with dropped_messages = 1 } )
  else (Some { msg with content = kept }, stats)

let checkpoint_content_chars_of_block = function
  | Agent_sdk.Types.Text text -> String.length text
  | Agent_sdk.Types.Thinking { content; _ } -> String.length content
  | Agent_sdk.Types.RedactedThinking text -> String.length text
  | Agent_sdk.Types.ToolResult { content; _ } -> String.length content
  | _ -> 0

let checkpoint_content_chars_of_message (msg : Agent_sdk.Types.message) : int =
  List.fold_left
    (fun total block -> total + checkpoint_content_chars_of_block block)
    0
    msg.content

let cap_checkpoint_message_to_remaining_content
    ~(remaining : int)
    (msg : Agent_sdk.Types.message)
  : Agent_sdk.Types.message option * int * checkpoint_sanitize_stats =
  let message_chars = checkpoint_content_chars_of_message msg in
  if message_chars = 0 then (Some msg, 0, empty_checkpoint_sanitize_stats)
  else if remaining <= 0 then
    ( None,
      0,
      {
        empty_checkpoint_sanitize_stats with
        dropped_messages = 1;
        dropped_chars = message_chars;
      } )
  else if message_chars <= remaining then
    (Some msg, message_chars, empty_checkpoint_sanitize_stats)
  else
    let remaining_ref = ref remaining in
    let used_ref = ref 0 in
    let kept_rev, stats =
      List.fold_left
        (fun (kept_rev, stats) block ->
           let cap_content rebuild content =
             let len = String.length content in
             if len = 0 then
               (rebuild content :: kept_rev, stats)
             else if !remaining_ref <= 0 then
               ( kept_rev,
                 add_checkpoint_sanitize_stats stats
                   {
                     empty_checkpoint_sanitize_stats with
                     dropped_blocks = 1;
                     dropped_chars = len;
                   } )
             else if len <= !remaining_ref then (
               remaining_ref := !remaining_ref - len;
               used_ref := !used_ref + len;
               (rebuild content :: kept_rev, stats))
             else
               let capped, truncated_chars =
                 truncate_checkpoint_text ~max_chars:!remaining_ref content
               in
               let capped_len = String.length capped in
               remaining_ref := 0;
               used_ref := !used_ref + capped_len;
               ( rebuild capped :: kept_rev,
                 add_checkpoint_sanitize_stats stats
                   {
                     empty_checkpoint_sanitize_stats with
                     truncated_blocks = 1;
                     truncated_chars;
                   } )
           in
           match block with
           | Agent_sdk.Types.Text text ->
               cap_content (fun text -> Agent_sdk.Types.Text text) text
           | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error; _ } ->
               cap_content
                 (fun content ->
                   Agent_sdk.Types.ToolResult
                     { tool_use_id; content; is_error; json = None })
                 content
           | Agent_sdk.Types.Thinking { content; _ } ->
               cap_content (fun text -> Agent_sdk.Types.Text text) content
           | Agent_sdk.Types.RedactedThinking text ->
               cap_content (fun text -> Agent_sdk.Types.Text text) text
           | _ -> (block :: kept_rev, stats))
        ([], empty_checkpoint_sanitize_stats)
        msg.content
    in
    let kept = List.rev kept_rev in
    if kept = [] then
      ( None,
        !used_ref,
        add_checkpoint_sanitize_stats stats
          { empty_checkpoint_sanitize_stats with dropped_messages = 1 } )
    else (Some { msg with content = kept }, !used_ref, stats)

let cap_checkpoint_messages_total_content
    (messages : Agent_sdk.Types.message list)
  : Agent_sdk.Types.message list * checkpoint_sanitize_stats =
  let rec loop kept remaining stats = function
    | [] -> (kept, stats)
    | msg :: older ->
        let sanitized, used, msg_stats =
          cap_checkpoint_message_to_remaining_content ~remaining msg
        in
        let kept =
          match sanitized with
          | Some msg -> msg :: kept
          | None -> kept
        in
        let remaining = max 0 (remaining - used) in
        loop
          kept
          remaining
          (add_checkpoint_sanitize_stats stats msg_stats)
          older
  in
  loop
    []
    default_max_checkpoint_content_chars_total
    empty_checkpoint_sanitize_stats
    (List.rev messages)

let sanitize_checkpoint_messages
    (messages : Agent_sdk.Types.message list)
  : Agent_sdk.Types.message list * checkpoint_sanitize_stats =
  let messages, stats =
    List.fold_right
      (fun msg (acc, stats) ->
         let sanitized_opt, msg_stats = sanitize_checkpoint_message msg in
         let acc =
           match sanitized_opt with
           | Some sanitized -> sanitized :: acc
           | None -> acc
         in
         let stats =
           add_checkpoint_sanitize_stats stats msg_stats
         in
         (acc, stats))
      messages
      ([], empty_checkpoint_sanitize_stats)
  in
  let messages, total_stats = cap_checkpoint_messages_total_content messages in
  (messages, add_checkpoint_sanitize_stats stats total_stats)

let sanitize_oas_checkpoint
    ?(repair_orphans = true)
    (cp : Agent_sdk.Checkpoint.t)
  : Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats =
  let messages, stats = sanitize_checkpoint_messages cp.messages in
  let messages =
    if repair_orphans then repair_broken_tool_call_pairs messages
    else messages
  in
  ({ cp with messages }, stats)

let capped_checkpoint_messages_of_context
      ~(max_checkpoint_messages : int)
      (ctx : working_context)
  : Agent_sdk.Types.message list
  =
  (* Shared by checkpoint persistence and pre-dispatch resume: both paths
     must honor the load-time message cap plus content-size guards. *)
  let original_messages = messages_of_context ctx in
  let capped_messages =
    trim_messages_preserving_pairs original_messages
      ~max_count:max_checkpoint_messages
  in
  let capped_messages_were_truncated =
    List.length capped_messages < List.length original_messages
  in
  let capped_messages =
    Agent_sdk.Context_reducer.reduce
      (Agent_sdk.Context_reducer.stub_tool_results ~keep_recent:1)
      capped_messages
  in
  let capped_messages, sanitize_stats =
    sanitize_checkpoint_messages capped_messages
  in
  if capped_messages_were_truncated || checkpoint_sanitize_changed sanitize_stats
  then repair_broken_tool_call_pairs capped_messages
  else capped_messages

let resume_checkpoint_of_context
      ~(max_checkpoint_messages : int)
      (ctx : working_context) : Agent_sdk.Checkpoint.t
  =
  let checkpoint_context = Agent_sdk.Context.copy (oas_context_of_context ctx) in
  {
    ctx.checkpoint with
    version = Agent_sdk.Checkpoint.checkpoint_version;
    system_prompt = Some (system_prompt_of_context ctx);
    messages = capped_checkpoint_messages_of_context ~max_checkpoint_messages ctx;
    max_total_tokens = Some (max_tokens_of_context ctx);
    context = checkpoint_context;
  }

let checkpoint_max_tokens (cp : Agent_sdk.Checkpoint.t) ~(fallback : int) : int =
  let open Yojson.Safe.Util in
  match cp.max_total_tokens with
  | Some value -> value
  | None -> (
      match cp.working_context with
      | Some (`Assoc _ as sidecar) ->
          sidecar |> member "max_tokens" |> to_int_option
      |> Option.value ~default:fallback
      | _ -> fallback)

let context_of_oas_checkpoint
    ?(repair_orphans = true)
    ~(max_checkpoint_messages : int)
    (cp : Agent_sdk.Checkpoint.t)
    ~(primary_model_max_tokens : int) : working_context =
  let cp, _ = sanitize_oas_checkpoint ~repair_orphans cp in
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let max_tokens =
    checkpoint_max_tokens cp ~fallback:primary_model_max_tokens
  in
  let messages =
    let messages =
      trim_messages_preserving_pairs cp.messages
        ~max_count:max_checkpoint_messages
    in
    if repair_orphans then repair_broken_tool_call_pairs messages
    else messages
  in
  let context = Agent_sdk.Context.copy cp.context in
  let checkpoint =
    { cp with system_prompt = Some system_prompt; messages; context }
  in
  sync_oas_context
    { checkpoint; max_tokens }

let context_of_legacy_checkpoint
    (ckpt : checkpoint)
    ~(primary_model_max_tokens : int) : working_context =
  restore_checkpoint ckpt ~max_tokens:primary_model_max_tokens

let checkpoint_model_of_meta (meta : keeper_meta) =
  let candidates =
    meta.runtime.usage.last_model_used
    :: Keeper_model_labels.configured_model_labels_of_meta meta
  in
  match List.find_opt (fun value -> String.trim value <> "") candidates with
  | Some value -> value
  | None -> Cascade_runtime_candidate.default_local_runtime_label ()

let save_oas_checkpoint
    ~(max_checkpoint_messages : int)
    ~(session : session_context)
    ~(agent_name : string)
    ~(model : string)
    ~(ctx : working_context)
    ~(generation : int)
  : (Agent_sdk.Checkpoint.t, string) result =
  let checkpoint_context = Agent_sdk.Context.copy (oas_context_of_context ctx) in
  Agent_sdk.Context.set_scoped checkpoint_context Agent_sdk.Context.Session
    checkpoint_generation_key (`Int generation);
  let checkpoint =
    {
      ctx.checkpoint with
      version = Agent_sdk.Checkpoint.checkpoint_version;
      session_id = session.session_id;
      agent_name;
      model;
      system_prompt = Some (system_prompt_of_context ctx);
      messages = capped_checkpoint_messages_of_context ~max_checkpoint_messages ctx;
      created_at = Time_compat.now ();
      max_total_tokens = Some (max_tokens_of_context ctx);
      context = checkpoint_context;
    }
  in
  match Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir checkpoint with
  | Ok () -> Ok checkpoint
  | Error e -> Error e

let checkpoint_generation (cp : Agent_sdk.Checkpoint.t) ~(fallback : int) : int =
  let open Yojson.Safe.Util in
  match
    Agent_sdk.Context.get_scoped cp.context Agent_sdk.Context.Session
      checkpoint_generation_key
  with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Option.value ~default:fallback (int_of_string_opt raw)
  | _ -> (
      match cp.working_context with
      | Some (`Assoc _ as sidecar) ->
          sidecar |> member "generation" |> to_int_option
          |> Option.value ~default:fallback
      | _ -> fallback)

let latest_state_snapshot_sidecar_path session =
  Filename.concat session.session_dir "state-snapshot.latest.json"

let state_snapshot_of_sidecar_payload (json : Yojson.Safe.t) =
  try
    let open Yojson.Safe.Util in
    match json |> member "schema_version" |> to_int_option with
    | Some 1 ->
        Keeper_memory_policy.keeper_state_snapshot_of_json
          (json |> member "state_snapshot")
    | _ -> Keeper_memory_policy.snapshot_of_structured_working_context json
  with
  | Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None

let load_latest_state_snapshot_sidecar session =
  let path = latest_state_snapshot_sidecar_path session in
  if not (Fs_compat.file_exists path) then None
  else
    try
      match Yojson.Safe.from_string (Fs_compat.load_file path)
            |> state_snapshot_of_sidecar_payload with
      | Some snapshot -> Some (path, snapshot)
      | None ->
          Log.Keeper.warn
            "keeper:%s state snapshot sidecar malformed: %s"
            session.session_id path;
          None
    with exn ->
      Log.Keeper.warn
        "keeper:%s state snapshot sidecar load failed: %s (%s)"
        session.session_id path (Printexc.to_string exn);
      None

let latest_message_metadata_snapshot messages =
  let rec loop = function
    | [] -> None
    | msg :: rest -> (
        match Keeper_memory_policy.snapshot_of_message_metadata msg with
        | Some _ as snapshot -> snapshot
        | None -> loop rest)
  in
  loop (List.rev messages)

let checkpoint_has_structured_state_snapshot (cp : Agent_sdk.Checkpoint.t) =
  match cp.working_context with
  | Some json
    when Option.is_some
           (Keeper_memory_policy.snapshot_of_structured_working_context json) ->
      true
  | _ -> Option.is_some (latest_message_metadata_snapshot cp.messages)

let hydrate_checkpoint_with_state_snapshot_sidecar session
    (cp : Agent_sdk.Checkpoint.t) =
  if checkpoint_has_structured_state_snapshot cp then cp
  else
    match load_latest_state_snapshot_sidecar session with
    | None -> cp
    | Some (path, snapshot) ->
        let last_assistant_idx = ref (-1) in
        List.iteri
          (fun idx (msg : Agent_sdk.Types.message) ->
            if msg.role = Agent_sdk.Types.Assistant then last_assistant_idx := idx)
          cp.messages;
        if !last_assistant_idx < 0 then cp
        else (
          Log.Keeper.debug
            "keeper:%s hydrating checkpoint continuity from state sidecar: %s"
            session.session_id path;
          let messages =
            List.mapi
              (fun idx msg ->
                if idx = !last_assistant_idx then
                  Keeper_memory_policy.with_snapshot_metadata msg snapshot
                else msg)
              cp.messages
          in
          { cp with messages })

(* ================================================================ *)
(* Checkpoint Loading                                                *)
(* ================================================================ *)

let load_context_from_checkpoint ~max_checkpoint_messages ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let oas_result =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:trace_id
  in
  (* P2 silent-failure fix: previously `Error Not_found | Ok _ -> ()`
     coalesced two semantically distinct outcomes — Not_found means
     "no prior checkpoint, expected on first boot" while Ok means
     "checkpoint loaded successfully."  Splitting the cases lets a
     `debug` log mark when the legacy fallback path is being taken,
     which is the signal an operator wants when investigating "why
     did this restart use defaults instead of the OAS checkpoint?" *)
  (match oas_result with
   | Error (Parse_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_parse))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint parse error: %s" trace_id detail
   | Error (Store_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_store))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint store error: %s" trace_id detail
   | Error (Io_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_io))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint I/O error: %s" trace_id detail
   | Error (Sdk_other_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_sdk))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint SDK error: %s" trace_id detail
   | Error Not_found ->
       Log.Keeper.debug "keeper:%s OAS checkpoint not found, falling back to legacy loader" trace_id
   | Ok _ -> ());
  let oas_checkpoint = match oas_result with
    | Ok v -> Some v
    | Error Not_found -> None
    | Error _ ->
      Log.Keeper.warn "keeper:%s OAS checkpoint error discarded at to_option" trace_id;
      None
  in
  let legacy_checkpoint =
    try load_latest_checkpoint session
    with ex ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_checkpoint_failures
        ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Load_legacy))]
        ();
      Log.Keeper.error "keeper:%s checkpoint load failed: %s" trace_id
        (Printexc.to_string ex);
      None
  in
  let prefer_legacy =
    match oas_checkpoint, legacy_checkpoint with
    | Some oas, Some legacy -> legacy.timestamp > oas.created_at
    | _ -> false
  in
  if prefer_legacy then
       Log.Keeper.info
      "keeper:%s checkpoint migration fallback: legacy newer than OAS"
      trace_id;
  let oas_checkpoint =
    (match oas_result with
     | Ok v -> Some v
     | Error Not_found -> None
     | Error _ ->
       Log.Keeper.warn "keeper:%s OAS checkpoint error discarded at sanitize to_option" trace_id;
       None)
    |> Option.map (fun checkpoint ->
      let sanitized, stats = sanitize_oas_checkpoint checkpoint in
      if checkpoint_sanitize_changed stats then begin
        Log.Keeper.info
          "keeper:%s checkpoint migration sanitized messages: dropped_blocks=%d dropped_messages=%d dropped_chars=%d truncated_blocks=%d truncated_chars=%d"
          trace_id
          stats.dropped_blocks
          stats.dropped_messages
          stats.dropped_chars
          stats.truncated_blocks
          stats.truncated_chars;
        (match Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir sanitized with
         | Ok () -> ()
         | Error detail ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_checkpoint_failures
               ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Migration_save))]
               ();
             Log.Keeper.error
               "keeper:%s checkpoint migration save failed: %s"
               trace_id detail)
      end;
      sanitized)
    |> Option.map (hydrate_checkpoint_with_state_snapshot_sidecar session)
  in
  match (prefer_legacy, oas_checkpoint, legacy_checkpoint) with
  | (false, Some checkpoint, _) ->
      let ctx =
        context_of_oas_checkpoint ~max_checkpoint_messages checkpoint ~primary_model_max_tokens
      in
      let ctx =
        if primary_model_max_tokens <= 0 then ctx
        else sync_oas_context { ctx with max_tokens = primary_model_max_tokens }
      in
      (session, Some ctx)
  | (_, _, Some ckpt) ->
      (try
         let ctx =
           context_of_legacy_checkpoint ckpt ~primary_model_max_tokens
         in
         (session, Some ctx)
       with ex ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_checkpoint_failures
           ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Restore_legacy))]
           ();
         Log.Keeper.error "keeper:%s checkpoint restore failed: %s"
           trace_id (Printexc.to_string ex);
         (session, None))
  | _ ->
      (* Both OAS and legacy checkpoints unavailable.
         Non-trivial OAS errors were already logged above at error level. *)
      (session, None)

(** Patch an OAS checkpoint: unify session_id and replace the last
    assistant message's text content with [response_text] and attach the
    structured replay snapshot in message metadata. New writes keep the
    checkpoint [working_context] empty; readers fall back to legacy
    [working_context]/[STATE] paths for older checkpoints. *)
let patch_checkpoint_last_assistant
    ?snapshot
    (cp : Agent_sdk.Checkpoint.t) ~session_id ~response_text
  : Agent_sdk.Checkpoint.t =
  let snapshot =
    match snapshot with
    | Some snapshot -> Some snapshot
    | None -> Keeper_memory_policy.parse_state_snapshot_from_reply response_text
  in
  let visible_response_text =
    match snapshot with
    | Some _ -> Keeper_text_processing.strip_state_blocks_text response_text
    | None -> response_text
  in
  (* Find index of last assistant message. *)
  let last_asst_idx = ref (-1) in
  List.iteri
    (fun i (msg : Agent_sdk.Types.message) ->
      if msg.role = Agent_sdk.Types.Assistant then last_asst_idx := i)
    cp.messages;
  let messages =
    if !last_asst_idx < 0 then cp.messages
    else
      List.mapi
        (fun i msg ->
          if i = !last_asst_idx then
            let metadata =
              match snapshot with
              | Some snapshot ->
                  [
                    ( Keeper_memory_policy.replay_metadata_key,
                      Keeper_memory_policy.replay_metadata_of_snapshot
                        snapshot );
                  ]
              | None -> []
            in
            Agent_sdk.Types.make_message
              ~role:Agent_sdk.Types.Assistant
              ~metadata
              [ Agent_sdk.Types.Text visible_response_text ]
          else msg)
        cp.messages
  in
  let sanitized_messages, _ = sanitize_checkpoint_messages messages in
  { cp with Agent_sdk.Checkpoint.session_id;
            messages = sanitized_messages;
            working_context = None }

let save_checkpoint session (ctx : working_context) ~generation =
  let ckpt = create_checkpoint ctx ~generation in
  save_session_checkpoint session ckpt;
  ckpt
