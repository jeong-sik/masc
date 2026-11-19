(* A Keeper turn in its turn log (RFC librarian-call-only-proposes §5.2):
   [Keeper_turn_log_turn.around] writes the turn's [Opened] and, on every way
   out, its [Closed]. Histories are written by the checkpoint store's own
   save and the log is read back from its file. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Codec = Masc.Keeper_turn_log_codec
module Recorder = Masc.Keeper_turn_log_recorder
module Writer = Masc.Keeper_turn_log_writer
module Turn = Masc.Keeper_turn_log_turn
module Store = Masc.Keeper_checkpoint_store
module Objects = Agent_core.Checkpoint_objects

let session_id = "trace-1"
let keeper_name = "turn-keeper"

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK -> Unix.unlink path
;;

let in_workspace test () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_file "test_turn_log_turn_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  let place : Recorder.place =
    { keepers_dir = Filename.concat base_path "keepers"
    ; base_path
    ; keeper_name
    ; session_dir = Filename.concat base_path "session"
    ; session_id
    }
  in
  Unix.mkdir place.session_dir 0o755;
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> test place)
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

(* Turn [n] of the history written by [who]: a question and its answer. *)
let turn_messages ?(who = "a") n =
  [ message User (Printf.sprintf "%s asks %d" who n)
  ; message Assistant (Printf.sprintf "%s answers %d" who n)
  ]
;;

let checkpoint ~turn_count messages : Agent_core.Checkpoint.t =
  { provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "turn-log-turn"
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
    Store.save_agent_core_classified ~session_dir:place.session_dir ~history_retained:0 ~boundary
      (checkpoint ~turn_count messages)
  with
  | Ok (Store.Saved _) -> ()
  | Ok (Store.Stale_noop _) -> failf "save %d was read as stale" turn_count
  | Error detail -> failf "save %d: %s" turn_count detail
;;

(* Turns [first .. last] saved one by one, each closing. *)
let save_turns ?who place ~first ~last messages =
  let rec go n messages =
    if n <= last
    then (
      let messages = messages @ turn_messages ?who n in
      save place ~boundary:Objects.Turn_closes ~turn_count:n messages;
      go (n + 1) messages)
    else messages
  in
  go first messages
;;

let log_path (place : Recorder.place) =
  Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:place.keepers_dir
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
           | Error error -> fail (Masc.Keeper_memory_os_types.wire_error_to_string error)))
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

let cause_text : Log.reset_cause -> string = function
  | Announced Cleared -> "cleared"
  | Announced Recovered -> "recovered"
  | Unannounced -> "unannounced"
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
    Printf.sprintf "reset %s %d to %d [%s]" (cause_text cause) before.closed_messages
      after.closed_messages (slices_text closed_before)
;;

let log_text place = String.concat "\n" (List.map line_text (log_lines place))


let mentions text part =
  let length = String.length part in
  let rec from at =
    at + length <= String.length text
    && (String.equal (String.sub text at length) part || from (at + 1))
  in
  from 0
;;

let turn_ref n = Ids.Turn_ref.make ~trace_id:session_id ~absolute_turn:n

(* One turn around [body]. The answer says whether the turn completed. *)
let turn ?(task = Log.No_task) place n body =
  Turn.around ~place ~turn_ref:(turn_ref n) ~runtime:"test-runtime" ~task ~succeeded:Result.is_ok
    body
;;

let failures site =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string TurnLogAppendFailures)
    ~labels:[ "keeper", keeper_name; "site", site ]
    ()
;;

let every_exit = [ Turn.Returned_ok; Returned_error; Raised; Cancelled ]
let every_save = [ None; Some Turn.Saved; Some Stale; Some Failed ]

let ending_text : Writer.ending -> string = function
  | Completed -> "completed"
  | Errored -> "errored"
  | Cancelled -> "cancelled"
  | Save_failed -> "save failed"
  | Stale_save -> "stale save"
;;

let test_the_label_of_an_end () =
  let row exit = String.concat ", " (List.map (fun save -> ending_text (Turn.ending exit save)) every_save) in
  check (list string) "by exit, for no closing save, saved, stale, failed"
    [ "completed, completed, stale save, save failed"
    ; "errored, errored, stale save, save failed"
    ; "errored, errored, stale save, save failed"
    ; "cancelled, cancelled, cancelled, cancelled"
    ]
    (List.map row every_exit)
;;

