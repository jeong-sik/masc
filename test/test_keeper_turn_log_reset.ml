(* The one way a product path shrinks a Keeper's head, over a real
   workspace (RFC librarian-call-only-proposes §5.2, §5.6): its checks, the
   save that closes open messages, the announced Reset line, then the change.
   Histories are written by the checkpoint store's own save and the log is
   read back from its file. *)

open Alcotest
open Masc
module Log = Keeper_turn_log
module Codec = Keeper_turn_log_codec
module Recorder = Keeper_turn_log_recorder
module Writer = Keeper_turn_log_writer
module Reset = Keeper_turn_log_reset
module Objects = Agent_core.Checkpoint_objects

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK -> Unix.unlink path
;;

let with_keeper name f () =
  let root = Filename.temp_file "turn-log-reset-" "" in
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
    (fun () ->
       let session_id = "reset-session" in
       let session_dir = Filename.concat (Keeper_fs.session_base_dir config) session_id in
       Unix.mkdir session_dir 0o700;
       f
         { Recorder.keepers_dir = Workspace.keepers_runtime_dir config
         ; base_path = config.base_path
         ; keeper_name = name
         ; session_dir
         ; session_id
         })
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
  | Reset { cause; before; after; closed_before; _ } ->
    Printf.sprintf "reset %s %d to %d, named [%s]"
      (match cause with
       | Unannounced -> "unannounced"
       | Announced Cleared -> "cleared"
       | Announced Recovered -> "recovered")
      before.closed_messages after.closed_messages (slices_text closed_before)
;;

let log_text place = String.concat "\n" (List.map line_text (log_lines place))

let open_messages (place : Recorder.place) =
  match
    Keeper_turn_log_head.read ~session_dir:place.session_dir ~session_id:place.session_id
  with
  | Ok head -> head.open_messages
  | Error error -> fail (Keeper_checkpoint_store_session.checkpoint_load_error_to_string error)
;;

let turn_one = [ message User "a asks 1"; message Assistant "a answers 1" ]
let waiting = turn_one @ [ message User "a asks 2" ]

let turn_one_closed =
  "started at 0\nopened 1 at 0\nclosed completed at 2, before [], own [0+2]"
;;

(* Turn 1 ends; turn 2 is admitted and saves one message it leaves open. *)
let turn_two_open place =
  let first = admitted place 1 in
  save place ~boundary:Objects.Turn_closes ~turn_count:1 turn_one;
  finish place first Writer.Completed;
  let (_ : Writer.admitted) = admitted place 2 in
  save place ~boundary:Objects.Turn_continues ~turn_count:2 waiting
;;

let keep kept (mark : Log.mark) = { mark with closed_messages = kept }

type refused = Busy

let refused_text Busy = "busy"

