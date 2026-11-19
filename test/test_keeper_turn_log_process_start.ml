(* The turn log's step of a process start, over persisted Keepers in a real
   workspace (RFC librarian-call-only-proposes §5.2). Histories are written by
   the checkpoint store's own save and the log is read back from its file. *)

open Alcotest
open Masc
module Log = Keeper_turn_log
module Codec = Keeper_turn_log_codec
module Recorder = Keeper_turn_log_recorder
module Writer = Keeper_turn_log_writer
module Start = Keeper_turn_log_process_start
module Objects = Agent_core.Checkpoint_objects

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK -> Unix.unlink path
;;

let with_workspace f () =
  let root = Filename.temp_file "turn-log-process-start-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      remove_tree root)
    (fun () -> f config)
;;

(* A persisted Keeper with an empty session directory, as the turn path
   names its stores. *)
let persisted_keeper config name : Recorder.place =
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
    | Ok meta -> meta
    | Error detail -> failf "keeper meta fixture failed: %s" detail
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let session_id = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id in
  let session_dir = Filename.concat (Keeper_fs.session_base_dir config) session_id in
  Unix.mkdir session_dir 0o700;
  { keepers_dir = Workspace.keepers_runtime_dir config
  ; base_path = config.base_path
  ; keeper_name = name
  ; session_dir
  ; session_id
  }
;;

let message role text : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation
  ; role
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let checkpoint (place : Recorder.place) ~turn_count messages : Agent_core.Checkpoint.t =
  { provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = place.session_id
  ; agent_name = place.keeper_name
  ; model = "test-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; pending_input = None
  ; working_context = None
  }
;;

let save (place : Recorder.place) ~boundary ~turn_count messages =
  match
    Keeper_checkpoint_store.save_agent_core_classified ~session_dir:place.session_dir
      ~history_retained:0 ~boundary (checkpoint place ~turn_count messages)
  with
  | Ok (Keeper_checkpoint_store.Saved _) -> ()
  | Ok (Keeper_checkpoint_store.Stale_noop _) -> failf "save %d was read as stale" turn_count
  | Error detail -> failf "save %d: %s" turn_count detail
;;

let log_id =
  match Log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let record place event = Recorder.record ~at:100.0 ~new_log_id:log_id place event

let must label = function
  | Ok (Recorder.Appended _) -> ()
  | Ok Recorder.Nothing_to_append -> failf "%s: nothing was appended" label
  | Error error -> failf "%s: %s" label (Recorder.not_recorded_to_string error)
;;

let admitted (place : Recorder.place) n =
  let answer =
    record place
      (Writer.Admit
         { turn_ref = Ids.Turn_ref.make ~trace_id:place.session_id ~absolute_turn:n
         ; runtime = "test-runtime"
         ; task = Log.No_task
         ; stimuli = []
         })
  in
  must (Printf.sprintf "admission of turn %d" n) answer;
  Recorder.admitted answer
;;

let finish place admitted ending =
  must "end of the turn" (record place (Writer.Finish { admitted; ending }))
;;

let log_path (place : Recorder.place) =
  Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:place.keepers_dir
    ~keeper_id:place.keeper_name
;;

let log_lines place =
  let path = log_path place in
  if Sys.file_exists path
  then
    List.filter_map
      (fun row ->
         if String.equal row ""
         then None
         else (
           match Codec.of_json (Yojson.Safe.from_string row) with
           | Ok line -> Some line
           | Error error -> fail (Keeper_memory_os_types.wire_error_to_string error)))
      (String.split_on_char '\n' (Fs_compat.load_file path))
  else []
;;

let slices_text slices =
  String.concat ","
    (List.map (fun (slice : Log.slice) -> Printf.sprintf "%d+%d" slice.skip slice.take) slices)
;;

let outcome_text : Log.outcome -> string = function
  | Completed -> "completed"
  | Errored -> "errored"
  | Cancelled -> "cancelled"
  | Save_failed -> "save failed"
  | Stale_save -> "stale save"
  | Close_missing -> "close missing"
  | Process_exited -> "process exited"
;;

(* Messages are written as counts, and a run as skip+take of each bundle. *)
let line_text : Log.line -> string = function
  | Log_started { mark; _ } -> Printf.sprintf "started at %d" mark.closed_messages
  | Opened { turn_ref; baseline; _ } ->
    Printf.sprintf "opened %d at %d" (Ids.Turn_ref.absolute_turn turn_ref) baseline.closed_messages
  | Closed { outcome; after; unattributed; own; _ } ->
    Printf.sprintf "closed %s at %d, before [%s], own [%s]" (outcome_text outcome)
      after.closed_messages (slices_text unattributed) (slices_text own)
  | Reset { before; after; _ } ->
    Printf.sprintf "reset %d to %d" before.closed_messages after.closed_messages
;;

let log_text place = String.concat "\n" (List.map line_text (log_lines place))

let open_messages (place : Recorder.place) =
  match
    Keeper_turn_log_head.read ~session_dir:place.session_dir ~session_id:place.session_id
  with
  | Ok head -> head.open_messages
  | Error error -> fail (Keeper_checkpoint_store_session.checkpoint_load_error_to_string error)
;;

let closing_text : Start.closing -> string = function
  | No_open_turn -> "no open turn"
  | Closing Nothing_open -> "nothing open"
  | Closing (Closed_open { messages }) -> Printf.sprintf "closed %d" messages
  | Closing (Not_closed (Head_unread _)) -> "not closed: head unread"
  | Closing (Not_closed (History_unread _)) -> "not closed: history unread"
  | Closing (Not_closed (Save_not_installed _)) -> "not closed: save not installed"
;;

let line_result_text = function
  | Ok (Recorder.Appended { lines; _ }) -> String.concat " / " (List.map line_text lines)
  | Ok Recorder.Nothing_to_append -> "nothing to append"
  | Error error -> "not written: " ^ Recorder.not_recorded_to_string error
;;

let outcome_text_of : Start.outcome -> string = function
  | No_metadata -> "no metadata"
  | Metadata_unread detail -> "metadata unread: " ^ detail
  | Log_unread _ -> "log unread"
  | Raised detail -> "raised: " ^ detail
  | Stepped { closing; line } ->
    Printf.sprintf "%s; %s" (closing_text closing) (line_result_text line)
;;

(* One process start over the workspace's one Keeper. *)
let start ?(failed = 0) ?(closed_open = 0) label config expected =
  let report = Start.run config in
  check int (label ^ ": examined") 1 report.examined;
  check (list string) label [ expected ] (List.map (fun (_, o) -> outcome_text_of o) report.outcomes);
  check int (label ^ ": failed") failed report.failed;
  check int (label ^ ": closed open") closed_open report.closed_open
;;

let turn_one = [ message User "a asks 1"; message Assistant "a answers 1" ]

(* Turn 1 from its admission to its end. *)
let run_turn_one place =
  let first = admitted place 1 in
  save place ~boundary:Objects.Turn_closes ~turn_count:1 turn_one;
  finish place first Writer.Completed
;;

let test_first_line =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "first-line" in
  start "the first start" config "no open turn; started at 0";
  start "the next start" config "no open turn; nothing to append";
  check string "the log has its one line" "started at 0" (log_text place)
;;

(* The turn saved on its way and the process went away before its end. The
   step closes what the turn left open, and the turn's end names it. *)
let test_a_turn_the_process_left_open =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "left-open" in
  run_turn_one place;
  let (_ : Writer.admitted) = admitted place 2 in
  save place ~boundary:Objects.Turn_continues ~turn_count:2 (turn_one @ [ message User "a asks 2" ]);
  check int "the turn's message is open" 1 (open_messages place);
  start ~closed_open:1 "the start after the kill" config
    "closed 1; closed process exited at 3, before [], own [0+1]";
  check int "no message is open" 0 (open_messages place);
  check string "the log"
    "started at 0\n\
     opened 1 at 0\n\
     closed completed at 2, before [], own [0+2]\n\
     opened 2 at 2\n\
     closed process exited at 3, before [], own [0+1]"
    (log_text place);
  start "the start after that" config "no open turn; nothing to append"
;;

(* The process went away before the turn saved anything. *)
let test_an_open_turn_that_saved_nothing =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "saved-nothing" in
  run_turn_one place;
  let (_ : Writer.admitted) = admitted place 2 in
  start "the start after the kill" config
    "nothing open; closed process exited at 2, before [], own []"
;;

(* A save that leaves a message open with no turn open in the log: a paused
   turn that will be continued. The step leaves it, and the turn admitted
   next closes it as its own. *)
let test_open_messages_with_no_open_turn_are_left =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "continued" in
  run_turn_one place;
  let waiting = turn_one @ [ message User "a asks 2" ] in
  save place ~boundary:Objects.Turn_continues ~turn_count:2 waiting;
  start "the start" config "no open turn; nothing to append";
  check int "the message is still open" 1 (open_messages place);
  let second = admitted place 2 in
  save place ~boundary:Objects.Turn_closes ~turn_count:2
    (waiting @ [ message Assistant "a answers 2" ]);
  finish place second Writer.Completed;
  check string "the continued turn names the message that was open at its admission"
    "opened 2 at 2\nclosed completed at 4, before [], own [0+2]"
    (String.concat "\n"
       (List.filteri (fun index (_ : string) -> index >= 3)
          (List.map line_text (log_lines place))))
;;

let open_close_failures (place : Recorder.place) =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string TurnLogOpenCloseFailures)
    ~labels:[ "keeper", place.keeper_name ]
    ()
;;

let line_failures (place : Recorder.place) =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string TurnLogAppendFailures)
    ~labels:[ "keeper", place.keeper_name; "site", "process_start" ]
    ()
;;

(* The closing save cannot write its bundle. The start goes on: the turn's
   end is written with nothing of its own, the message stays open, and the
   turn admitted next closes it as its own. *)
let test_a_closing_save_that_fails =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "save-fails" in
  run_turn_one place;
  let (_ : Writer.admitted) = admitted place 2 in
  let waiting = turn_one @ [ message User "a asks 2" ] in
  save place ~boundary:Objects.Turn_continues ~turn_count:2 waiting;
  let objects = Filename.concat place.session_dir Keeper_checkpoint_object_store.dirname in
  let counted = open_close_failures place in
  Unix.chmod objects 0o500;
  Fun.protect
    ~finally:(fun () -> Unix.chmod objects 0o700)
    (fun () ->
       start ~failed:1 "the start after the kill" config
         "not closed: save not installed; closed process exited at 2, before [], own []");
  check (float 0.0) "the failure is counted" (counted +. 1.0) (open_close_failures place);
  check int "the message is still open" 1 (open_messages place);
  let third = admitted place 3 in
  save place ~boundary:Objects.Turn_closes ~turn_count:3
    (waiting @ [ message Assistant "a answers 3" ]);
  finish place third Writer.Completed;
  check string "the next turn names the message as its own"
    "opened 3 at 2\nclosed completed at 4, before [], own [0+2]"
    (String.concat "\n"
       (List.filteri (fun index (_ : string) -> index >= 5)
          (List.map line_text (log_lines place))))
;;

(* A log whose tail does not decode: whether a turn is open is not known, so
   the head is not touched and nothing is written. *)
let test_a_log_that_cannot_be_read =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "log-unread" in
  run_turn_one place;
  let (_ : Writer.admitted) = admitted place 2 in
  save place ~boundary:Objects.Turn_continues ~turn_count:2 (turn_one @ [ message User "a asks 2" ]);
  let path = log_path place in
  let before = Fs_compat.load_file path in
  Fs_compat.save_file path (before ^ "not a line\n");
  let counted = line_failures place in
  start ~failed:1 "the start" config "log unread";
  check int "the message is still open" 1 (open_messages place);
  check string "the log is as it was" (before ^ "not a line\n") (Fs_compat.load_file path);
  check (float 0.0) "and the failure is counted" (counted +. 1.0) (line_failures place)
;;

(* A Keeper file this build does not read as metadata is skipped. *)
let test_a_keeper_with_no_metadata =
  with_workspace
  @@ fun config ->
  let place = persisted_keeper config "no-metadata" in
  let path = Keeper_types_profile.keeper_meta_path config place.keeper_name in
  Fs_compat.save_file path "{}";
  start "the start" config "no metadata";
  check bool "no log is made for it" false (Sys.file_exists (log_path place))
;;

let () =
  run "keeper_turn_log_process_start"
    [ ( "process start"
      , [ test_case "a Keeper with no log gets its first line" `Quick test_first_line
        ; test_case "a turn the process left open" `Quick test_a_turn_the_process_left_open
        ; test_case "an open turn that saved nothing" `Quick
            test_an_open_turn_that_saved_nothing
        ; test_case "open messages with no open turn are left" `Quick
            test_open_messages_with_no_open_turn_are_left
        ; test_case "a closing save that fails" `Quick test_a_closing_save_that_fails
        ; test_case "a log that cannot be read" `Quick test_a_log_that_cannot_be_read
        ; test_case "a Keeper with no metadata" `Quick test_a_keeper_with_no_metadata
        ] )
    ]
;;
