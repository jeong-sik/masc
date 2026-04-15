(** Keeper_context_core — shared keeper context utilities: working context,
    checkpoint management, serialization, and OAS checkpoint operations.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are inlined below.

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

open Printf
open Keeper_types

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

let token_count (ctx : working_context) =
  count_tokens ctx.system_prompt ctx.messages

let message_count (ctx : working_context) =
  List.length ctx.messages

let context_ratio (ctx : working_context) : float =
  if ctx.max_tokens = 0 then 0.0
  else float_of_int (token_count ctx) /. float_of_int ctx.max_tokens

let create ~system_prompt ~max_tokens =
  let context = Agent_sdk.Context.create () in
  { system_prompt; messages = []; max_tokens; context }

let set_system_prompt (ctx : working_context) ~system_prompt =
  let messages =
    List.map (fun (m : Agent_sdk.Types.message) ->
      if m.role = Agent_sdk.Types.System then { m with role = Agent_sdk.Types.Assistant } else m
    ) ctx.messages
  in
  { ctx with system_prompt; messages }

let append ctx (msg : Agent_sdk.Types.message) =
  { ctx with messages = ctx.messages @ [msg] }

let append_many ctx msgs =
  List.fold_left append ctx msgs

let sync_oas_context (ctx : working_context) : working_context =
  let context = ctx.context in
  let message_count = message_count ctx in
  let token_count = token_count ctx in
  let context_ratio =
    if ctx.max_tokens = 0 then 0.0
    else float_of_int token_count /. float_of_int ctx.max_tokens
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

let role_to_string (r : Agent_sdk.Types.role) = match r with
  | System -> "system" | User -> "user"
  | Assistant -> "assistant" | Tool -> "tool"

let role_of_string = function
  | "system" -> Agent_sdk.Types.System | "user" -> Agent_sdk.Types.User
  | "assistant" -> Agent_sdk.Types.Assistant | "tool" -> Agent_sdk.Types.Tool
  | unknown ->
    Log.Misc.warn "keeper_context_core: unknown role %S, defaulting to User" unknown;
    Agent_sdk.Types.User

let content_blocks_to_json
    (blocks : Agent_sdk.Types.content_block list) : Yojson.Safe.t =
  `List (List.map Agent_sdk.Api.content_block_to_json blocks)

let content_blocks_of_json
    (json : Yojson.Safe.t) : Agent_sdk.Types.content_block list option =
  let open Yojson.Safe.Util in
  match json |> member "content_blocks" with
  | `List blocks ->
      let parsed =
        List.filter_map Agent_sdk.Api.content_block_of_json blocks
      in
      if List.length parsed = List.length blocks then Some parsed else None
  | _ -> None

let string_field_opt key value =
  match value with
  | Some text -> [ (key, `String text) ]
  | None -> []

let message_to_json (m : Agent_sdk.Types.message) : Yojson.Safe.t =
  let m = Inference_utils.sanitize_message_utf8 m in
  let tool_call_id =
    match m.tool_call_id with
    | Some _ as explicit -> explicit
    | None ->
        (match m.role with
         | Agent_sdk.Types.Tool ->
             List.find_map
               (function
                 | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
                 | _ -> None)
               m.content
         | _ -> None)
  in
  let base = [
    ("role", `String (role_to_string m.role));
    ("content", `String (text_of_message m));
    ("content_blocks", content_blocks_to_json m.content);
  ] in
  `Assoc
    (base
     @ string_field_opt "name" m.name
     @ string_field_opt "tool_call_id" tool_call_id)

let message_of_json (json : Yojson.Safe.t) : Agent_sdk.Types.message =
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string |> role_of_string in
  let text =
    match json |> member "content" |> to_string_option with
    | Some value -> Inference_utils.sanitize_text_utf8 value
    | None -> ""
  in
  let content =
    match content_blocks_of_json json with
    | Some blocks ->
        if blocks <> [] then blocks else
        (* Legacy checkpoints stored only flattened text + role. For Tool
           messages that means the original assistant ToolUse block is gone,
           so rebuilding a structured ToolResult here creates an invalid
           orphaned pair on the next Anthropic request. Fall back to plain
           text so old checkpoints remain readable without breaking turns. *)
        [ Agent_sdk.Types.Text text ]
    | None ->
        [ Agent_sdk.Types.Text text ]
  in
  Inference_utils.sanitize_message_utf8
    {
      Agent_sdk.Types.role;
      content;
      name =
        (json |> member "name" |> to_string_option
         |> Option.map Inference_utils.sanitize_text_utf8);
      tool_call_id =
        (json |> member "tool_call_id" |> to_string_option
         |> Option.map Inference_utils.sanitize_text_utf8);
    }

let tool_use_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  List.filter_map
    (function
      | Agent_sdk.Types.ToolUse { id; _ } -> Some id
      | _ -> None)
    msg.content

let has_tool_result_block (msg : Agent_sdk.Types.message) : bool =
  List.exists
    (function
      | Agent_sdk.Types.ToolResult _ -> true
      | _ -> false)
    msg.content

let tool_result_text_of_block
    ~(tool_use_id : string)
    ~(content : string)
    ~(json : Yojson.Safe.t option) : string =
  let content = Inference_utils.sanitize_text_utf8 (String.trim content) in
  if content <> "" then content
  else
    match json with
    | Some value -> Yojson.Safe.to_string value
    | None -> Printf.sprintf "[tool result %s]" tool_use_id

let repair_orphan_tool_result_messages
    (messages : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  let rec loop prev acc = function
    | [] -> List.rev acc
    | msg :: rest ->
        let repaired =
          if not (has_tool_result_block msg) then msg
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
                  | _ -> false)
                msg.content
            in
            if not has_orphan then msg
            else
              let content =
                List.map
                  (function
                    | Agent_sdk.Types.ToolResult { tool_use_id; content; json; _ } ->
                        Agent_sdk.Types.Text
                          (tool_result_text_of_block ~tool_use_id ~content ~json)
                    | other -> other)
                  msg.content
              in
              { msg with content }
        in
        loop (Some repaired) (repaired :: acc) rest
  in
  loop None [] messages

let serialize_context (ctx : working_context) : string =
  let json = `Assoc [
    ("system_prompt", `String (Inference_utils.sanitize_text_utf8 ctx.system_prompt));
    ("messages", `List (List.map message_to_json ctx.messages));
    ("token_count", `Int (token_count ctx));
    ("max_tokens", `Int ctx.max_tokens);
  ] in
  Yojson.Safe.to_string json

let deserialize_context (s : string) ~max_tokens : working_context =
  let json = Yojson.Safe.from_string s in
  let open Yojson.Safe.Util in
  let system_prompt = json |> member "system_prompt" |> to_string in
  let messages =
    json |> member "messages" |> to_list |> List.map message_of_json
    |> repair_orphan_tool_result_messages
  in
  let _legacy_token_count = json |> member "token_count" |> to_int_option in
  sync_oas_context
    {
      system_prompt;
      messages;
      max_tokens;
      context = Agent_sdk.Context.create ();
    }

let context_to_json (ctx : working_context) : Yojson.Safe.t =
  `Assoc [
    ("system_prompt", `String (Inference_utils.sanitize_text_utf8 ctx.system_prompt));
    ("messages", `List (List.map message_to_json ctx.messages));
    ("token_count", `Int (token_count ctx));
    ("max_tokens", `Int ctx.max_tokens);
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

type history_migration_stats = {
  moved_lines : int;
  dropped_lines : int;
  kept_lines : int;
  malformed_lines : int;
}

let empty_history_migration_stats =
  { moved_lines = 0; dropped_lines = 0; kept_lines = 0; malformed_lines = 0 }

let split_jsonl_lines (content : string) : string list =
  content
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

let normalize_system_context_prefix (text : string) : string =
  let trimmed = String.trim text in
  let prefix = "[system context]" in
  if String.starts_with ~prefix trimmed then
    let prefix_len = String.length prefix in
    let rest_len = String.length trimmed - prefix_len in
    if rest_len <= 0 then ""
    else String.trim (String.sub trimmed prefix_len rest_len)
  else trimmed

let has_world_state_signature (text : string) : bool =
  let trimmed = normalize_system_context_prefix text in
  String_util.contains_substring_ci trimmed "## Current World State"
  &&
  (String_util.contains_substring_ci trimmed "### Namespace State"
   || String_util.contains_substring_ci trimmed "### Available Tools"
   || String_util.contains_substring_ci trimmed "### Continuity")

type history_line_action =
  | Keep_main
  | Move_internal
  | Drop_line

let classify_history_entry ~(source : string) ~(content : string) :
    history_line_action =
  if Keeper_types.is_prompt_history_source source
     || has_world_state_signature content
  then Drop_line
  else if Keeper_types.is_internal_history_source source then
    Move_internal
  else Keep_main

let classify_history_jsonl_line (line : string) : history_line_action option =
  try
    let json = Yojson.Safe.from_string line in
    let source =
      Yojson.Safe.Util.(json |> member "source" |> to_string_option)
      |> Option.value ~default:""
      |> String.trim
    in
    let content =
      Yojson.Safe.Util.(json |> member "content" |> to_string_option)
      |> Option.value ~default:""
      |> String.trim
    in
    Some (classify_history_entry ~source ~content)
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None

let render_jsonl_lines (lines : string list) : string =
  match lines with
  | [] -> ""
  | _ -> String.concat "\n" lines ^ "\n"

let dedupe_preserve_order (lines : string list) : string list =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create (List.length lines) in
  List.filter
    (fun line ->
       if Hashtbl.mem seen line then false
       else (
         Hashtbl.add seen line ();
         true))
    lines

let migrate_session_history_logs
    ~(session_dir : string) : history_migration_stats =
  let main_path = Filename.concat session_dir "history.jsonl" in
  let internal_path = Filename.concat session_dir "history.internal.jsonl" in
  if not (Fs_compat.file_exists main_path) && not (Fs_compat.file_exists internal_path) then
    empty_history_migration_stats
  else
    let main_lines =
      if Fs_compat.file_exists main_path then
        split_jsonl_lines (Fs_compat.load_file main_path)
      else []
    in
    let existing_internal =
      if Fs_compat.file_exists internal_path then
        split_jsonl_lines (Fs_compat.load_file internal_path)
      else []
    in
    let kept_rev, moved_rev, dropped_main, malformed_main =
      List.fold_left
        (fun (kept_rev, moved_rev, dropped_lines, malformed_lines) line ->
           match classify_history_jsonl_line line with
           | Some Keep_main ->
               (line :: kept_rev, moved_rev, dropped_lines, malformed_lines)
           | Some Move_internal ->
               (kept_rev, line :: moved_rev, dropped_lines, malformed_lines)
           | Some Drop_line ->
               (kept_rev, moved_rev, dropped_lines + 1, malformed_lines)
           | None ->
               (line :: kept_rev, moved_rev, dropped_lines, malformed_lines + 1))
        ([], [], 0, 0)
        main_lines
    in
    let kept_lines = List.rev kept_rev in
    let moved_lines = List.rev moved_rev in
    let internal_kept_rev, dropped_internal, malformed_internal =
      List.fold_left
        (fun (kept_rev, dropped_lines, malformed_lines) line ->
           match classify_history_jsonl_line line with
           | Some Drop_line -> (kept_rev, dropped_lines + 1, malformed_lines)
           | Some _ -> (line :: kept_rev, dropped_lines, malformed_lines)
           | None -> (line :: kept_rev, dropped_lines, malformed_lines + 1))
        ([], 0, 0)
        existing_internal
    in
    let sanitized_internal = List.rev internal_kept_rev in
    let total_dropped = dropped_main + dropped_internal in
    let malformed_lines = malformed_main + malformed_internal in
    if moved_lines = [] && total_dropped = 0 then
      {
        moved_lines = 0;
        dropped_lines = 0;
        kept_lines = List.length kept_lines;
        malformed_lines;
      }
    else
      let merged_internal =
        dedupe_preserve_order (sanitized_internal @ moved_lines)
      in
      (match Fs_compat.save_file_atomic main_path (render_jsonl_lines kept_lines) with
       | Ok () -> ()
       | Error detail ->
           raise (Failure (Printf.sprintf "save main history failed: %s" detail)));
      (match
         Fs_compat.save_file_atomic internal_path
           (render_jsonl_lines merged_internal)
       with
       | Ok () -> ()
       | Error detail ->
           raise (Failure
                    (Printf.sprintf "save internal history failed: %s" detail)));
      {
        moved_lines = List.length moved_lines;
        dropped_lines = total_dropped;
        kept_lines = List.length kept_lines;
        malformed_lines;
      }

let history_path_for_source
    ~(session_dir : string)
    ~(source : string option) : string =
  match source with
  | Some source when Keeper_types.is_internal_history_source source ->
      Filename.concat session_dir "history.internal.jsonl"
  | _ ->
      Filename.concat session_dir "history.jsonl"

let persist_message ?source session msg =
  let msg = Inference_utils.sanitize_message_utf8 msg in
  let source_text =
    source |> Option.value ~default:"" |> String.trim
  in
  let content_text =
    msg.content
    |> List.filter_map (function
         | Agent_sdk.Types.Text text -> Some text
         | _ -> None)
    |> String.concat "\n"
  in
  if classify_history_entry ~source:source_text ~content:content_text = Drop_line then
    ()
  else
    let path = history_path_for_source ~session_dir:session.session_dir ~source in
    let now_ts = Time_compat.now () in
    let payload =
      match message_to_json msg with
      | `Assoc fields ->
        let fields =
          match source with
          | Some source when String.trim source <> "" ->
              ("source", `String source) :: fields
          | _ -> fields
        in
        `Assoc
          (("timestamp", `Float now_ts) :: ("ts_unix", `Float now_ts) :: fields)
      | j -> j
    in
    let line = Yojson.Safe.to_string payload ^ "\n" in
    Fs_compat.append_file path line

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
               (* Over count or aggregate budget: stub the result *)
               let stub_content = "[tool result cleared]" in
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
               (* Individual result too large: truncate *)
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

let sanitize_checkpoint_messages
    (messages : Agent_sdk.Types.message list)
  : Agent_sdk.Types.message list * checkpoint_sanitize_stats =
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

let sanitize_oas_checkpoint
    (cp : Agent_sdk.Checkpoint.t)
  : Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats =
  let messages, stats = sanitize_checkpoint_messages cp.messages in
  ({ cp with messages = repair_orphan_tool_result_messages messages }, stats)

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
    ~(max_checkpoint_messages : int)
    (cp : Agent_sdk.Checkpoint.t)
    ~(primary_model_max_tokens : int) : working_context =
  let cp, _ = sanitize_oas_checkpoint cp in
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let max_tokens =
    checkpoint_max_tokens cp ~fallback:primary_model_max_tokens
  in
  let messages =
    let n = List.length cp.messages in
    if n <= max_checkpoint_messages then cp.messages
    else
      let drop = n - max_checkpoint_messages in
      List.filteri (fun i _ -> i >= drop) cp.messages
    |> repair_orphan_tool_result_messages
  in
  sync_oas_context
    {
      system_prompt;
      messages;
      max_tokens;
      context = Agent_sdk.Context.copy cp.context;
    }

let context_of_legacy_checkpoint
    (ckpt : checkpoint)
    ~(primary_model_max_tokens : int) : working_context =
  restore_checkpoint ckpt ~max_tokens:primary_model_max_tokens

let checkpoint_model_of_meta (meta : keeper_meta) =
  let candidates =
    meta.runtime.usage.last_model_used
    :: Keeper_model_labels.configured_model_labels_of_meta meta
  in
  List.find_opt (fun value -> String.trim value <> "") candidates
  |> Option.value ~default:(Provider_adapter.default_local_fallback_label ())

let save_oas_checkpoint
    ~(max_checkpoint_messages : int)
    ~(session : session_context)
    ~(agent_name : string)
    ~(model : string)
    ~(ctx : working_context)
    ~(generation : int)
  : (Agent_sdk.Checkpoint.t, string) result =
  let checkpoint_context = Agent_sdk.Context.copy ctx.context in
  Agent_sdk.Context.set_scoped checkpoint_context Agent_sdk.Context.Session
    checkpoint_generation_key (`Int generation);
  (* Truncate messages at save time to match the load-time cap.
     Without this, checkpoints grow unbounded between compaction cycles,
     causing multi-GB transient allocations when loaded by concurrent keepers. *)
  let capped_messages =
    let n = List.length ctx.messages in
    if n <= max_checkpoint_messages then ctx.messages
    else
      let drop = n - max_checkpoint_messages in
      List.filteri (fun i _ -> i >= drop) ctx.messages
  in
  (* Stub old tool results at save time: keep only the most recent turn's
     results in full. During Agent.run the reducer uses keep_recent:3, but
     at checkpoint persistence we are more aggressive — older tool results
     are unlikely to be useful on resume and bloat disk/memory. *)
  let capped_messages =
    Agent_sdk.Context_reducer.reduce
      (Agent_sdk.Context_reducer.stub_tool_results ~keep_recent:1)
      capped_messages
  in
  let capped_messages, _ = sanitize_checkpoint_messages capped_messages in
  let capped_messages =
    repair_orphan_tool_result_messages capped_messages
  in
  let state =
    {
      Agent_sdk.Types.config =
        {
          Agent_sdk.Types.default_config with
          name = agent_name;
          model;
          system_prompt = Some ctx.system_prompt;
          max_total_tokens = Some ctx.max_tokens;
        };
      messages = capped_messages;
      turn_count = 0;
      usage = Agent_sdk.Types.empty_usage;
    }
  in
  let checkpoint =
    Agent_sdk.Agent_checkpoint.build_checkpoint
      ~session_id:session.session_id
      ~state
      ~tools:Agent_sdk.Tool_set.empty
      ~context:checkpoint_context
      ~mcp_clients:[]
      ()
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

(* ================================================================ *)
(* Checkpoint Loading                                                *)
(* ================================================================ *)

let load_context_from_checkpoint ~max_checkpoint_messages ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let oas_result =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:trace_id
  in
  (* Log non-trivial load errors (Not_found is normal on first boot) *)
  (match oas_result with
   | Error (Parse_error detail) ->
       Log.Keeper.error "keeper:%s OAS checkpoint parse error: %s" trace_id detail
   | Error (Store_error detail) ->
       Log.Keeper.error "keeper:%s OAS checkpoint store error: %s" trace_id detail
   | Error (Io_error detail) ->
       Log.Keeper.error "keeper:%s OAS checkpoint I/O error: %s" trace_id detail
   | Error Not_found | Ok _ -> ());
  let oas_checkpoint = Result.to_option oas_result in
  let legacy_checkpoint =
    try load_latest_checkpoint session
    with ex ->
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
    Result.to_option oas_result
    |> Option.map (fun checkpoint ->
      let sanitized, stats = sanitize_oas_checkpoint checkpoint in
      if checkpoint_sanitize_changed stats then begin
        let has_data_loss =
          stats.dropped_blocks > 0
          || stats.dropped_messages > 0
          || stats.dropped_chars > 0
        in
        (if has_data_loss then
           Log.Keeper.warn
         else
           Log.Keeper.debug)
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
             Log.Keeper.error
               "keeper:%s checkpoint migration save failed: %s"
               trace_id detail)
      end;
      sanitized)
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
         Log.Keeper.error "keeper:%s checkpoint restore failed: %s"
           trace_id (Printexc.to_string ex);
         (session, None))
  | _ ->
      (* Both OAS and legacy checkpoints unavailable.
         Non-trivial OAS errors were already logged above at error level. *)
      (session, None)

