(** Keeper_coordination — Coord presence, model selection, and room cursor management.

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

let keeper_action_kind_of_tool_names =
  Keeper_exec_context.keeper_action_kind_of_tool_names
;;

let effective_model_labels_for_turn (m : keeper_meta) : string list =
  Keeper_exec_context.effective_model_labels_for_turn m
;;

let room_cursor_for meta room_id =
  meta.last_seen_seq_by_room
  |> List.find_map (fun (rid, seq) -> if rid = room_id then Some seq else None)
  |> Option.value ~default:0
;;

let set_room_cursor meta room_id seq =
  let kept = meta.last_seen_seq_by_room |> List.filter (fun (rid, _) -> rid <> room_id) in
  { meta with last_seen_seq_by_room = dedupe_keep_order ((room_id, seq) :: kept) }
;;

let room_ids_for_meta _config (_meta : keeper_meta) : string list = [ "default" ]
let ensure_keeper_room_presence = Keeper_exec_context.ensure_keeper_room_presence
