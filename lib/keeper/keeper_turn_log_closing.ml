module Objects = Agent_core.Checkpoint_objects
module Checkpoint = Keeper_checkpoint_store
module Decode = Keeper_checkpoint_store_decode

type not_closed =
  | Head_unread of Decode.checkpoint_load_error
  | Open_turn_unread of Objects.load_error
  | Save_not_installed of Checkpoint.checkpoint_cas_error

type t =
  | Nothing_open
  | Closed_open of { messages : int }
  | Not_closed of not_closed

(* The head names the open messages and their objects hold their bytes, so
   the turn closes without reading or decoding the history before it: the
   cost follows the open turn, not the history (RFC
   librarian-call-only-proposes §5.2). *)
let close_open (place : Keeper_turn_log_recorder.place) =
  let canonical_path =
    Keeper_checkpoint_store_history_files.agent_core_checkpoint_path
      ~session_dir:place.session_dir ~session_id:place.session_id
  in
  match Keeper_checkpoint_store_canonical.known_canonical ~canonical_path with
  (* The two a turn starts fresh from, as the turn log's head read counts
     them ({!Keeper_turn_log_head.read}). *)
  | Ok None | Error Decode.Not_found | Error (Decode.Superseded_version _) -> Nothing_open
  | Error
      (( Decode.Store_error _
       | Decode.Parse_error _
       | Decode.Newer_version _
       | Decode.Io_error _
       | Decode.Read_failed _
       | Decode.Agent_core_error _
       | Decode.Objects_invalid _ ) as error) -> Not_closed (Head_unread error)
  | Ok (Some known) ->
    (match
       Objects.close_open_turn
         ~read_object:(Keeper_checkpoint_object_store.read ~session_dir:place.session_dir)
         known.known_head
     with
     | Error error -> Not_closed (Open_turn_unread error)
     | Ok None -> Nothing_open
     | Ok (Some closing) ->
       (match
          Checkpoint.close_open_turn_if_source ~session_dir:place.session_dir known closing
        with
        | Checkpoint.Installed (_ : Checkpoint.installed_checkpoint) ->
          Closed_open { messages = List.length known.known_head.history.open_messages }
        | Checkpoint.Not_installed { cause; auxiliary = (_ : Checkpoint.checkpoint_installation_auxiliary list) }
          -> Not_closed (Save_not_installed cause)))
;;

let not_closed_to_string = function
  | Head_unread error -> Keeper_checkpoint_store_session.checkpoint_load_error_to_string error
  | Open_turn_unread error ->
    "the open messages could not be read: " ^ Objects.load_error_to_string error
  | Save_not_installed error ->
    "the closing save was not installed: " ^ Checkpoint.checkpoint_cas_error_to_string error
;;