let test_the_task_of_a_turn () =
  let task_id =
    match Keeper_id.Task_id.of_string "task-7" with
    | Ok id -> id
    | Error reason -> fail reason
  in
  let goal : Masc.Keeper_turn_task_context.goal =
    { goal_id = "goal-1"
    ; phase = Goal_phase.Executing
    ; criterion =
        Goal_store.Criterion
          { revision = "r1"
          ; title = "Retain every input"
          ; measure = Goal_measure_fixture.done_when "all"
          ; procedure = "read the file"
          }
    }
  in
  check bool "no Task" true (Turn.task_evidence No_task = Log.No_task);
  check bool "a Task source that was not read" true
    (Turn.task_evidence (Task_source_unavailable "the board is down") = Log.Task_source_unavailable);
  (match Turn.task_evidence (Task { task_id; goals = Ok [ goal ] }) with
   | Task { task; goals = Some [ shown ] } ->
     check bool "the Task" true (Keeper_id.Task_id.equal task task_id);
     check string "the Goal" "goal-1" shown.goal;
     check string "its phase and criterion, as the Goal's own encoders write them"
       (Yojson.Safe.to_string
          (`Assoc
              [ "phase", Goal_phase.to_yojson goal.phase
              ; "criterion", Goal_store.criterion_to_yojson goal.criterion
              ]))
       shown.shown;
     check bool "the text names the criterion" true (mentions shown.shown "Retain every input")
   | _ -> fail "a Task with one Goal was not kept as one");
  match Turn.task_evidence (Task { task_id; goals = Error (Goal_links_unavailable "no index") }) with
  | Task { goals = None; _ } -> ()
  | _ -> fail "Goals that were not read are not kept as unread"
;;

let test_a_turn_that_completes =
  in_workspace
  @@ fun place ->
  let answer =
    turn place 1 (fun turn ->
      let (_ : Agent_core.Types.message list) = save_turns place ~first:1 ~last:1 [] in
      Turn.note_closing_save turn Saved;
      Ok "done")
  in
  check (result string string) "the body's answer is the turn's" (Ok "done") answer;
  check string "its two lines" "started at 0\nopened 1 at 0\nclosed completed at 2, before [], own [0+2]"
    (log_text place)
;;

exception Turn_broke

let test_every_way_out_writes_one_end =
  in_workspace
  @@ fun place ->
  let (_ : (unit, string) result) = turn place 1 (fun (_ : Turn.t) -> Error "the provider failed") in
  (match turn place 2 (fun (_ : Turn.t) -> raise Turn_broke) with
   | (_ : (unit, string) result) -> fail "the exception did not leave"
   | exception Turn_broke -> ());
  (* The turn's fiber is cancelled while its body runs. *)
  (match
     Eio.Cancel.sub (fun context ->
       turn place 3 (fun (_ : Turn.t) ->
         Eio.Cancel.cancel context Turn_broke;
         Eio.Fiber.check ();
         Ok ()))
   with
   | (_ : (unit, string) result) -> fail "the cancellation did not leave"
   | exception Eio.Cancel.Cancelled _ -> ());
  let (_ : (unit, string) result) =
    turn place 4 (fun turn ->
      Turn.note_closing_save turn Failed;
      Error "the save failed")
  in
  let (_ : (unit, string) result) =
    turn place 5 (fun turn ->
      Turn.note_closing_save turn Stale;
      Ok ())
  in
  check string "one end for each turn, named by how it ended"
    "started at 0\n\
     opened 1 at 0\n\
     closed errored at 0, before [], own []\n\
     opened 2 at 0\n\
     closed errored at 0, before [], own []\n\
     opened 3 at 0\n\
     closed cancelled at 0, before [], own []\n\
     opened 4 at 0\n\
     closed save failed at 0, before [], own []\n\
     opened 5 at 0\n\
     closed stale save at 0, before [], own []"
    (log_text place)
;;

(* The log cannot take the turn's lines. The turn runs, and its answer and
   its saves are what they would have been. *)
let test_a_turn_the_log_cannot_take =
  in_workspace
  @@ fun place ->
  let head = Store.agent_core_checkpoint_path ~session_dir:place.session_dir ~session_id in
  let at_admission = failures "admission" in
  let at_end = failures "end" in
  Fs_compat.save_file head "not a head";
  let answer = turn place 1 (fun (_ : Turn.t) -> Ok "ran") in
  check (result string string) "the turn ran" (Ok "ran") answer;
  check int "no line" 0 (List.length (log_lines place));
  check (float 0.0) "the admission is counted" (at_admission +. 1.0) (failures "admission");
  check (float 0.0) "a turn that is not in the log has no end to fail" at_end (failures "end");
  (* The admission is written, and the end is not. *)
  Unix.unlink head;
  let answer =
    turn place 2 (fun (_ : Turn.t) ->
      Fs_compat.save_file head "not a head";
      Ok "ran again")
  in
  check (result string string) "the answer is the body's" (Ok "ran again") answer;
  check string "the turn stays open in the log" "started at 0\nopened 2 at 0" (log_text place);
  check (float 0.0) "the end is counted" (at_end +. 1.0) (failures "end");
  (* The next turn closes it. *)
  Unix.unlink head;
  let (_ : (unit, string) result) = turn place 3 (fun (_ : Turn.t) -> Ok ()) in
  check string "the next admission closes the turn that could not"
    "started at 0\n\
     opened 2 at 0\n\
     closed close missing at 0, before [], own []\n\
     opened 3 at 0\n\
     closed completed at 0, before [], own []"
    (log_text place)
;;

(* A Keeper is deleted and made again under the same name while the process
   lives: its directory is gone when the next turn writes. *)
let test_a_keeper_directory_that_was_removed =
  in_workspace
  @@ fun place ->
  let (_ : (unit, string) result) = turn place 1 (fun (_ : Turn.t) -> Ok ()) in
  remove place.keepers_dir;
  let at_admission = failures "admission" in
  let (_ : (unit, string) result) = turn place 2 (fun (_ : Turn.t) -> Ok ()) in
  check (float 0.0) "the admission is written" at_admission (failures "admission");
  check string "the log starts again in a new directory"
    "started at 0\nopened 2 at 0\nclosed completed at 0, before [], own []"
    (log_text place)
;;

let () =
  run "keeper_turn_log_turn"
    [ ( "values"
      , [ test_case "the label of an end" `Quick test_the_label_of_an_end
        ; test_case "the Task of a turn" `Quick test_the_task_of_a_turn
        ] )
    ; ( "around"
      , [ test_case "a turn that completes" `Quick test_a_turn_that_completes
        ; test_case "every way out writes one end" `Quick test_every_way_out_writes_one_end
        ; test_case "a turn the log cannot take" `Quick test_a_turn_the_log_cannot_take
        ; test_case "a Keeper directory that was removed" `Quick
            test_a_keeper_directory_that_was_removed
        ] )
    ]
;;
