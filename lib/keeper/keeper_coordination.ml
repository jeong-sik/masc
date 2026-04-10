(** Keeper_coordination — Room presence, model selection, and room cursor management.

    Checkpoint/compaction/logging functions are delegated to {!Keeper_exec_context}
    (single source of truth) and re-exported here for backward compatibility
    with [include Keeper_coordination] in {!Keeper_execution}. *)

open Keeper_types

(* ================================================================ *)
(* Re-exports from Keeper_exec_context — single source of truth     *)
(* ================================================================ *)

let log_keeper_exn = Keeper_exec_context.log_keeper_exn
let load_context_from_checkpoint = Keeper_exec_context.load_context_from_checkpoint
let save_checkpoint = Keeper_exec_context.save_checkpoint
let compaction_policy_of_keeper = Keeper_exec_context.compaction_policy_of_keeper
let compact_if_needed = Keeper_exec_context.compact_if_needed
let generate_trace_id = Keeper_exec_context.generate_trace_id
let keeper_board_write_tool_names = Keeper_exec_context.keeper_board_write_tool_names
let keeper_write_done = Keeper_exec_context.keeper_write_done
let keeper_action_kind_of_tool_names = Keeper_exec_context.keeper_action_kind_of_tool_names

let effective_model_labels_for_turn (m : keeper_meta) : string list =
  Keeper_exec_context.effective_model_labels_for_turn m

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
            Room.ensure_room_bootstrap config;
            let preset_cap = match Keeper_types.tool_access_preset meta.tool_access with
              | Some p -> ["preset:" ^ Keeper_types.tool_preset_to_string p]
              | None -> []
            in
            ignore
              (Room.join config ~agent_name:meta.agent_name
                 ~capabilities:(["keeper"] @ preset_cap) ())
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
