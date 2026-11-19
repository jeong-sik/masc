(* One event written to a Keeper's turn log from its real stores
   (RFC librarian-call-only-proposes §5.2, §5.3). Histories are written by
   the checkpoint store's own save and the log is read back from its file,
   so what a line names is what a reader will find. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Codec = Masc.Keeper_turn_log_codec
module Recorder = Masc.Keeper_turn_log_recorder
module Writer = Masc.Keeper_turn_log_writer
module Store = Masc.Keeper_checkpoint_store
module Objects = Agent_core.Checkpoint_objects

let session_id = "trace-1"
let keeper_name = "recorder-keeper"

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
  let base_path = Filename.temp_file "test_turn_log_recorder_" "" in
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
  ; agent_name = "turn-log-recorder"
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

(* The whole session is taken away, as when a history is replaced behind the
   log's back. *)
let wipe_session (place : Recorder.place) =
  remove place.session_dir;
  Unix.mkdir place.session_dir 0o755
;;

let log_id =
  match Log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let record place event = Recorder.record ~at:100.0 ~new_log_id:log_id place event

let admit place n =
  record place
    (Writer.Admit
       { turn_ref = Ids.Turn_ref.make ~trace_id:session_id ~absolute_turn:n
       ; runtime = "test-runtime"
       ; task = Log.No_task
       ; stimuli = []
       })
;;

let must label = function
  | Ok (Recorder.Appended _) -> ()
  | Ok Recorder.Nothing_to_append -> failf "%s: nothing was appended" label
  | Error error -> failf "%s: %s" label (Recorder.not_recorded_to_string error)
;;

(* An admission that must be in the log, and what its turn carries. *)
let admitted place n =
  let answer = admit place n in
  must (Printf.sprintf "admission of turn %d" n) answer;
  Recorder.admitted answer
;;

let finish place admitted ending =
  must "end of the turn" (record place (Writer.Finish { admitted; ending }))
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

let test_turns_and_what_closed_between =
  in_workspace
  @@ fun place ->
  let first = admitted place 1 in
  let messages = save_turns place ~first:1 ~last:1 [] in
  finish place first Writer.Completed;
  (* A turn closed outside any admitted turn, and a chat row that arrived. *)
  let messages = save_turns place ~first:2 ~last:2 messages in
  let chat = Masc.Keeper_chat_store.chat_path ~base_dir:place.base_path ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname chat);
  Fs_compat.save_file chat "{\"c\":1}\n";
  let third = admitted place 3 in
  (match List.rev (log_lines place) with
   | Opened { baseline; _ } :: _ ->
     check (pair string string) "a mark names the history and the session it was taken from"
       (session_id, session_id)
       (baseline.trace, baseline.session);
     check int "and where the other stores ended" 8 baseline.chat_bytes
   | _ -> fail "the last line is not the admission");
  let (_ : Agent_core.Types.message list) = save_turns place ~first:3 ~last:3 messages in
  finish place third Writer.Errored;
  check string "each turn names what it closed, and the next names what closed in between"
    "started at 0\n\
     opened 1 at 0\n\
     closed completed at 2, before [], own [0+2]\n\
     opened 3 at 4\n\
     closed errored at 6, before [0+2], own [0+2]"
    (log_text place);
  (* A turn whose admission is not in the log ends without a line. *)
  (match record place (Writer.Finish { admitted = Writer.Not_recorded; ending = Writer.Completed }) with
   | Ok Recorder.Nothing_to_append -> ()
   | Ok (Recorder.Appended _) -> fail "a turn that was not admitted in the log wrote a line"
   | Error error -> fail (Recorder.not_recorded_to_string error));
  check int "and the log is as it was" 5 (List.length (log_lines place))
;;

(* The turn saved on its way and the process went away before its end. The
   next process start closes what was left open, then writes its line. *)
let test_a_turn_the_process_left_open =
  in_workspace
  @@ fun place ->
  let (_ : Writer.admitted) = admitted place 1 in
  let messages = save_turns place ~first:1 ~last:1 [] in
  let messages = messages @ [ message User "a asks 2" ] in
  save place ~boundary:Objects.Turn_continues ~turn_count:2 messages;
  (* The process is gone. The next one closes the open message. *)
  save place ~boundary:Objects.Turn_closes ~turn_count:3 messages;
  must "process start" (record place Writer.Process_start);
  check string "what the turn saved before the process went away is in its unit"
    "started at 0\nopened 1 at 0\nclosed process exited at 3, before [], own [0+2,0+1]"
    (log_text place);
  (match record place Writer.Process_start with
   | Ok Recorder.Nothing_to_append -> ()
   | Ok (Recorder.Appended _) -> fail "a second process start wrote a line"
   | Error error -> fail (Recorder.not_recorded_to_string error));
  let (_ : Writer.admitted) = admitted place 4 in
  check string "and the next turn starts after it" "opened 4 at 3"
    (line_text (List.nth (log_lines place) 3))
;;

(* More turns closed between two lines than a head keeps: the run reaches
   into a segment, which is read. *)
let test_a_gap_longer_than_the_head_keeps =
  in_workspace
  @@ fun place ->
  must "process start" (record place Writer.Process_start);
  let between = Objects.turns_per_segment + 2 in
  let messages = save_turns place ~first:1 ~last:between [] in
  let turn = admitted place (between + 1) in
  let (_ : Agent_core.Types.message list) =
    save_turns place ~first:(between + 1) ~last:(between + 1) messages
  in
  finish place turn Writer.Completed;
  match List.rev (log_lines place) with
  | Closed { unattributed; own; after; _ } :: _ ->
    check int "every closed message is counted" (2 * (between + 1)) after.closed_messages;
    check int "one slice for each turn closed in between" between (List.length unattributed);
    check bool "each of them whole" true
      (List.for_all (fun (slice : Log.slice) -> slice.skip = 0 && slice.take = 2) unattributed);
    check string "and the turn's own" "0+2" (slices_text own)
  | _ -> fail "the last line is not the turn's end"
;;

let head_turns (place : Recorder.place) =
  match
    Masc.Keeper_checkpoint_store_canonical.known_canonical
      ~canonical_path:
        (Store.agent_core_checkpoint_path ~session_dir:place.session_dir ~session_id)
  with
  | Ok (Some known) -> known.known_head.history.turns
  | Ok None -> fail "no head"
  | Error error ->
    fail (Masc.Keeper_checkpoint_store_session.checkpoint_load_error_to_string error)
;;

let named_bundles place =
  List.concat_map
    (fun (line : Log.line) ->
       match line with
       | Closed { unattributed; own; _ } -> unattributed @ own
       | Reset { closed_before; _ } -> closed_before
       | Log_started _ | Opened _ -> [])
    (log_lines place)
  |> List.map (fun (slice : Log.slice) -> slice.bundle)
;;

(* A history that is replaced behind the log's back and holds fewer closed
   messages than the last line saw. *)
let test_a_replaced_history_that_is_shorter =
  in_workspace
  @@ fun place ->
  let (_ : Agent_core.Types.message list) = save_turns place ~first:1 ~last:3 [] in
  must "process start" (record place Writer.Process_start);
  wipe_session place;
  let messages = save_turns ~who:"b" place ~first:1 ~last:1 [] in
  let turn = admitted place 2 in
  let (_ : Agent_core.Types.message list) = save_turns ~who:"b" place ~first:2 ~last:2 messages in
  finish place turn Writer.Completed;
  check string "the admission says the history is another one, and every message of it is named"
    "started at 6\n\
     reset unannounced 6 to 0 []\n\
     opened 2 at 2\n\
     closed completed at 4, before [0+2], own [0+2]"
    (log_text place);
  check bool "the bundles named are the new history's" true
    (named_bundles place = List.map (fun (turn : Objects.turn) -> turn.bundle) (head_turns place))
;;

(* The same, when the new history holds more closed messages than the last
   line saw. The counts do not show that it is another history (RFC §22.4):
   its messages up to the old count are named by no line. *)
let test_a_replaced_history_that_is_longer =
  in_workspace
  @@ fun place ->
  let (_ : Agent_core.Types.message list) = save_turns place ~first:1 ~last:1 [] in
  must "process start" (record place Writer.Process_start);
  wipe_session place;
  let messages = save_turns ~who:"b" place ~first:1 ~last:3 [] in
  let turn = admitted place 4 in
  let (_ : Agent_core.Types.message list) = save_turns ~who:"b" place ~first:4 ~last:4 messages in
  finish place turn Writer.Completed;
  check string "no reset is written"
    "started at 2\nopened 4 at 6\nclosed completed at 8, before [0+2,0+2], own [0+2]"
    (log_text place);
  match head_turns place with
  | [ first; second; third; fourth ] ->
    check bool "the new history's turns after the old count are named" true
      (named_bundles place = [ second.bundle; third.bundle; fourth.bundle ]);
    check bool "its first turn is named by no line" false
      (List.mem first.bundle (named_bundles place))
  | turns -> failf "the head holds %d turns" (List.length turns)
;;

let test_what_is_not_written =
  in_workspace
  @@ fun place ->
  must "process start" (record place Writer.Process_start);
  let path = log_path place in
  let whole = Fs_compat.load_file path in
  (* An append that was interrupted left a fragment after the last line.
     The next append cuts it: the fragment is in no line. *)
  let channel = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path in
  output_string channel "{\"k\":";
  close_out channel;
  let (_ : Writer.admitted) = admitted place 1 in
  check string "the log goes on after the last whole line" "started at 0\nopened 1 at 0"
    (log_text place);
  let whole_after = Fs_compat.load_file path in
  check string "and the fragment is gone" whole (String.sub whole_after 0 (String.length whole));
  (* A head that is there and cannot be read: no line, and the turn carries
     that its admission is not in the log. *)
  Fs_compat.save_file
    (Store.agent_core_checkpoint_path ~session_dir:place.session_dir ~session_id)
    "not a head";
  let answer = admit place 2 in
  (match answer with
   | Error (Recorder.Head_unread _) -> ()
   | Error error -> fail (Recorder.not_recorded_to_string error)
   | Ok _ -> fail "a line was written from a head that was not read");
  check bool "the turn knows" true (Recorder.admitted answer = Writer.Not_recorded);
  check string "and the log is as it was" whole_after (Fs_compat.load_file path)
;;

let () =
  run "keeper_turn_log_recorder"
    [ ( "record"
      , [ test_case "turns, and what closed between them" `Quick test_turns_and_what_closed_between
        ; test_case "a turn the process left open" `Quick test_a_turn_the_process_left_open
        ; test_case "a gap longer than the head keeps" `Quick
            test_a_gap_longer_than_the_head_keeps
        ; test_case "a replaced history that is shorter" `Quick
            test_a_replaced_history_that_is_shorter
        ; test_case "a replaced history that is longer" `Quick
            test_a_replaced_history_that_is_longer
        ; test_case "what is not written" `Quick test_what_is_not_written
        ] )
    ]
;;
