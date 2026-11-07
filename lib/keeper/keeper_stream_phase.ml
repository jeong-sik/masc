(* See keeper_stream_phase.mli. *)

type t =
  | Accepting_content
  | Stop_reason_seen of Agent_core.Types.stop_reason
  | Message_stopped

let admits_block_open_or_delta = function
  | Accepting_content -> true
  | Stop_reason_seen _ | Message_stopped -> false
;;

let admits_block_stop = function
  | Accepting_content | Stop_reason_seen _ -> true
  | Message_stopped -> false
;;

type stop_reason_event =
  | Stop_reason_unchanged
  | Stop_reason_first of Agent_core.Types.stop_reason
  | Stop_reason_conflict

let on_stop_reason t stop_reason =
  match t, stop_reason with
  | Accepting_content, None -> Stop_reason_unchanged
  | Accepting_content, Some stop_reason -> Stop_reason_first stop_reason
  | Stop_reason_seen _, None -> Stop_reason_unchanged
  | Stop_reason_seen recorded, Some replay when recorded = replay ->
    Stop_reason_unchanged
  | Stop_reason_seen _, Some _ | Message_stopped, None | Message_stopped, Some _ ->
    Stop_reason_conflict
;;

type message_stop_event =
  | Message_stop_replayed
  | Message_stop_without_reason
  | Message_stop_after_reason

let on_message_stop = function
  | Message_stopped -> Message_stop_replayed
  | Accepting_content -> Message_stop_without_reason
  | Stop_reason_seen _ -> Message_stop_after_reason
;;
