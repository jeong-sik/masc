(** Keeper_working_context — Working context type and pure operations.

    Contains the [working_context] record type and basic operations
    (create, append, context_ratio, serialization, checkpoint creation)
    and session persistence (create_session, persist_message) with no
    keeper-specific dependencies.

    Checkpoint file I/O (save, load, prune) lives in
    {!Keeper_checkpoint_store}.

    This module exists to break the dependency cycle: modules like
    Keeper_alerting_path and Keeper_exec_tools need the working_context
    type, but Keeper_exec_context depends on those modules.

    @since context-manager-cleanup *)

open Printf

let text_of_message = Agent_sdk.Types.text_of_message

(* ================================================================ *)
(* Working Context Types                                             *)
(* ================================================================ *)

type working_context = {
  system_prompt : string;
  messages : Agent_sdk.Types.message list;
  max_tokens : int;
  context : Agent_sdk.Context.t;
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
  mutable checkpoints : checkpoint list;
}

(* ================================================================ *)
(* Memory Formats                                                    *)
(* ================================================================ *)

(* ================================================================ *)
(* Filesystem Utilities                                              *)
(* ================================================================ *)

let ensure_dir path =
  ignore (Keeper_fs.ensure_dir path)

(* ================================================================ *)
(* Token Estimation                                                  *)
(* ================================================================ *)

(** CJK-aware token estimate delegated to OAS Context_reducer. *)
let msg_tokens : Agent_sdk.Types.message -> int =
  Agent_sdk.Context_reducer.estimate_message_tokens

let count_tokens (system_prompt : string) (msgs : Agent_sdk.Types.message list) =
  let sys_tokens = Agent_sdk.Context_reducer.estimate_char_tokens system_prompt in
  List.fold_left (fun acc m -> acc + msg_tokens m) sys_tokens msgs

let token_count (ctx : working_context) =
  count_tokens ctx.system_prompt ctx.messages

let message_count (ctx : working_context) =
  List.length ctx.messages

(* ================================================================ *)
(* Context Ratio                                                     *)
(* ================================================================ *)

let context_ratio (ctx : working_context) : float =
  if ctx.max_tokens = 0 then 0.0
  else float_of_int (token_count ctx) /. float_of_int ctx.max_tokens

let exceeds_threshold ctx threshold =
  context_ratio ctx >= threshold

(* ================================================================ *)
(* Working Context Operations                                        *)
(* ================================================================ *)

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
  { ctx with
    messages = ctx.messages @ [msg];
  }

let append_many ctx msgs =
  List.fold_left append ctx msgs

(* ================================================================ *)
(* OAS Context Sync                                                  *)
(* ================================================================ *)

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

(* ================================================================ *)
(* Checkpointing                                                     *)
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
  let m = Inference_utils.sanitize_message_utf8 m in
  let base = [
    ("role", `String (role_to_string m.role));
    ("content", `String (text_of_message m));
  ] in
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
  let text = json |> member "content" |> to_string |> Inference_utils.sanitize_text_utf8 in
  match role with
  | Agent_sdk.Types.Tool ->
    let tool_use_id = json |> member "tool_call_id" |> to_string_option |> Option.value ~default:"masc-tool" in
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.ToolResult { tool_use_id; content = text; is_error = false }]; name = None; tool_call_id = None }
  | _ ->
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.Text text]; name = None; tool_call_id = None }

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
  let messages = json |> member "messages" |> to_list |> List.map message_of_json in
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

(* ================================================================ *)
(* Session Persistence                                               *)
(* ================================================================ *)

let create_session ~session_id ~base_dir =
  let session_dir = Filename.concat base_dir session_id in
  ensure_dir session_dir;
  { session_id; session_dir; checkpoints = [] }

let persist_message ?source session msg =
  let msg = Inference_utils.sanitize_message_utf8 msg in
  let path = Filename.concat session.session_dir "history.jsonl" in
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
      `Assoc (("timestamp", `Float now_ts) :: ("ts_unix", `Float now_ts) :: fields)
    | j -> j
  in
  let line = Yojson.Safe.to_string payload ^ "\n" in
  Fs_compat.append_file path line
