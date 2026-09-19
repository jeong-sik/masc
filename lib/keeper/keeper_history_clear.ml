(* Emptying a keeper's saved history. See the interface for the contract. *)

type outcome =
  | Cleared of
      { cleared_message_count : int
      ; marker : (unit, string) result
      }
  | Superseded of
      { incoming_turn_count : int
      ; known_turn_count : int
      }
  | Save_unconfirmed of { detail : string }

let kept_messages ~preserve_system (messages : Agent_core.Types.message list) =
  if preserve_system
  then
    List.filter
      (fun (message : Agent_core.Types.message) ->
         match message.role with
         | Agent_core.Types.System -> true
         | Agent_core.Types.User | Agent_core.Types.Assistant | Agent_core.Types.Tool ->
           false)
      messages
  else []
;;

(* Called only from the [Saved] arm of [clear]: the line states a save that
   already happened. *)
let append_marker ~keepers_dir ~keeper_name ~trace_id =
  let record : Keeper_turn_boundaries.record =
    { recorded_at = Time_compat.now ()
    ; event = Keeper_turn_boundaries.History_empty { trace_id }
    }
  in
  match Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:keeper_name record with
  | Ok () -> Ok ()
  | Error error -> Error (Keeper_turn_boundaries.append_error_to_string error)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
;;

let clear
      ~keepers_dir
      ~runtime_id
      ~keeper_name
      ~(session : Keeper_context_core.session_context)
      ~preserve_system
      (ctx : Keeper_context_core.working_context)
  =
  let existing = Keeper_context_core.messages_of_context ctx in
  let kept = kept_messages ~preserve_system existing in
  let emptied : Keeper_context_core.working_context =
    { Keeper_types.checkpoint =
        { (Keeper_context_core.checkpoint_of_context ctx) with
          Agent_core.Checkpoint.messages = kept
        }
    }
  in
  match
    Keeper_context_core.save_agent_core_checkpoint_classified
      ~runtime_id
      ~keeper_name
      ~session
      ~agent_name:keeper_name
      ~ctx:emptied
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Save_unconfirmed { detail = Printexc.to_string exn }
  | Ok (_checkpoint, Keeper_checkpoint_store.Saved _) ->
    Cleared
      { cleared_message_count = List.length existing - List.length kept
      ; marker =
          append_marker
            ~keepers_dir
            ~keeper_name
            ~trace_id:session.Keeper_types.session_id
      }
  | Ok
      ( _checkpoint
      , Keeper_checkpoint_store.Stale_noop { incoming_turn_count; known_turn_count } ) ->
    Superseded { incoming_turn_count; known_turn_count }
  | Error error ->
    Save_unconfirmed
      { detail =
          Keeper_context_core.checkpoint_write_error_to_string
            ~persistence_error_to_string:Fun.id
            error
      }
;;
