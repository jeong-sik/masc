type unresolved =
  | Other_trace of { covered : string }
  | History_shorter of
      { closed_messages : int
      ; in_hand : int
      }

type place =
  | Covered of { end_atom : int }
  | Nothing_read
  | Front_unresolved of unresolved

type t =
  { place : place
  ; working_state : string option
  }

(* The same reading as the turn boundary's ([Keeper_turn_driver_try_provider.
   turn_starts]): a count of closed messages becomes the atom that opens at or
   after it, once the history is known to hold that many messages of the same
   trace. How far into its last unit the writer read ([Through.within]) is
   already in [covered], which is where the stores ended at that position. *)
let place_of ~trace_id ~messages ~covers_through ~(covered : Keeper_turn_log.mark) =
  match (covers_through : Librarian_log.position) with
  | Librarian_log.Before_first -> Nothing_read
  | Librarian_log.Through { line = (_ : int); within = (_ : Librarian_log.within) } ->
    let in_hand = List.length messages in
    if not (String.equal covered.trace trace_id)
    then Front_unresolved (Other_trace { covered = covered.trace })
    else if in_hand < covered.closed_messages
    then Front_unresolved (History_shorter { closed_messages = covered.closed_messages; in_hand })
    else
      Covered
        { end_atom =
            Runtime_model_input_tail_window.first_atom_at_or_after
              messages
              ~message_index:covered.closed_messages
        }
;;

let of_view ~trace_id ~messages ({ covers_through; covered; working_state } : Librarian_writer.view) =
  { place = place_of ~trace_id ~messages ~covers_through ~covered; working_state }
;;

let read ~(config : Workspace.config) ~keeper_name ~trace_id ~messages =
  match Keeper_memory_writers.find ~base_path:config.base_path with
  | None -> Error `Writers_not_started
  | Some writers ->
    (match Librarian_writers.view writers keeper_name with
     | Ok view -> Ok (of_view ~trace_id ~messages view)
     | Error ((`Booting | `Stopped (_ : Librarian_store.stop) | `No_writer) as no_view) ->
       Error no_view)
;;
