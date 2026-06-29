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
(* Constants                                                         *)
(* ================================================================ *)

(** Default maximum messages to retain in checkpoints (load and save).
    Caps both load-time deserialization and save-time persistence to prevent
    unbounded memory growth.  The context_reducer (keep_last 30) trims
    further during Agent.run, so 120 gives the reducer workspace to operate.
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


type session_context = Keeper_types.session_context

(* ================================================================ *)
(* Working Context Operations (inlined from Keeper_working_context)  *)
(* ================================================================ *)

let text_of_message = Agent_sdk.Types.text_of_message

let ensure_dir path =
  (* ensure_dir returns the created path; fire-and-forget *)
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
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
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

let create ~eio ~system_prompt ~max_tokens =
  let context = Agent_sdk.Context.create ~eio () in
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

let role_to_string = Message_json.role_to_string
let role_of_string_opt = Message_json.role_of_string_opt
let content_blocks_to_json = Message_json.content_blocks_to_json
let content_blocks_of_json = Message_json.content_blocks_of_json
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
let has_tool_use_block = Keeper_context_tool_message_pairs.has_tool_use_block
let trim_messages_preserving_pairs = Keeper_context_tool_message_pairs.trim_messages_preserving_pairs

(* Tool block text renderers extracted to
   [Keeper_context_tool_text_block] (godfile decomp). Parent wrapper
   injects [default_max_checkpoint_tool_result_chars] so the existing
   surface (no [~max_chars] arg) stays byte-compatible for callers. *)
let tool_result_text_of_block ~tool_use_id ~content ~json =
  Keeper_context_tool_text_block.tool_result_text_of_block
    ~tool_use_id
    ~content
    ~json
    ~max_chars:default_max_checkpoint_tool_result_chars
;;

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

type tool_pair_repair_mode =
  { drop_dangling_uses : bool
  ; drop_orphan_results : bool
  }

let record_dropped_tool_use stats id name =
  let id = bound_pair_repair_diagnostic_string id in
  let name = bound_pair_repair_diagnostic_string name in
  stats :=
    add_tool_pair_repair_stats
      !stats
      { empty_tool_pair_repair_stats with
        dropped_tool_uses = 1
      ; dropped_tool_use_samples = [ id, name ]
      }

let record_dropped_tool_result stats tool_use_id =
  let tool_use_id = bound_pair_repair_diagnostic_string tool_use_id in
  stats :=
    add_tool_pair_repair_stats
      !stats
      { empty_tool_pair_repair_stats with
        dropped_tool_results = 1
      ; dropped_tool_result_ids = [ tool_use_id ]
      }

let pair_repair_metadata_kind stats =
  match stats.dropped_tool_uses > 0, stats.dropped_tool_results > 0 with
  | true, true -> "dropped_tool_pair_blocks"
  | true, false -> "dropped_tool_use"
  | false, true -> "dropped_tool_result"
  | false, false -> "none"

let annotate_pair_repair_metadata stats (msg : Agent_sdk.Types.message) =
  if not (tool_pair_repair_stats_changed stats)
  then msg
  else
    msg
    |> with_pair_repair_metadata
         ~tool_use_samples:stats.dropped_tool_use_samples
         ~tool_result_ids:stats.dropped_tool_result_ids
         ~kind:(pair_repair_metadata_kind stats)
         ~count:(stats.dropped_tool_uses + stats.dropped_tool_results)

let repaired_message_opt msg stats content =
  match content with
  | [] -> None
  | content -> Some ({ msg with content } |> annotate_pair_repair_metadata stats)

let is_tool_result_span_message msg =
  has_tool_result_block msg && tool_use_ids_of_message msg = []

let split_tool_result_group messages =
  let rec loop original result remainder = function
    | msg :: rest when tool_use_ids_of_message msg <> [] ->
        List.rev original, List.rev result, List.rev remainder, msg :: rest
    | msg :: rest when is_tool_result_span_message msg ->
        loop (msg :: original) (msg :: result) remainder rest
    | msg :: rest -> loop (msg :: original) result (msg :: remainder) rest
    | [] -> List.rev original, List.rev result, List.rev remainder, []
  in
  loop [] [] [] messages

let filter_group_message_content
    mode
    ~(allowed_tool_use_ids : string list)
    ~(matched_tool_result_ids : string list)
    ~(seen_tool_result_ids : string list ref)
    (msg : Agent_sdk.Types.message)
    : Agent_sdk.Types.content_block list * tool_pair_repair_stats =
  let stats = ref empty_tool_pair_repair_stats in
  let content =
    List.filter_map
      (function
        | Agent_sdk.Types.ToolUse { id; name; _ }
          when mode.drop_dangling_uses
               && (msg.role <> Agent_sdk.Types.Assistant
                   || not (List.mem id matched_tool_result_ids)) ->
            record_dropped_tool_use stats id name;
            None
        | Agent_sdk.Types.ToolResult { tool_use_id; _ } as block
          when mode.drop_orphan_results ->
            let allowed = List.mem tool_use_id allowed_tool_use_ids in
            let duplicate = List.mem tool_use_id !seen_tool_result_ids in
            if allowed && not duplicate
            then (
              seen_tool_result_ids := tool_use_id :: !seen_tool_result_ids;
              Some block)
            else (
              record_dropped_tool_result stats tool_use_id;
              None)
        | other -> Some other)
      msg.content
  in
  content, !stats

let filter_orphan_result_message_content
    mode
    (msg : Agent_sdk.Types.message)
    : Agent_sdk.Types.content_block list * tool_pair_repair_stats =
  let drop_non_assistant_tool_use =
    mode.drop_dangling_uses && msg.role <> Agent_sdk.Types.Assistant
  in
  if (not mode.drop_orphan_results) && not drop_non_assistant_tool_use
  then msg.content, empty_tool_pair_repair_stats
  else
    let stats = ref empty_tool_pair_repair_stats in
    let content =
      List.filter_map
        (function
          | Agent_sdk.Types.ToolResult { tool_use_id; _ }
            when mode.drop_orphan_results ->
              record_dropped_tool_result stats tool_use_id;
              None
          | Agent_sdk.Types.ToolUse { id; name; _ } when drop_non_assistant_tool_use ->
              record_dropped_tool_use stats id name;
              None
          | other -> Some other)
        msg.content
    in
    content, !stats

let order_tool_result_group_by_tool_use_ids tool_use_ids messages =
  let rec index_of needle index = function
    | [] -> None
    | id :: rest ->
        if String.equal needle id
        then Some index
        else index_of needle (index + 1) rest
  in
  let message_rank msg =
    msg
    |> tool_result_ids_of_message
    |> List.filter_map (fun id -> index_of id 0 tool_use_ids)
    |> function
    | [] -> max_int
    | ranks -> List.fold_left min max_int ranks
  in
  messages
  |> List.mapi (fun original_index msg -> message_rank msg, original_index, msg)
  |> List.sort (fun (left_rank, left_index, _) (right_rank, right_index, _) ->
    match Int.compare left_rank right_rank with
    | 0 -> Int.compare left_index right_index
    | comparison -> comparison)
  |> List.map (fun (_, _, msg) -> msg)

let repair_tool_call_pairs_with_stats
    mode
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let reorder_for_pairing = mode.drop_dangling_uses && mode.drop_orphan_results in
  let append_repaired acc stats msg content =
    match repaired_message_opt msg stats content with
    | None -> acc
    | Some repaired -> repaired :: acc
  in
  let append_filtered_group_message
      allowed_tool_use_ids
      matched_tool_result_ids
      seen_tool_result_ids
      (acc, acc_stats)
      msg =
    let content, stats =
      filter_group_message_content
        mode
        ~allowed_tool_use_ids
        ~matched_tool_result_ids
        ~seen_tool_result_ids
        msg
    in
    ( append_repaired acc stats msg content
    , add_tool_pair_repair_stats acc_stats stats )
  in
  let rec loop acc_stats acc = function
    | [] -> List.rev acc, acc_stats
    | msg :: rest ->
        let tool_use_ids = tool_use_ids_of_message msg in
        if tool_use_ids <> []
        then
          let original_group, result_group, remainder_group, rest =
            split_tool_result_group rest
          in
          let matched_tool_result_ids =
            tool_result_ids_of_message msg
            @ List.concat_map tool_result_ids_of_message result_group
          in
          let seen_tool_result_ids = ref [] in
          let current_content, current_stats =
            filter_group_message_content
              mode
              ~allowed_tool_use_ids:tool_use_ids
              ~matched_tool_result_ids
              ~seen_tool_result_ids
              msg
          in
          let acc = append_repaired acc current_stats msg current_content in
          let acc_stats =
            add_tool_pair_repair_stats acc_stats current_stats
          in
          let group =
            if reorder_for_pairing
            then
              order_tool_result_group_by_tool_use_ids tool_use_ids result_group
              @ remainder_group
            else original_group
          in
          let acc, acc_stats =
            List.fold_left
              (append_filtered_group_message
                 tool_use_ids
                 matched_tool_result_ids
                 seen_tool_result_ids)
              (acc, acc_stats)
              group
          in
          loop acc_stats acc rest
        else if has_tool_result_block msg
                || (mode.drop_dangling_uses
                    && msg.role <> Agent_sdk.Types.Assistant
                    && has_tool_use_block msg)
        then
          let content, stats = filter_orphan_result_message_content mode msg in
          let acc = append_repaired acc stats msg content in
          loop (add_tool_pair_repair_stats acc_stats stats) acc rest
        else
          loop acc_stats (msg :: acc) rest
  in
  loop empty_tool_pair_repair_stats [] messages

let repair_dangling_tool_use_messages_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  repair_tool_call_pairs_with_stats
    { drop_dangling_uses = true; drop_orphan_results = false }
    messages

let repair_dangling_tool_use_messages messages =
  fst (repair_dangling_tool_use_messages_with_stats messages)

let repair_orphan_tool_result_messages_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  repair_tool_call_pairs_with_stats
    { drop_dangling_uses = false; drop_orphan_results = true }
    messages

let repair_orphan_tool_result_messages messages =
  fst (repair_orphan_tool_result_messages_with_stats messages)

let repair_broken_tool_call_pairs_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  repair_tool_call_pairs_with_stats
    { drop_dangling_uses = true; drop_orphan_results = true }
    messages

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

let deserialize_context ~eio (s : string) ~max_tokens : working_context =
  let json = Yojson.Safe.from_string s in
  let system_prompt = (match Json_util.assoc_member_opt "system_prompt" json with Some (`String s) -> s | _ -> "") in
  let messages =
    (match Json_util.assoc_member_opt "messages" json with Some (`List l) -> l | _ -> []) |> List.map message_of_json
    |> repair_broken_tool_call_pairs
  in
  let _legacy_token_count = Json_util.get_int json "token_count" in
  let context = Agent_sdk.Context.create ~eio () in
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

type checkpoint_sanitize_stats = {
  dropped_messages : int;
  dropped_blocks : int;
  dropped_chars : int;
  truncated_blocks : int;
  truncated_chars : int;
  tool_pair_repair : tool_pair_repair_stats;
}

let empty_checkpoint_sanitize_stats =
  {
    dropped_messages = 0;
    dropped_blocks = 0;
    dropped_chars = 0;
    truncated_blocks = 0;
    truncated_chars = 0;
    tool_pair_repair = empty_tool_pair_repair_stats;
  }

let checkpoint_sanitize_changed (stats : checkpoint_sanitize_stats) : bool =
  stats.dropped_messages > 0
  || stats.dropped_blocks > 0
  || stats.dropped_chars > 0
  || stats.truncated_blocks > 0
  || stats.truncated_chars > 0
  || tool_pair_repair_stats_changed stats.tool_pair_repair
