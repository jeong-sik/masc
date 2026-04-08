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
    [Agent_sdk.Context_reducer.estimate_*] directly for decision-making. *)

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
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.ToolResult { tool_use_id; content = text; is_error = false; json = None }]; name = None; tool_call_id = None }
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
    :: Oas_model_resolve.models_of_cascade_name meta.cascade_name
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

(** Patch an OAS checkpoint: unify session_id and replace the last
    assistant message's text content with [response_text] (which includes
    MASC's [STATE] synthesis).  This ensures read_continuity_summary can
    find the [STATE] block in checkpoint messages on the next turn.  #5431 *)
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
  { cp with Agent_sdk.Checkpoint.session_id; messages }

let save_checkpoint session (ctx : working_context) ~generation =
  let ckpt = create_checkpoint ctx ~generation in
  save_session_checkpoint session ckpt;
  ckpt
