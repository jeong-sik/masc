(** Keeper_exec_context — shared keeper context utilities: working context,
    checkpoint management, compaction, room presence, system prompts,
    text processing, proactive prompt helpers, and proactive generation.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are inlined below. *)

open Printf
open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_status

(* ================================================================ *)
(* Constants                                                         *)
(* ================================================================ *)

(** Maximum messages to retain in checkpoints (load and save).
    Caps both load-time deserialization and save-time persistence to prevent
    unbounded memory growth.  The context_reducer (keep_last 30) trims
    further during Agent.run, so 60 gives the reducer room to operate. *)
let max_checkpoint_messages = 60

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

(** CJK-aware token estimate delegated to OAS Context_reducer. *)
let msg_tokens (m : Agent_sdk.Types.message) : int =
  let estimated = Agent_sdk.Context_reducer.estimate_message_tokens m in
  (* Use 15% safety buffer for message estimation errors (#5053).
     Ceiling-based to avoid truncation erasing the buffer. *)
  int_of_float (ceil (float_of_int estimated *. 1.15))

let count_tokens (system_prompt : string) (msgs : Agent_sdk.Types.message list) =
  let sys_tokens = Agent_sdk.Context_reducer.estimate_char_tokens system_prompt in
  List.fold_left (fun acc m -> acc + msg_tokens m) sys_tokens msgs

let token_count (ctx : working_context) =
  count_tokens ctx.system_prompt ctx.messages

let message_token_count (ctx : working_context) =
  count_tokens "" ctx.messages

let message_count (ctx : working_context) =
  List.length ctx.messages

let context_ratio (ctx : working_context) : float =
  if ctx.max_tokens = 0 then 0.0
  else float_of_int (token_count ctx) /. float_of_int ctx.max_tokens

let exceeds_threshold ctx threshold =
  context_ratio ctx >= threshold

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
    (cp : Agent_sdk.Checkpoint.t)
    ~(primary_model_max_tokens : int) : working_context =
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let max_tokens =
    checkpoint_max_tokens cp ~fallback:primary_model_max_tokens
  in
  (* Cap loaded messages — see module-level max_checkpoint_messages. *)
  let max_checkpoint_messages = max_checkpoint_messages in
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
  |> Option.value ~default:"keeper_unified"

let save_oas_checkpoint
    ~(session : session_context)
    ~(agent_name : string)
    ~(model : string)
    ~(ctx : working_context)
    ~(generation : int)
  : Agent_sdk.Checkpoint.t =
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
  Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir checkpoint;
  checkpoint

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

type handoff_rollover = {
  updated_meta : keeper_meta;
  handoff_json : Yojson.Safe.t option;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

type compaction_event = {
  applied : bool;
  trigger : string option;
  decision : string;
  before_tokens : int;
  after_tokens : int;
  saved_tokens : int;
}

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_sdk.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  compaction : compaction_event;
  turn_generation : int;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

type overflow_retry_recovery = {
  checkpoint : Agent_sdk.Checkpoint.t;
  compaction : compaction_event;
  turn_generation : int;
} [@@warning "-69"]

let maybe_rollover_oas_handoff
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : handoff_rollover =
  match checkpoint with
  | None ->
      {
        updated_meta = meta;
        handoff_json = None;
        context_ratio = 0.0;
        context_tokens = 0;
        context_max = primary_model_max_tokens;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_oas_checkpoint cp ~primary_model_max_tokens in
      let current_generation =
        checkpoint_generation cp ~fallback:meta.runtime.generation
      in
      let base_meta =
        if current_generation = meta.runtime.generation then meta
        else map_runtime (fun rt -> { rt with generation = current_generation }) meta
      in
      let ratio = context_ratio ctx in
      let cooldown_elapsed =
        base_meta.runtime.last_handoff_ts <= 0.0
        || Time_compat.now () -. base_meta.runtime.last_handoff_ts
           >= float_of_int base_meta.handoff_cooldown_sec
      in
      let rollover_base =
        {
          updated_meta = base_meta;
          handoff_json = None;
          context_ratio = ratio;
          context_tokens = token_count ctx;
          context_max = ctx.max_tokens;
          message_count = message_count ctx;
        }
      in
      if
        not base_meta.auto_handoff
        || ratio < base_meta.handoff_threshold
        || not cooldown_elapsed
      then
        rollover_base
      else
        let now_ts = Time_compat.now () in
        let prev_trace_id = base_meta.runtime.trace_id in
        let new_trace_id = Keeper_identity.generate_trace_id () in
        let next_generation = current_generation + 1 in
        let new_session =
          create_session ~session_id:new_trace_id ~base_dir
        in
        try
          ignore
            (save_oas_checkpoint ~session:new_session
               ~agent_name:base_meta.agent_name
               ~model ~ctx ~generation:next_generation);
          let updated_meta =
            {
              base_meta with
              updated_at = now_iso ();
              runtime = { base_meta.runtime with
                trace_id = new_trace_id;
                trace_history =
                  dedupe_keep_order (prev_trace_id :: base_meta.runtime.trace_history);
                generation = next_generation;
                last_handoff_ts = now_ts;
              };
            }
          in
          let handoff_json =
            `Assoc
              [
                ("performed", `Bool true);
                ("from_generation", `Int current_generation);
                ("to_generation", `Int next_generation);
                ("new_generation", `Int next_generation);
                ("prev_trace_id", `String prev_trace_id);
                ("new_trace_id", `String new_trace_id);
                ("to_model", `String model);
                ("context_ratio", `Float ratio);
              ]
          in
          Log.Keeper.info
            "keeper:%s OAS handoff rollover trace=%s->%s gen=%d->%d ratio=%.3f"
            base_meta.name prev_trace_id new_trace_id current_generation
            next_generation ratio;
          { rollover_base with updated_meta; handoff_json = Some handoff_json }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log_keeper_exn ~label:"keeper OAS handoff rollover failed" exn;
            rollover_base

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let oas_checkpoint =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:trace_id
  in
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
      ( session,
        Some
          (context_of_oas_checkpoint checkpoint ~primary_model_max_tokens) )
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
  | _ -> (session, None)

let save_checkpoint session (ctx : working_context) ~generation =
  let ckpt = create_checkpoint ctx ~generation in
  save_session_checkpoint session ckpt;
  ckpt

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  (meta.compaction.ratio_gate, meta.compaction.message_gate, meta.compaction.token_gate)

let compact_if_needed
    ~(meta : keeper_meta)
    ~(now_ts : float)
    (ctx : working_context) :
    working_context * string option * string =
  let ratio = context_ratio ctx in
  let message_count = message_count ctx in
  let token_count = token_count ctx in
  let ratio_gate, message_gate, token_gate = compaction_policy_of_keeper meta in
  let cooldown = Float.of_int meta.compaction.cooldown_sec in
  let last_reflection_ts = max meta.runtime.last_continuity_update_ts meta.runtime.proactive_rt.last_ts in
  let reflection_ready =
    last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown
  in
  let hold_s =
    if cooldown <= 0.0 then 0.0
    else if last_reflection_ts <= 0.0 then
      Float.of_int meta.compaction.cooldown_sec
    else
      max
        0.0
        (Float.of_int meta.compaction.cooldown_sec
       -. (now_ts -. last_reflection_ts))
  in
  let trigger_reason =
    if not reflection_ready then
      Some
        (Printf.sprintf
           "skipped:continuity_reflection(%0.0fs<%ds)"
           hold_s meta.compaction.cooldown_sec)
    else if ratio >= ratio_gate then
      Some (Printf.sprintf "ratio(%.4f>=%.4f)" ratio ratio_gate)
    else if message_gate > 0 && message_count >= message_gate then
      Some (Printf.sprintf "messages(%d>=%d)" message_count message_gate)
    else if token_gate > 0 && token_count >= token_gate then
      Some (Printf.sprintf "tokens(%d>=%d)" token_count token_gate)
    else None
  in
  match trigger_reason with
  | None -> (ctx, None, "blocked:below_thresholds")
  | Some reason ->
      if String.starts_with ~prefix:"skipped:" reason then
        (ctx, None, reason)
      else
        (* PreCompact observability: log strategy and context state (#3165) *)
      let strategies = Context_compact_oas.[
        PruneToolOutputs; MergeContiguous;
        DropLowImportance]
      in
      (* FoldCompleted replaces SummarizeOld — applied as a separate
         OAS Custom reducer after the standard strategy pipeline. *)
      let fold_reducer = Keeper_compaction.fold_completed_strategy () in
      let strategy_names =
        List.map Context_compact_oas.strategy_name strategies
        @ ["FoldCompleted"]
      in
      Log.Harness.info
        "[pre_compact] keeper=%s ratio=%.4f messages=%d tokens=%d trigger=%s"
        meta.name ratio message_count token_count reason;
      let model_meta =
        let model_labels = Oas_model_resolve.models_of_cascade_name meta.cascade_name in
        let primary_id = match Llm_provider.Cascade_config.parse_model_strings model_labels with
          | c :: _ -> c.Llm_provider.Provider_config.model_id | [] -> "auto" in
        Llm_provider.Model_meta.for_model_id primary_id
      in
      let pre_compact_event =
        Dashboard_harness_health.record_pre_compact
          ~keeper_name:meta.name ~context_ratio:ratio ~message_count
          ~token_count ~strategies:strategy_names
          ~context_window:model_meta.context_window
          ~is_local_model:model_meta.is_local ~trigger:reason
      in
      (try
         Sse.broadcast
           (`Assoc
             [
               ("type", `String "oas:masc:harness:pre_compact");
               ( "payload",
                 `Assoc
                   [
                     ("timestamp", `Float pre_compact_event.timestamp);
                     ("keeper_name", `String pre_compact_event.keeper_name);
                     ("context_ratio", `Float pre_compact_event.context_ratio);
                     ("message_count", `Int pre_compact_event.message_count);
                     ("token_count", `Int pre_compact_event.token_count);
                     ( "strategies",
                       `List
                         (List.map
                            (fun value -> `String value)
                            pre_compact_event.strategies) );
                     ("model_family", `String pre_compact_event.model_family);
                     ("context_window", `Int pre_compact_event.context_window);
                     ("is_local_model", `Bool pre_compact_event.is_local_model);
                     ("trigger", `String pre_compact_event.trigger);
                   ] );
             ])
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Harness.warn "[pre_compact] sse broadcast failed: %s"
            (Printexc.to_string exn));
      let messages =
          let msgs_after_compact, _ =
            Context_compact_oas.compact
              ~system_prompt:ctx.system_prompt
              ~messages:ctx.messages
              ~strategies
              ()
          in
          (* Apply keeper-private fold after standard strategies *)
          let msgs_after_fold =
            Agent_sdk.Context_reducer.reduce fold_reducer msgs_after_compact
          in
          let token_count =
            Context_compact_oas.count_tokens ctx.system_prompt msgs_after_fold
          in
          let _ = token_count in
          msgs_after_fold
        in
        let compacted_ctx =
          sync_oas_context { ctx with messages }
        in
        (compacted_ctx, Some reason, "applied:" ^ reason)

let apply_post_turn_lifecycle
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : post_turn_lifecycle =
  let now_ts = Time_compat.now () in
  let no_checkpoint_decision = "skipped:no_checkpoint" in
  let apply_continuity_summary
      ~(meta : keeper_meta)
      ~(ctx : working_context) : keeper_meta =
    match latest_state_snapshot_from_messages ctx.messages with
    | None -> meta
    | Some snapshot ->
        {
          meta with
          continuity_summary = keeper_state_snapshot_to_summary_text snapshot;
          runtime =
            {
              meta.runtime with
              last_continuity_update_ts = now_ts;
            };
        }
  in
  match checkpoint with
  | None ->
      let updated_meta =
        map_runtime
          (fun rt ->
            {
              rt with
              compaction_rt =
                {
                  rt.compaction_rt with
                  last_check_ts = now_ts;
                  last_decision = no_checkpoint_decision;
                };
            })
          meta
      in
      {
        updated_meta;
        checkpoint = None;
        handoff_json = None;
        compaction =
          {
            applied = false;
            trigger = None;
            decision = no_checkpoint_decision;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          };
        turn_generation = meta.runtime.generation;
        context_ratio = 0.0;
        context_tokens = 0;
        context_max = primary_model_max_tokens;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_oas_checkpoint cp ~primary_model_max_tokens in
      let current_generation =
        checkpoint_generation cp ~fallback:meta.runtime.generation
      in
      let base_meta =
        if current_generation = meta.runtime.generation then meta
        else
          map_runtime
            (fun rt -> { rt with generation = current_generation })
            meta
      in
      let before_tokens = token_count ctx in
      let compacted_ctx, trigger, decision =
        compact_if_needed ~meta:base_meta ~now_ts ctx
      in
      let compaction_applied =
        String.starts_with ~prefix:"applied:" decision
      in
      let after_tokens = token_count compacted_ctx in
      let saved_tokens = max 0 (before_tokens - after_tokens) in
      let meta_after_compaction =
        map_runtime
          (fun rt ->
            {
              rt with
              compaction_rt =
                {
                  count =
                    rt.compaction_rt.count
                    + if compaction_applied then 1 else 0;
                  last_ts =
                    if compaction_applied then now_ts else rt.compaction_rt.last_ts;
                  last_before_tokens =
                    if compaction_applied then before_tokens
                    else rt.compaction_rt.last_before_tokens;
                  last_after_tokens =
                    if compaction_applied then after_tokens
                    else rt.compaction_rt.last_after_tokens;
                  last_check_ts = now_ts;
                  last_decision = decision;
                };
            })
          base_meta
      in
      let checkpoint =
        if not compaction_applied then Some cp
        else
          let session =
            create_session ~session_id:meta_after_compaction.runtime.trace_id ~base_dir
          in
          Some
            (save_oas_checkpoint ~session
               ~agent_name:meta_after_compaction.agent_name
               ~model ~ctx:compacted_ctx ~generation:current_generation)
      in
      let rollover =
        maybe_rollover_oas_handoff ~base_dir
          ~meta:meta_after_compaction
          ~model
          ~primary_model_max_tokens
          ~checkpoint
      in
      let continuity_meta =
        apply_continuity_summary
          ~meta:rollover.updated_meta
          ~ctx:compacted_ctx
      in
      {
        updated_meta = continuity_meta;
        checkpoint;
        handoff_json = rollover.handoff_json;
        compaction =
          {
            applied = compaction_applied;
            trigger;
            decision;
            before_tokens;
            after_tokens;
            saved_tokens;
          };
        turn_generation = current_generation;
        context_ratio = rollover.context_ratio;
        context_tokens = rollover.context_tokens;
        context_max = rollover.context_max;
        message_count = rollover.message_count;
      }

let forced_overflow_retry_meta
    (meta : keeper_meta)
    ~(turn_generation : int)
    ~(now_ts : float) : keeper_meta =
  let base_meta =
    if turn_generation = meta.runtime.generation then meta
    else
      map_runtime
        (fun rt -> { rt with generation = turn_generation })
        meta
  in
  {
    (map_runtime
       (fun rt ->
         let last_continuity_update_ts =
           if rt.last_continuity_update_ts > 0.0
           then rt.last_continuity_update_ts
           else now_ts
         in
         let proactive_rt =
           if rt.proactive_rt.last_ts > 0.0
           then rt.proactive_rt
           else { rt.proactive_rt with last_ts = now_ts }
         in
         { rt with last_continuity_update_ts; proactive_rt })
       base_meta)
    with
    compaction =
      {
        base_meta.compaction with
        ratio_gate = 0.0;
        message_gate = 0;
        token_gate = 0;
        cooldown_sec = 0;
      };
  }

let[@warning "-32"] recover_latest_checkpoint_for_overflow_retry
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(model : string)
    ~(primary_model_max_tokens : int) : overflow_retry_recovery option =
  let session = create_session ~session_id:meta.runtime.trace_id ~base_dir in
  let oas_checkpoint =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:meta.runtime.trace_id
  in
  let legacy_checkpoint =
    try load_latest_checkpoint session
    with exn ->
      Log.Keeper.error "keeper:%s overflow retry checkpoint load failed: %s"
        meta.runtime.trace_id (Printexc.to_string exn);
      None
  in
  let prefer_legacy =
    match oas_checkpoint, legacy_checkpoint with
    | Some oas, Some legacy -> legacy.timestamp > oas.created_at
    | _ -> false
  in
  let selected =
    match (prefer_legacy, oas_checkpoint, legacy_checkpoint) with
    | false, Some checkpoint, _ ->
        let turn_generation =
          checkpoint_generation checkpoint ~fallback:meta.runtime.generation
        in
        Some
          ( context_of_oas_checkpoint checkpoint ~primary_model_max_tokens,
            turn_generation )
    | _, _, Some checkpoint ->
        (try
           Some
             ( context_of_legacy_checkpoint checkpoint
                 ~primary_model_max_tokens,
               checkpoint.generation )
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.Keeper.error
               "keeper:%s overflow retry legacy checkpoint restore failed: %s"
               meta.runtime.trace_id (Printexc.to_string exn);
             (match oas_checkpoint with
              | Some checkpoint ->
                  let turn_generation =
                    checkpoint_generation checkpoint
                      ~fallback:meta.runtime.generation
                  in
                  Some
                    ( context_of_oas_checkpoint checkpoint
                        ~primary_model_max_tokens,
                      turn_generation )
              | None -> None))
    | _ -> None
  in
  match selected with
  | None -> None
  | Some (ctx, turn_generation) ->
      let now_ts = Time_compat.now () in
      let ctx =
        if primary_model_max_tokens <= 0 then ctx
        else sync_oas_context { ctx with max_tokens = min ctx.max_tokens primary_model_max_tokens }
      in
      let before_tokens = token_count ctx in
      let retry_meta =
        forced_overflow_retry_meta meta ~turn_generation ~now_ts
      in
      let compacted_ctx, trigger, base_decision =
        compact_if_needed ~meta:retry_meta ~now_ts ctx
      in
      let strategy_after_tokens = token_count compacted_ctx in
      let strategy_after_message_tokens =
        message_token_count compacted_ctx
      in
      let compacted_ctx =
        if
          primary_model_max_tokens > 0
          && strategy_after_message_tokens > primary_model_max_tokens
        then
          let reducer =
            let target_tokens = int_of_float (float_of_int primary_model_max_tokens *. 0.9) in
            Agent_sdk.Context_reducer.from_context_config ~max_tokens:target_tokens ()
          in
          let messages = Agent_sdk.Context_reducer.reduce reducer compacted_ctx.messages in
          sync_oas_context
            { compacted_ctx with messages; max_tokens = min compacted_ctx.max_tokens primary_model_max_tokens }
        else
          compacted_ctx
      in
      let after_tokens = token_count compacted_ctx in
      let after_message_tokens = message_token_count compacted_ctx in
      let hard_trim_applied = after_tokens < strategy_after_tokens in
      let decision =
        if hard_trim_applied then
          Printf.sprintf "%s+budget_trim(%d->%d,msg<=%d)"
            base_decision strategy_after_tokens after_tokens
            primary_model_max_tokens
        else
          base_decision
      in
      let compaction_applied =
        String.starts_with ~prefix:"applied:" base_decision || hard_trim_applied
      in
      let meaningful_reduction = after_tokens < before_tokens in
      let fits_budget =
        primary_model_max_tokens <= 0
        || after_message_tokens <= primary_model_max_tokens
      in
      if not (compaction_applied && meaningful_reduction && fits_budget) then None
      else
        let compaction =
          {
            applied = true;
            trigger;
            decision;
            before_tokens;
            after_tokens;
            saved_tokens = max 0 (before_tokens - after_tokens);
          }
        in
        try
          let checkpoint =
            save_oas_checkpoint ~session
              ~agent_name:retry_meta.agent_name
              ~model ~ctx:compacted_ctx ~generation:turn_generation
          in
          Some { checkpoint; compaction; turn_generation }
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            log_keeper_exn
              ~label:"overflow retry checkpoint save failed"
              exn;
            None

let generate_trace_id = Keeper_identity.generate_trace_id

let keeper_board_write_tool_names =
  [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]

let keeper_write_done tool_names =
  List.exists (fun name -> List.mem name keeper_board_write_tool_names) tool_names

let keeper_action_kind_of_tool_names tool_names =
  if List.mem "keeper_board_post" tool_names then "post"
  else if List.mem "keeper_board_comment" tool_names then "comment"
  else if List.mem "keeper_board_vote" tool_names then "vote"
  else "none"


let effective_model_labels_for_turn (m : keeper_meta) : string list =
  let configured = Oas_model_resolve.models_of_cascade_name m.cascade_name in
  let configured_ids =
    try
      Llm_provider.Cascade_config.parse_model_strings configured
      |> List.map (fun (c : Llm_provider.Provider_config.t) -> String.trim c.model_id)
    with _ -> []
  in
  match String.trim (active_model_of_meta m) with
  | "" -> configured
  | model ->
      let model_allowed =
        List.mem model configured
        || List.mem model configured_ids
      in
      if model_allowed
      then dedupe_keep_order (model :: configured)
      else configured

let room_cursor_for meta room_id =
  meta.last_seen_seq_by_room
  |> List.find_map (fun (rid, seq) -> if rid = room_id then Some seq else None)
  |> Option.value ~default:0

let set_room_cursor meta room_id seq =
  let kept =
    meta.last_seen_seq_by_room
    |> List.filter (fun (rid, _) -> rid <> room_id)
  in
  {
    meta with
    last_seen_seq_by_room = dedupe_keep_order ((room_id, seq) :: kept);
  }

let room_ids_for_meta _config (_meta : keeper_meta) : string list =
  [ "default" ]

let ensure_keeper_room_presence config (meta : keeper_meta) : keeper_meta =
  let room_ids = room_ids_for_meta config meta in
  let successful_rooms =
    List.fold_left
      (fun acc room_id ->
        try
          if
            not
              (Room.is_agent_joined config
                 ~agent_name:meta.agent_name)
          then begin
            Room.ensure_room_bootstrap config room_id;
            ignore
              (Room.join config ~agent_name:meta.agent_name
                 ~capabilities:[ "keeper" ] ())
          end;
          ignore
            (Room.heartbeat config ~agent_name:meta.agent_name);
          room_id :: acc
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          log_keeper_exn ~label:(Printf.sprintf "room presence sync failed for %s in %s" meta.name room_id) exn;
          acc)
      [] room_ids
  in
  { meta with joined_room_ids = List.rev successful_rooms }

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

(* Delegate to Keeper_prompt — single source of truth for keeper prompts. *)
let keeper_constitution = Keeper_prompt.keeper_constitution

let build_keeper_system_prompt = Keeper_prompt.build_keeper_system_prompt

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if contains_ci b c then b
  else Printf.sprintf "%s; %s" b c


include Keeper_text_processing

let memory_check_default_json () : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool false);
    ("query_kind", `String "none");
    ("expected_topic", `Null);
    ("candidate_count", `Int 0);
    ("initial_score", `Float 0.0);
    ("final_score", `Float 0.0);
    ("threshold", `Float 0.18);
    ("passed", `Bool true);
    ("best_match", `Null);
    ("correction_applied", `Bool false);
    ("correction_success", `Bool false);
    ("prompt_fallback_applied", `Bool false);
    ("prompt_fallback_success", `Bool false);
    ("deterministic_fallback_applied", `Bool false);
    ("recall_fallback_applied", `Bool false);
  ]
