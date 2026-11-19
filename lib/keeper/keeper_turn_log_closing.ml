module Head = Keeper_turn_log_head
module Checkpoint = Keeper_checkpoint_store

type not_closed =
  | Head_unread of Keeper_checkpoint_store_decode.checkpoint_load_error
  | History_unread of Checkpoint.Saved_history.ref_error
  | Save_not_installed of Checkpoint.checkpoint_cas_error

type t =
  | Nothing_open
  | Closed_open of { messages : int }
  | Not_closed of not_closed

let close_open (place : Keeper_turn_log_recorder.place) =
  match Head.read ~session_dir:place.session_dir ~session_id:place.session_id with
  | Error error -> Not_closed (Head_unread error)
  | Ok { open_messages = 0; closed_messages = (_ : int); covered = (_ : Keeper_turn_log_marks.covered) }
    -> Nothing_open
  | Ok { open_messages; closed_messages = (_ : int); covered = (_ : Keeper_turn_log_marks.covered) }
    ->
    (match
       Checkpoint.saved_history_of_ref
         (Checkpoint.load_agent_core_with_ref ~session_dir:place.session_dir
            ~session_id:place.session_id)
     with
     | Error error -> Not_closed (History_unread error)
     | Ok (Checkpoint.Saved_history.Superseded { expected = (_ : int); got = (_ : int) }) ->
       Nothing_open
     | Ok (Checkpoint.Saved_history.Read (checkpoint, expected_source_ref)) ->
       (match
          Checkpoint.save_agent_core_if_source ~session_dir:place.session_dir
            ~expected_source_ref ~boundary:Agent_core.Checkpoint_objects.Turn_closes checkpoint
        with
        | Checkpoint.Installed (_ : Checkpoint.installed_checkpoint) ->
          Closed_open { messages = open_messages }
        | Checkpoint.Not_installed { cause; auxiliary = (_ : Checkpoint.checkpoint_installation_auxiliary list) }
          -> Not_closed (Save_not_installed cause)))
;;

let not_closed_to_string = function
  | Head_unread error -> Keeper_checkpoint_store_session.checkpoint_load_error_to_string error
  | History_unread error -> Checkpoint.saved_history_ref_error_to_string error
  | Save_not_installed (_ : Checkpoint.checkpoint_cas_error) -> "the closing save was not installed"
;;