(** Feature flag: when true, store structured JSON in
    [Checkpoint.working_context] alongside the text [STATE] block.
    Default false — existing behavior preserved. RFC-MASC-001 Phase 1. *)
let structured_state_enabled () =
  match Sys.getenv_opt "MASC_STRUCTURED_STATE" with
  | Some ("true" | "1" | "yes") -> true
  | _ -> false

(** Patch an OAS checkpoint: unify session_id and replace the last
    assistant message's text content with [response_text] (which includes
    MASC's [STATE] synthesis).  This ensures read_continuity_summary can
    find the [STATE] block in checkpoint messages on the next turn.  #5431

    When [MASC_STRUCTURED_STATE=true], also stores the parsed state
    snapshot as structured JSON in [Checkpoint.working_context].
    RFC-MASC-001 Phase 1: dual-write (text + structured). *)
let patch_checkpoint_last_assistant
    (cp : Agent_sdk.Checkpoint.t) ~session_id ~response_text
  : Agent_sdk.Checkpoint.t =
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
            Agent_sdk.Types.assistant_msg response_text
          else msg)
        cp.messages
  in
  let sanitized_messages, _ = sanitize_checkpoint_messages messages in
  (* RFC-MASC-001 Phase 1: when structured state is enabled, parse the
     [STATE] block from response_text and store as structured JSON in
     Checkpoint.working_context.  This runs alongside the existing text
     path — dual-write for safe migration. *)
  let working_context =
    if structured_state_enabled () then
      match Keeper_memory_policy.parse_state_snapshot_from_reply response_text with
      | Some snapshot ->
        Some (Keeper_memory_policy.structured_working_context_of_snapshot snapshot)
      | None -> cp.working_context
    else cp.working_context
  in
  { cp with Agent_sdk.Checkpoint.session_id;
            messages = sanitized_messages;
            working_context }

let save_checkpoint session (ctx : working_context) ~generation =
  let ckpt = create_checkpoint ctx ~generation in
  save_session_checkpoint session ckpt;
  ckpt
