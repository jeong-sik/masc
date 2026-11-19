module Turn_log = Keeper_turn_log
module Store = Keeper_turn_log_store
module Writer = Keeper_turn_log_writer
module Recorder = Keeper_turn_log_recorder
module Closing = Keeper_turn_log_closing

type closing =
  | No_open_turn
  | Closing of Keeper_turn_log_closing.t

type outcome =
  | No_metadata
  | Metadata_unread of string
  | Log_unread of Store.read_error
  | Stepped of
      { closing : closing
      ; line : (Recorder.recorded, Recorder.not_recorded) result
      }
  | Raised of string

type report =
  { examined : int
  ; closed_open : int
  ; failed : int
  ; outcomes : (string * outcome) list
  }

let step ~at ~new_log_id (place : Recorder.place) =
  let path =
    Store.path_for_keepers_dir ~keepers_dir:place.keepers_dir ~keeper_id:place.keeper_name
  in
  match Store.read_tail path with
  | Error error -> Log_unread error
  | Ok tail ->
    let closing =
      match tail with
      | Store.Nothing_written | Written { open_turn = None; _ } -> No_open_turn
      | Written { open_turn = Some (_ : Store.open_turn); _ } -> Closing (Closing.close_open place)
    in
    Stepped { closing; line = Recorder.record ~at ~new_log_id place Writer.Process_start }
;;

let place_of (config : Workspace.config) (meta : Keeper_meta_contract.keeper_meta) : Recorder.place =
  let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  { keepers_dir = Workspace.keepers_runtime_dir config
  ; base_path = config.base_path
  ; keeper_name = meta.name
  ; session_dir = Keeper_types_support.keeper_session_dir config session_id
  ; session_id
  }
;;

let keeper config name =
  match Keeper_meta_store.read_meta config name with
  | Error detail -> Metadata_unread detail
  | Ok None -> No_metadata
  | Ok (Some meta) ->
    (match
       step ~at:(Time_compat.now ()) ~new_log_id:(Turn_log.Log_id.fresh ()) (place_of config meta)
     with
     | outcome -> outcome
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn -> Raised (Printexc.to_string exn))
;;

let line_site = "process_start"

let line_not_written ~keeper_name detail =
  Log.Keeper.error ~keeper_name "turn log line not written at process start: %s" detail;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnLogAppendFailures)
    ~labels:[ "keeper", keeper_name; "site", line_site ]
    ()
;;

(* Whether the Keeper counts as failed in the report. *)
let report_outcome keeper_name = function
  | No_metadata -> false
  | Metadata_unread detail ->
    Log.Keeper.error ~keeper_name "turn log process start: durable metadata unavailable: %s" detail;
    true
  | Log_unread error ->
    line_not_written ~keeper_name (Recorder.not_recorded_to_string (Recorder.Tail_unread error));
    true
  | Raised detail ->
    line_not_written ~keeper_name detail;
    true
  | Stepped { closing; line } ->
    let not_closed =
      match closing with
      | No_open_turn | Closing Nothing_open -> false
      | Closing (Closed_open { messages }) ->
        Log.Keeper.warn ~keeper_name
          "turn log process start: closed %d open messages of the turn the process left open"
          messages;
        false
      | Closing (Not_closed error) ->
        Log.Keeper.error ~keeper_name
          "turn log process start: open messages of the turn the process left open were not \
           closed: %s"
          (Closing.not_closed_to_string error);
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string TurnLogOpenCloseFailures)
          ~labels:[ "keeper", keeper_name ]
          ();
        true
    in
    let not_written =
      match line with
      | Ok (Recorder.Appended _ | Nothing_to_append) -> false
      | Error error ->
        line_not_written ~keeper_name (Recorder.not_recorded_to_string error);
        true
    in
    not_closed || not_written
;;

let run config =
  let report =
    List.fold_left
      (fun report name ->
         let outcome = keeper config name in
         let failed = report_outcome name outcome in
         { examined = report.examined + 1
         ; closed_open =
             (match outcome with
              | Stepped { closing = Closing (Closed_open { messages = (_ : int) }); _ } ->
                report.closed_open + 1
              | Stepped { closing = No_open_turn | Closing (Nothing_open | Not_closed _); _ }
              | No_metadata | Metadata_unread _ | Log_unread _ | Raised _ -> report.closed_open)
         ; failed = (if failed then report.failed + 1 else report.failed)
         ; outcomes = (name, outcome) :: report.outcomes
         })
      { examined = 0; closed_open = 0; failed = 0; outcomes = [] }
      (Keeper_meta_store.persisted_keeper_names config)
  in
  { report with outcomes = List.rev report.outcomes }
;;
