(** Context_manager — 3-tier memory with progressive compaction.

    Implements the working memory tier (Tier 1) with in-process
    operations and session persistence (Tier 2) via JSONL files.
    Tier 3 (semantic/pgvector) is accessed externally.

    Compaction is delegated to {!Context_compact_oas} which routes
    through OAS [Context_reducer].

    @since 2.61.0 *)

open Printf

let text_of_message = Agent_sdk.Types.text_of_message

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type working_context = {
  system_prompt : string;
  messages : Agent_sdk.Types.message list;
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
  mutable full_history : Agent_sdk.Types.message list;
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

(* ================================================================ *)
(* Memory Formats                                                  *)
(* ================================================================ *)

let goal_prefix = Context_scoring.goal_prefix

let state_block_start = "[STATE]"
let state_block_end = "[/STATE]"


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
let msg_tokens (m : Agent_sdk.Types.message) =
  (String.length (text_of_message m) / 4) + 4

let count_tokens (system_prompt : string) (msgs : Agent_sdk.Types.message list) =
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
    List.map (fun (m : Agent_sdk.Types.message) ->
      if m.role = Agent_sdk.Types.System then { m with role = Agent_sdk.Types.Assistant } else m
    ) ctx.messages
  in
  let token_count = count_tokens system_prompt messages in
  { ctx with system_prompt; messages; token_count; importance_scores = [] }

let append ctx (msg : Agent_sdk.Types.message) =
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
(* Compaction Pipeline                                              *)
(* ================================================================ *)

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

(* compact removed — callers use Context_compact_oas.compact directly. *)

(* ================================================================ *)
(* Conversation History Offload                                     *)
(* ================================================================ *)

(** Format a single message as human-readable text: "role: content". *)
let format_message_readable (m : Agent_sdk.Types.message) : string =
  let role_str = match m.role with
    | Agent_sdk.Types.System -> "system"
    | Agent_sdk.Types.User -> "user"
    | Agent_sdk.Types.Assistant -> "assistant"
    | Agent_sdk.Types.Tool -> "tool"
  in
  let tool_suffix = match m.role with
    | Agent_sdk.Types.Tool ->
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
    (messages : Agent_sdk.Types.message list) : string option =
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

(* compact_with_offload removed — callers use Context_compact_oas.compact
   + offload_messages separately. *)

(* ================================================================ *)
(* Checkpointing                                                    *)
(* ================================================================ *)

let generate_checkpoint_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  sprintf "ckpt-%d" ts

let role_to_string (r : Agent_sdk.Types.role) = match r with
  | System -> "system" | User -> "user"
  | Assistant -> "assistant" | Tool -> "tool"

let role_of_string = function
  | "system" -> Agent_sdk.Types.System | "user" -> Agent_sdk.Types.User
  | "assistant" -> Agent_sdk.Types.Assistant | _ -> Agent_sdk.Types.Tool

let message_to_json (m : Agent_sdk.Types.message) : Yojson.Safe.t =
  let m = Cascade.sanitize_message_utf8 m in
  let base = [
    ("role", `String (role_to_string m.role));
    ("content", `String (text_of_message m));
  ] in
  (* Preserve tool_use_id for backward compat with old "tool_call_id" JSON field *)
  let with_tool_id = match m.role with
    | Agent_sdk.Types.Tool ->
      let tool_id = List.find_map (function
        | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
        | _ -> None) m.content in
      (match tool_id with Some id -> ("tool_call_id", `String id) :: base | None -> base)
    | _ -> base
  in
  `Assoc with_tool_id

let message_of_json (json : Yojson.Safe.t) : Agent_sdk.Types.message =
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string |> role_of_string in
  let text = json |> member "content" |> to_string |> Cascade.sanitize_text_utf8 in
  match role with
  | Agent_sdk.Types.Tool ->
    let tool_use_id = json |> member "tool_call_id" |> to_string_option |> Option.value ~default:"masc-tool" in
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.ToolResult { tool_use_id; content = text; is_error = false }]; name = None; tool_call_id = None }
  | _ ->
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.Text text]; name = None; tool_call_id = None }

let serialize_context (ctx : working_context) : string =
  let json = `Assoc [
    ("system_prompt", `String (Cascade.sanitize_text_utf8 ctx.system_prompt));
    ("messages", `List (List.map message_to_json ctx.messages));
    ("token_count", `Int ctx.token_count);
    ("max_tokens", `Int ctx.max_tokens);
  ] in
  Yojson.Safe.to_string json

let deserialize_context (s : string) ~max_tokens : working_context =
  let json = Yojson.Safe.from_string (Cascade.sanitize_text_utf8 s) in
  let open Yojson.Safe.Util in
  let system_prompt =
    json |> member "system_prompt" |> to_string |> Cascade.sanitize_text_utf8
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
    serialized = serialize_context ctx |> Cascade.sanitize_text_utf8;
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
  let msg = Cascade.sanitize_message_utf8 msg in
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
    (Yojson.Safe.to_string payload |> Cascade.sanitize_text_utf8) ^ "\n"
  in
  Fs_compat.append_file path line

let save_checkpoint session ckpt =
  let ckpt =
    { ckpt with serialized = Cascade.sanitize_text_utf8 ckpt.serialized }
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
  let content = Yojson.Safe.to_string json |> Cascade.sanitize_text_utf8 in
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
        |> Cascade.sanitize_text_utf8
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
          json |> member "serialized" |> to_string |> Cascade.sanitize_text_utf8;
      }
