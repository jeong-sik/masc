(** Keeper_context_core — shared keeper context utilities: working context,
    checkpoint management, serialization, and OAS checkpoint operations.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are inlined below.

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

open Printf
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_json = Keeper_context_core_message_json
(* ================================================================ *)
(* Working Context Types (re-exported from Keeper_types)             *)
(* ================================================================ *)

type working_context = Keeper_types.working_context


type session_context = Keeper_types.session_context

(* ================================================================ *)
(* Working Context Operations (inlined from Keeper_working_context)  *)
(* ================================================================ *)

let text_of_message = Agent_sdk.Types.text_of_message

let ensure_dir path =
  (* ensure_dir returns the created path; fire-and-forget *)
  ignore (Keeper_fs.ensure_dir path)

let checkpoint_of_context (ctx : working_context) = ctx.checkpoint

let oas_context_of_context (ctx : working_context) = ctx.checkpoint.context

let max_tokens_of_context (ctx : working_context) =
  ctx.max_tokens

let with_max_tokens (ctx : working_context) max_tokens =
  (* OAS no longer carries a cumulative-token cap on the checkpoint; the
     working_context [max_tokens] is the per-response output limit only. *)
  { ctx with max_tokens }

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
    reasoning_effort = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    context;
    mcp_sessions = [];
    working_context = None;
  }

let message_count (ctx : working_context) =
  List.length (messages_of_context ctx)

let create_oas_context ~eio =
  if eio then Agent_sdk.Context.create () else Agent_sdk.Context.create_sync ()

let create ~eio ~system_prompt ~max_tokens =
  let context = create_oas_context ~eio in
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
  Agent_sdk.Context.set_scoped context Agent_sdk.Context.Session
    "message_count" (`Int message_count);
  ctx

let role_to_string = Message_json.role_to_string
let role_of_string_opt = Message_json.role_of_string_opt
let content_blocks_to_json = Message_json.content_blocks_to_json
let content_blocks_of_json = Message_json.content_blocks_of_json
let string_field_opt = Message_json.string_field_opt
let metadata_of_json = Message_json.metadata_of_json
let message_to_json = Message_json.message_to_json
let message_of_json = Message_json.message_of_json
let text_of_history_jsonl_json = Message_json.text_of_history_jsonl_json

let trim_messages_preserving_pairs = Keeper_context_tool_message_pairs.trim_messages_preserving_pairs

type tool_pair_repair_stats = Keeper_context_core_pair_repair_stats.tool_pair_repair_stats =
  { dropped_tool_uses : int
  ; dropped_tool_results : int
  ; dropped_tool_use_samples : (string * string) list
  ; dropped_tool_result_ids : string list
  }

let empty_tool_pair_repair_stats =
  Keeper_context_core_pair_repair_stats.empty_tool_pair_repair_stats
let add_tool_pair_repair_stats =
  Keeper_context_core_pair_repair_stats.add_tool_pair_repair_stats
let tool_pair_repair_stats_changed =
  Keeper_context_core_pair_repair_stats.tool_pair_repair_stats_changed
let pair_repair_diagnostic_max_bytes =
  Keeper_context_core_pair_repair_stats.pair_repair_diagnostic_max_bytes
let bound_pair_repair_diagnostic_string =
  Keeper_context_core_pair_repair_stats.bound_pair_repair_diagnostic_string
let pair_repair_metadata_key =
  Keeper_context_core_pair_repair_stats.pair_repair_metadata_key
let pair_repair_metadata_keys =
  Keeper_context_core_pair_repair_stats.pair_repair_metadata_keys
let with_pair_repair_metadata =
  Keeper_context_core_pair_repair_stats.with_pair_repair_metadata


let serialize_context (ctx : working_context) : string =
  let json = `Assoc [
    ( "system_prompt",
      `String
        (Inference_utils.sanitize_text_utf8 (system_prompt_of_context ctx)) );
    ("messages", `List (List.map message_to_json (messages_of_context ctx)));
    ("max_tokens", `Int (max_tokens_of_context ctx));
  ] in
  Yojson.Safe.to_string json

let serialized_bytes (ctx : working_context) : int =
  String.length (serialize_context ctx)

let deserialize_context ~eio (s : string) ~max_tokens : working_context =
  let json = Yojson.Safe.from_string s in
  let system_prompt = (match Json_util.assoc_member_opt "system_prompt" json with Some (`String s) -> s | _ -> "") in
  let messages =
    (match Json_util.assoc_member_opt "messages" json with Some (`List l) -> l | _ -> []) |> List.map message_of_json
  in
  let context = create_oas_context ~eio in
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
    ("max_tokens", `Int (max_tokens_of_context ctx));
  ]


let create_session ~session_id ~base_dir =
  let session_dir = Filename.concat base_dir session_id in
  ensure_dir session_dir;
  { session_id; session_dir }

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
