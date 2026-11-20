module Log = Keeper_turn_log
module Store = Keeper_turn_log_store
module Scan = Private_jsonl_scan

type unread_lines =
  | No_reset
  | Reset_at of { offset : int }
  | Not_scanned of { detail : string }

type unresolved =
  | Other_trace of { covered : string }
  | History_shorter of
      { closed_messages : int
      ; in_hand : int
      }
  | Reset_unread of { offset : int }
  | Turn_log_unread of { detail : string }

type place =
  | Covered of { end_atom : int }
  | Nothing_read
  | Front_unresolved of unresolved

type t =
  { place : place
  ; working_state : string option
  }

(* Whether the line at [line] is the unit the view names, or one after it. *)
type scanning =
  | At_the_read_unit
  | After_the_read_unit

(* A [Reset] starts the count of closed messages again: a clear and a head
   found below the last mark leave none closed, and a purge that drops what
   follows a break leaves fewer. The view's count was taken before it. A unit
   read in part is a [Reset] not read to its end. *)
let read_unread_lines ~turns_path ~line ~(within : Librarian_log.within) =
  let not_scanned fmt = Printf.ksprintf (fun detail -> Not_scanned { detail }) fmt in
  let step scanning (scanned : Store.scanned) =
    match scanned.line with
    | Error (_ : Store.undecodable) ->
      Scan.Stop (not_scanned "the turn log line at byte %d does not decode" scanned.at)
    | Ok read ->
      (match scanning, read, within with
       | At_the_read_unit, Log.Closed _, (Librarian_log.Whole | Librarian_log.Item _)
       | At_the_read_unit, Log.Reset _, Librarian_log.Whole ->
         Scan.Continue After_the_read_unit
       | At_the_read_unit, Log.Reset _, Librarian_log.Item (_ : Librarian_unit.item_name) ->
         Scan.Stop (Reset_at { offset = scanned.at })
       | ( At_the_read_unit
         , (Log.Log_started _ | Log.Opened _)
         , (Librarian_log.Whole | Librarian_log.Item _) ) ->
         Scan.Stop (not_scanned "the turn log line at byte %d ends no unit" scanned.at)
       | After_the_read_unit, Log.Reset _, (Librarian_log.Whole | Librarian_log.Item _) ->
         Scan.Stop (Reset_at { offset = scanned.at })
       | ( After_the_read_unit
         , (Log.Log_started _ | Log.Opened _ | Log.Closed _)
         , (Librarian_log.Whole | Librarian_log.Item _) ) ->
         Scan.Continue After_the_read_unit)
  in
  if line < 0
  then not_scanned "the read position is byte %d" line
  else (
    match Store.fold_from turns_path ~from:line ~init:At_the_read_unit ~f:step with
    | Ok (Scan.Stopped found) -> found
    | Ok (Scan.Reached_end After_the_read_unit) -> No_reset
    | Ok (Scan.Reached_end At_the_read_unit) -> not_scanned "the turn log has no line at byte %d" line
    | Error (Scan.Not_a_row_start { from; length }) ->
      not_scanned "byte %d starts no line of the turn log, which is %d bytes long" from length
    | Error (Scan.Scan_failed error) -> Not_scanned { detail = Scan.error_to_string error })
;;

(* The same reading as the turn boundary's ([Keeper_turn_driver_try_provider.
   turn_starts]): a count of closed messages becomes the atom that opens at or
   after it, once the history is known to hold that many messages of the same
   trace. How far into its last unit the writer read ([Through.within]) is
   already in [covered], which is where the stores ended at that position.
   The turn log is scanned last, and only for a view the two cheap checks
   pass. *)
let place_of ~trace_id ~messages ~unread_lines ~covers_through ~(covered : Log.mark) =
  match (covers_through : Librarian_log.position) with
  | Librarian_log.Before_first -> Nothing_read
  | Librarian_log.Through { line; within } ->
    let in_hand = List.length messages in
    if not (String.equal covered.trace trace_id)
    then Front_unresolved (Other_trace { covered = covered.trace })
    else if in_hand < covered.closed_messages
    then Front_unresolved (History_shorter { closed_messages = covered.closed_messages; in_hand })
    else (
      match (unread_lines ~line ~within : unread_lines) with
      | Reset_at { offset } -> Front_unresolved (Reset_unread { offset })
      | Not_scanned { detail } -> Front_unresolved (Turn_log_unread { detail })
      | No_reset ->
        Covered
          { end_atom =
              Runtime_model_input_tail_window.first_atom_at_or_after
                messages
                ~message_index:covered.closed_messages
          })
;;

let of_view
      ~trace_id
      ~messages
      ~unread_lines
      ({ covers_through; covered; working_state } : Librarian_writer.view)
  =
  { place = place_of ~trace_id ~messages ~unread_lines ~covers_through ~covered; working_state }
;;

let read ~(config : Workspace.config) ~keeper_name ~trace_id ~messages =
  match Keeper_memory_writers.find ~base_path:config.base_path with
  | None -> Error `Writers_not_started
  | Some writers ->
    (match Librarian_writers.view writers keeper_name with
     | Ok view ->
       let turns_path =
         Store.path_for_keepers_dir
           ~keepers_dir:(Workspace.keepers_runtime_dir config)
           ~keeper_id:keeper_name
       in
       Ok (of_view ~trace_id ~messages ~unread_lines:(read_unread_lines ~turns_path) view)
     | Error ((`Booting | `Stopped (_ : Librarian_store.stop) | `No_writer) as no_view) ->
       Error no_view)
;;
