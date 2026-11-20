module Store = Keeper_turn_log_store
module Recorder = Keeper_turn_log_recorder

let first_line_written config keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail -> Error ("the Keeper's durable metadata was not read: " ^ detail)
  | Ok None -> Error "the Keeper has no durable metadata to name its stores"
  | Ok (Some meta) ->
    (match
       Recorder.record_start ~at:(Time_compat.now ()) ~new_log_id:(Keeper_turn_log.Log_id.fresh ())
         (Keeper_turn_log_process_start.place_of config meta)
     with
     | Ok (Recorder.Appended _ | Nothing_to_append) -> Ok ()
     | Error error -> Error (Recorder.not_recorded_to_string error))
;;

let step config keeper_name =
  let path =
    Store.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
  in
  match Store.read_start path with
  | Ok (Some (_ : Store.start)) -> Ok ()
  | Ok None -> first_line_written config keeper_name
  | Error error ->
    Log.Keeper.warn ~keeper_name
      "librarian store start: the turn log's first line was not read (%s); the boot reads the log"
      (Recorder.not_recorded_to_string (Recorder.Tail_unread error));
    Ok ()
;;

(* A store that raised is a first line not written: the writer stops with
   the text instead of ending its fiber. *)
let run config keeper_name =
  match step config keeper_name with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
;;
