(** Keeper_context_core — shared keeper context utilities: working context,
    checkpoint management, serialization, and AGENT_CORE checkpoint operations.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are inlined below.

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

open Printf
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Message_json = Keeper_context_core_message_json
module Canonical_tool = Agent_core.Canonical_tool

(* ================================================================ *)
(* Working Context Types (re-exported from Keeper_types)             *)
(* ================================================================ *)

type working_context = Keeper_types.working_context


type session_context = Keeper_types.session_context

(* ================================================================ *)
(* Working Context Operations (inlined from Keeper_working_context)  *)
(* ================================================================ *)

let text_of_message = Agent_core.Types.text_of_message

let checkpoint_of_context (ctx : working_context) = ctx.checkpoint

let agent_core_context_of_context (ctx : working_context) = ctx.checkpoint.context

let system_prompt_of_context (ctx : working_context) =
  Option.value ~default:"" ctx.checkpoint.system_prompt

let messages_of_context (ctx : working_context) =
  ctx.checkpoint.messages

let empty_runtime_checkpoint ~system_prompt ~messages
    ~(context : Agent_core.Context.t) : Agent_core.Checkpoint.t =
  {
    Agent_core.Checkpoint.version = Agent_core.Checkpoint.checkpoint_version;
    session_id = "";
    agent_name = "";
    model = "";
    system_prompt = Some system_prompt;
    messages;
    usage = Agent_core.Types.empty_usage;
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
    response_format = Agent_core.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    context;
    mcp_sessions = [];
    working_context = None;
  }

let message_count (ctx : working_context) =
  List.length (messages_of_context ctx)

let create_agent_core_context ~eio =
  if eio then Agent_core.Context.create () else Agent_core.Context.create_sync ()

let create ~eio ~system_prompt =
  let context = create_agent_core_context ~eio in
  let checkpoint =
    empty_runtime_checkpoint ~system_prompt ~messages:[] ~context
  in
  { checkpoint }

let set_system_prompt (ctx : working_context) ~system_prompt =
  let messages =
    List.map
      (fun (m : Agent_core.Types.message) ->
        if m.role = Agent_core.Types.System
        then { m with role = Agent_core.Types.Assistant }
        else m)
      (messages_of_context ctx)
  in
  let checkpoint =
    { ctx.checkpoint with system_prompt = Some system_prompt; messages }
  in
  { checkpoint }

let append ctx (msg : Agent_core.Types.message) =
  let checkpoint =
    { ctx.checkpoint with messages = messages_of_context ctx @ [ msg ] }
  in
  { checkpoint }

let append_many ctx msgs =
  List.fold_left append ctx msgs

let sync_agent_core_context (ctx : working_context) : working_context =
  let context = agent_core_context_of_context ctx in
  let message_count = message_count ctx in
  Agent_core.Context.set_scoped context Agent_core.Context.Session
    "message_count" (`Int message_count);
  ctx

let role_to_string = Message_json.role_to_string
let role_of_string_opt = Message_json.role_of_string_opt
let message_to_json = Message_json.message_to_json
let message_of_json = Message_json.message_of_json
let text_of_history_jsonl_json = Message_json.text_of_history_jsonl_json

(* Naming a session does not open one. Every writer under this directory goes
   through [Keeper_fs.save_atomic], which creates the parent it needs, so the
   directory appears when something is actually stored in it. Creating it here
   meant a failed boot — which never reaches a write — still left an empty
   session behind, and autoboot retries left one per round: 39,594 directories
   had accumulated by 2026-08-23, 96.7% of the recent ones belonging to no
   keeper meta at all (#29586). *)
let create_session ~session_id ~base_dir =
  { session_id; session_dir = Filename.concat base_dir session_id }

include Keeper_context_core_history

(* ================================================================ *)
(* End of inlined Keeper_working_context operations                  *)
(* ================================================================ *)

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
