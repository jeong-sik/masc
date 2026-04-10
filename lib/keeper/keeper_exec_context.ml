(** Keeper_exec_context — facade that re-exports from domain sub-modules.

    Working context types live in {!Keeper_types}.
    Pure context operations are in {!Keeper_context_core}.
    Compaction policy is in {!Keeper_compact_policy}.
    Handoff rollover is in {!Keeper_rollover}.
    Post-turn lifecycle is in {!Keeper_post_turn}.

    This module preserves the original public API so that callers
    do not need updating. *)

open Keeper_types

let contains_ci = String_util.contains_substring_ci

(* ================================================================ *)
(* Re-export from Keeper_context_core                                *)
(* ================================================================ *)

type working_context = Keeper_types.working_context
type checkpoint = Keeper_types.checkpoint
type session_context = Keeper_types.session_context

let text_of_message = Keeper_context_core.text_of_message
let msg_tokens = Keeper_context_core.msg_tokens
let count_tokens = Keeper_context_core.count_tokens
let token_count = Keeper_context_core.token_count
let message_count = Keeper_context_core.message_count
let context_ratio = Keeper_context_core.context_ratio
let create = Keeper_context_core.create
let set_system_prompt = Keeper_context_core.set_system_prompt
let append = Keeper_context_core.append
let append_many = Keeper_context_core.append_many
let sync_oas_context = Keeper_context_core.sync_oas_context
let role_to_string = Keeper_context_core.role_to_string
let role_of_string = Keeper_context_core.role_of_string
let message_to_json = Keeper_context_core.message_to_json
let message_of_json = Keeper_context_core.message_of_json
let serialize_context = Keeper_context_core.serialize_context
let deserialize_context = Keeper_context_core.deserialize_context
let context_to_json = Keeper_context_core.context_to_json
let create_checkpoint = Keeper_context_core.create_checkpoint
let create_session = Keeper_context_core.create_session
let persist_message = Keeper_context_core.persist_message

let timed = Keeper_context_core.timed
let zero_usage = Keeper_context_core.zero_usage
let usage_of_response = Keeper_context_core.usage_of_response
let total_tokens = Keeper_context_core.total_tokens

let save_session_checkpoint = Keeper_context_core.save_session_checkpoint

let log_keeper_exn = Keeper_context_core.log_keeper_exn
let checkpoint_max_tokens = Keeper_context_core.checkpoint_max_tokens
let context_of_oas_checkpoint = Keeper_context_core.context_of_oas_checkpoint
let checkpoint_model_of_meta = Keeper_context_core.checkpoint_model_of_meta
let save_oas_checkpoint = Keeper_context_core.save_oas_checkpoint
let load_context_from_checkpoint = Keeper_context_core.load_context_from_checkpoint
let save_checkpoint = Keeper_context_core.save_checkpoint

let restore_checkpoint = Keeper_context_core.restore_checkpoint
let load_latest_checkpoint = Keeper_context_core.load_latest_checkpoint
let context_of_legacy_checkpoint = Keeper_context_core.context_of_legacy_checkpoint
let checkpoint_generation = Keeper_context_core.checkpoint_generation

(* ================================================================ *)
(* Re-export from Keeper_rollover                                    *)
(* ================================================================ *)

type handoff_rollover = Keeper_rollover.handoff_rollover = {
  updated_meta : keeper_meta;
  handoff_json : Yojson.Safe.t option;
  context_ratio : float;
  context_tokens : int;
  context_max : int;
  message_count : int;
}

let maybe_rollover_oas_handoff = Keeper_rollover.maybe_rollover_oas_handoff

(* ================================================================ *)
(* Re-export from Keeper_compact_policy                              *)
(* ================================================================ *)

let compaction_policy_of_keeper = Keeper_compact_policy.compaction_policy_of_keeper
let compact_if_needed = Keeper_compact_policy.compact_if_needed

(* ================================================================ *)
(* Re-export from Keeper_post_turn                                   *)
(* ================================================================ *)

type compaction_event = Keeper_post_turn.compaction_event = {
  applied : bool;
  trigger : string option;
  decision : string;
  before_tokens : int;
  after_tokens : int;
  saved_tokens : int;
}

type post_turn_lifecycle = Keeper_post_turn.post_turn_lifecycle = {
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

type overflow_retry_recovery = Keeper_post_turn.overflow_retry_recovery = {
  checkpoint : Agent_sdk.Checkpoint.t;
  compaction : compaction_event;
  turn_generation : int;
}

let apply_post_turn_lifecycle = Keeper_post_turn.apply_post_turn_lifecycle
let recover_latest_checkpoint_for_overflow_retry =
  Keeper_post_turn.recover_latest_checkpoint_for_overflow_retry

(* ================================================================ *)
(* Remaining functions (not extracted — small utilities)              *)
(* ================================================================ *)

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
  (* provider filtering now handled by OAS cascade via ~provider_filter *)
  let configured =
    Oas_model_resolve.models_of_cascade_name m.cascade_name
  in
  let configured_ids =
    try
      Llm_provider.Cascade_config.parse_model_strings configured
      |> List.map (fun (c : Llm_provider.Provider_config.t) -> String.trim c.model_id)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
  in
  match String.trim (Keeper_exec_status.active_model_of_meta m) with
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

let keeper_room_capabilities (meta : keeper_meta) =
  let preset_cap =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some p -> [ "preset:" ^ Keeper_types.tool_preset_to_string p ]
    | None -> []
  in
  [ "keeper" ] @ preset_cap

let keeper_room_capabilities_need_sync config (meta : keeper_meta) capabilities =
  let agent_file =
    Filename.concat (Room.agents_dir config)
      (Room.safe_filename meta.agent_name ^ ".json")
  in
  if not (Sys.file_exists agent_file) then
    true
  else
    try
      let json = Room.read_json config agent_file in
      match Types.agent_of_yojson json with
      | Ok agent -> agent.capabilities <> capabilities
      | Error _ -> true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> true

let ensure_keeper_room_presence config (meta : keeper_meta) : keeper_meta =
  let room_ids = room_ids_for_meta config meta in
  let capabilities = keeper_room_capabilities meta in
  let successful_rooms =
    List.fold_left
      (fun acc room_id ->
        try
          let joined =
            Room.is_agent_joined config ~agent_name:meta.agent_name
          in
          if not joined
          then begin
            Room.ensure_room_bootstrap config room_id;
            ignore
              (Room.join config ~agent_name:meta.agent_name
                 ~capabilities ())
          end;
          if joined && keeper_room_capabilities_need_sync config meta capabilities
          then
            ignore
              (Room.update_agent_r config ~agent_name:meta.agent_name
                 ~capabilities ());
          ignore
            (Room.heartbeat config ~agent_name:meta.agent_name);
          room_id :: acc
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Keeper_context_core.log_keeper_exn ~label:(Printf.sprintf "room presence sync failed for %s in %s" meta.name room_id) exn;
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