(* The path's checks: the nth run answers [answer n]. *)
let checks answer =
  let runs = ref 0 in
  ( runs
  , fun () ->
      incr runs;
      answer !runs )
;;

let result_text changed_text = function
  | Ok changed -> "changed: " ^ changed_text changed
  | Error refusal -> "refused: " ^ Reset.refusal_to_string refused_text refusal
;;

let cleared _ = Reset.Announce { cause = Cleared; after = keep 0 }
let dropped _ = Reset.Drop { after = keep 0 }

let reset ?(line = cleared) place ~prepare ~change =
  Reset.run ~at:200.0 ~new_log_id:log_id place ~prepare ~line ~change
;;

(* The change sees the line written and nothing open, and it is handed the
   plan of the checks that ran after the closing save. *)
let test_the_line_comes_before_the_change =
  with_keeper "line-first"
  @@ fun place ->
  turn_two_open place;
  let runs, prepare = checks (fun run -> Ok run) in
  let result =
    reset place ~prepare ~change:(fun plan -> plan, log_text place, open_messages place)
  in
  check string "the result"
    (String.concat "\n"
       [ "changed: plan 2, nothing open"
       ; turn_one_closed
       ; "opened 2 at 2"
       ; "reset cleared 3 to 0, named [0+1]"
       ])
    (result_text
       (fun (plan, log, open_count) ->
          Printf.sprintf "plan %d, %s\n%s" plan
            (if open_count = 0 then "nothing open" else "messages open")
            log)
       result);
  check int "the checks ran before and after the closing save" 2 !runs
;;

(* No open message: the checks run once, and the line names nothing new. *)
let test_nothing_open =
  with_keeper "nothing-open"
  @@ fun place ->
  let first = admitted place 1 in
  save place ~boundary:Objects.Turn_closes ~turn_count:1 turn_one;
  finish place first Writer.Completed;
  let runs, prepare = checks (fun run -> Ok run) in
  let result =
    reset
      ~line:(fun (_ : int) -> Reset.Announce { cause = Recovered; after = keep 1 })
      place ~prepare ~change:Fun.id
  in
  check string "the result" "changed: 1" (result_text string_of_int result);
  check int "the checks ran once" 1 !runs;
  check string "the log" (turn_one_closed ^ "\nreset recovered 2 to 1, named []") (log_text place)
;;

(* A refusal before the save leaves everything; a refusal after it leaves the
   messages closed, as the next turn's own save would have, and no line. *)
let test_a_refusal_writes_no_line =
  with_keeper "refused"
  @@ fun place ->
  turn_two_open place;
  let before = log_text place in
  let changes = ref 0 in
  let change () = incr changes in
  let runs, prepare = checks (fun (_ : int) -> Error Busy) in
  check string "refused at once" "refused: busy"
    (result_text (fun () -> "") (reset place ~prepare ~change));
  check int "the checks ran once" 1 !runs;
  check int "the message is still open" 1 (open_messages place);
  let runs, prepare = checks (fun run -> if run = 1 then Ok () else Error Busy) in
  check string "refused after the closing save" "refused: busy"
    (result_text (fun () -> "") (reset place ~prepare ~change));
  check int "the checks ran twice" 2 !runs;
  check int "the message was closed" 0 (open_messages place);
  check string "no line" before (log_text place);
  check int "no change" 0 !changes
;;

(* The closing save cannot write its bundle. The change writes the same
   store, so it is not tried, and no line is written. *)
let test_a_closing_save_that_fails =
  with_keeper "save-fails"
  @@ fun place ->
  turn_two_open place;
  let before = log_text place in
  let changes = ref 0 in
  let objects = Filename.concat place.session_dir Keeper_checkpoint_object_store.dirname in
  Unix.chmod objects 0o500;
  let result =
    Fun.protect
      ~finally:(fun () -> Unix.chmod objects 0o700)
      (fun () ->
         reset place ~prepare:(fun () -> Ok ()) ~change:(fun () -> incr changes))
  in
  (match result with
   | Error (Open_not_closed (Save_not_installed (Objects_not_installed _ as cause))) ->
     check string "refused with the save's cause"
       ("refused: the head's open messages were not closed: the closing save was not installed: "
        ^ Keeper_checkpoint_store.checkpoint_cas_error_to_string cause)
       (result_text (fun () -> "") result)
   | Ok _ | Error _ -> fail ("refused for another reason: " ^ result_text (fun () -> "") result));
  check int "the message is still open" 1 (open_messages place);
  check string "no line" before (log_text place);
  check int "no change" 0 !changes
;;

(* A log whose tail does not decode takes no line, so the head is not
   changed, nor dropped. The closing save before it already landed. *)
let test_a_line_that_cannot_be_written =
  with_keeper "log-unread"
  @@ fun place ->
  turn_two_open place;
  let path = log_path place in
  let unreadable = Fs_compat.load_file path ^ "not a line\n" in
  Fs_compat.save_file path unreadable;
  let changes = ref 0 in
  List.iter
    (fun (label, line) ->
       match reset ~line place ~prepare:(fun () -> Ok ()) ~change:(fun () -> incr changes) with
       | Error (Reset.Line_not_written (Recorder.Tail_unread _)) -> ()
       | Error (Path_refused Busy | Open_not_closed _ | Line_not_written _ | Line_not_planned) ->
         failf "%s: refused for another reason" label
       | Ok () -> failf "%s: the head was changed with no line" label)
    [ "an announced reset", cleared; "a drop", dropped ];
  check string "the log is as it was" unreadable (Fs_compat.load_file path);
  check int "no change" 0 !changes
;;

(* No head to name: the change runs at once, with no closing save and no
   line. *)
let test_no_line =
  with_keeper "no-line"
  @@ fun place ->
  turn_two_open place;
  let before = log_text place in
  check string "the change ran" "changed: 1"
    (result_text string_of_int
       (reset ~line:(fun (_ : unit) -> Reset.No_line) place ~prepare:(fun () -> Ok ())
          ~change:(fun () -> 1)));
  check int "the message is still open" 1 (open_messages place);
  check string "no line" before (log_text place)
;;

(* A head this build cannot decode is dropped without being read: the line
   goes from the last mark to no closed message, and nothing is closed. *)
let test_a_drop_reads_no_head =
  with_keeper "drop"
  @@ fun place ->
  turn_two_open place;
  let head =
    Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir:place.session_dir
      ~session_id:place.session_id
  in
  Fs_compat.save_file head "not a head";
  (match
     Keeper_turn_log_head.read ~session_dir:place.session_dir ~session_id:place.session_id
   with
   | Error (_ : Keeper_checkpoint_store_decode.checkpoint_load_error) -> ()
   | Ok (_ : Keeper_turn_log_head.t) -> fail "the head still decodes");
  let runs, prepare = checks (fun run -> Ok run) in
  check string "the change ran" "changed: 1"
    (result_text string_of_int (reset ~line:dropped place ~prepare ~change:Fun.id));
  check int "the checks ran once" 1 !runs;
  check string "the log"
    (String.concat "\n"
       [ turn_one_closed; "opened 2 at 2"; "reset unannounced 2 to 0, named []" ])
    (log_text place)
;;

(* A drop before the log started writes its first line at no closed
   message, so the next unit names the head from its first message. *)
let test_a_drop_before_the_log_started =
  with_keeper "drop-first"
  @@ fun place ->
  save place ~boundary:Objects.Turn_closes ~turn_count:1 turn_one;
  check string "the change ran" "changed: ()"
    (result_text (fun () -> "()") (reset ~line:dropped place ~prepare:(fun () -> Ok ()) ~change:Fun.id));
  let second = admitted place 2 in
  save place ~boundary:Objects.Turn_closes ~turn_count:2
    (waiting @ [ message Assistant "a answers 2" ]);
  finish place second Writer.Completed;
  check string "the log"
    "started at 0\nopened 2 at 2\nclosed completed at 4, before [0+2], own [0+2]"
    (log_text place)
;;

(* The change fails after the line, or a kill cuts it: the disk is the same,
   a Reset and the head as it was. The next unit starts at the line's
   [after], so what lies above it is named again as no turn's, and nothing
   is skipped. *)
let test_a_change_that_does_not_land =
  with_keeper "not-landed"
  @@ fun place ->
  turn_two_open place;
  check string "the change's own answer is returned" "changed: failed"
    (result_text Fun.id (reset place ~prepare:(fun () -> Ok ()) ~change:(fun () -> "failed")));
  let third = admitted place 3 in
  save place ~boundary:Objects.Turn_closes ~turn_count:3
    (waiting @ [ message Assistant "a answers 3" ]);
  finish place third Writer.Completed;
  check string "the log"
    (String.concat "\n"
       [ turn_one_closed
       ; "opened 2 at 2"
       ; "reset cleared 3 to 0, named [0+1]"
       ; "closed close missing at 3, before [0+2,0+1], own []"
       ; "opened 3 at 3"
       ; "closed completed at 4, before [], own [0+1]"
       ])
    (log_text place)
;;

let () =
  run "keeper_turn_log_reset"
    [ ( "reset"
      , [ test_case "the line comes before the change" `Quick test_the_line_comes_before_the_change
        ; test_case "nothing open" `Quick test_nothing_open
        ; test_case "a refusal writes no line" `Quick test_a_refusal_writes_no_line
        ; test_case "a closing save that fails" `Quick test_a_closing_save_that_fails
        ; test_case "a line that cannot be written" `Quick test_a_line_that_cannot_be_written
        ; test_case "a change that does not land" `Quick test_a_change_that_does_not_land
        ; test_case "no line" `Quick test_no_line
        ; test_case "a drop reads no head" `Quick test_a_drop_reads_no_head
        ; test_case "a drop before the log started" `Quick test_a_drop_before_the_log_started
        ] )
    ]
;;
