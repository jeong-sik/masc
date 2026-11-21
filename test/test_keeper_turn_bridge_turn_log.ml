(* The turns carried across a runtime switch, read from the Keeper's turn log
   and the ledger of turns an official client answered (RFC
   librarian-call-only-proposes §11.8). One scene per rule. *)

open Alcotest
open Masc
module Turn_log = Keeper_turn_log
module Bridge = Keeper_turn_bridge

let keeper_name = "bridge-keeper"
let trace_id = "bridge-trace"
let turn n = Ids.Turn_ref.make ~trace_id ~absolute_turn:n
let mark = Masc_test_deps.turn_log_mark ~trace_id ~closed_messages:0

let session_a =
  { Bridge.client_kind = Codex
  ; runtime_id = "codex.a"
  ; session_id = "thread-a"
  }
;;

let session_b =
  { Bridge.client_kind = Claude_code
  ; runtime_id = "claude.b"
  ; session_id = "session-b"
  }
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f () =
  let base_path = Filename.temp_file "turn-bridge-turn-log" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base_path)
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f base_path)
;;

let log_path base_path =
  Keeper_turn_log_store.path_for_keepers_dir
    ~keepers_dir:(Common.keepers_runtime_dir_of_base ~base_path)
    ~keeper_id:keeper_name
;;

(* [line] at the end of the turn log. Answers the offset it starts at. *)
let append base_path line =
  let path = log_path base_path in
  let at_end =
    match Keeper_turn_log_store.read_tail path with
    | Ok Keeper_turn_log_store.Nothing_written -> 0
    | Ok (Keeper_turn_log_store.Written { rows_end; _ }) -> rows_end
    | Error error -> fail (Keeper_turn_log_store.read_error_to_string error)
  in
  match Keeper_turn_log_store.append ~path ~at_end (line, []) with
  | Ok { Keeper_turn_log_store.last_at; new_end = (_ : int) } -> last_at
  | Error (_ : Keeper_turn_log_store.append_error) -> fail "the turn log line was not appended"
;;

let start base_path =
  let (_ : int) =
    append base_path (Turn_log.Log_started { id = Turn_log.Log_id.fresh (); at = 1.0; mark })
  in
  ()
;;

(* What an Agent Core closing save closed: the turn's [own]. *)
let saved_head =
  [ { Turn_log.bundle = Agent_core.Checkpoint_objects.digest_of_bytes "head"; skip = 0; take = 2 }
  ]
;;

let close_turn ?(own = []) base_path n outcome =
  let opened =
    append
      base_path
      (Turn_log.Opened
         { at = 2.0
         ; turn_ref = turn n
         ; runtime = "fixture"
         ; task = Turn_log.No_task
         ; stimuli = []
         ; baseline = mark
         })
  in
  let (_ : int) =
    append
      base_path
      (Turn_log.Closed { turn = opened; at = 3.0; outcome; after = mark; unattributed = []; own })
  in
  ()
;;

let reset base_path cause =
  let (_ : int) =
    append
      base_path
      (Turn_log.Reset { at = 4.0; cause; before = mark; after = mark; closed_before = [] })
  in
  ()
;;

(* The history lines a turn left: its request and, when it answered, its
   reply. *)
let history base_path =
  Keeper_context_runtime.create_session
    ~session_id:trace_id
    ~base_dir:(Keeper_fs.session_store_path_for_base_path base_path)
;;

let ask history n =
  Keeper_context_runtime.persist_message
    ~keeper_name
    ~turn_ref:(turn n)
    ~source:Keeper_types_support.Direct_user
    history
    (Agent_core.Types.user_msg (Printf.sprintf "ask %d" n))
;;

let reply history n =
  Keeper_context_runtime.persist_message
    ~keeper_name
    ~turn_ref:(turn n)
    ~source:Keeper_types_support.Direct_assistant
    history
    (Agent_core.Types.assistant_msg (Printf.sprintf "reply %d" n))
;;

let answered ?session base_path n =
  match Bridge.record_client_turn ~base_path ~keeper_name { Bridge.turn_ref = turn n; session } with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let bridged base_path ~existing_messages =
  Bridge.uncheckpointed_official_turns
    ~base_path
    ~keeper_name
    ~trace_id
    ~session_dir:(Filename.concat (Keeper_fs.session_store_path_for_base_path base_path) trace_id)
    ~existing_messages
;;

let bridged_texts base_path ~existing_messages =
  match bridged base_path ~existing_messages with
  | Ok messages -> List.map Agent_core.Types.text_of_message messages
  | Error error -> fail (Bridge.bridge_load_error_to_string error)
;;

let handoff base_path (key : Bridge.session_key) =
  Bridge.intervening_context_for_official_resume
    ~base_path
    ~keeper_name
    ~trace_id
    ~client_kind:key.client_kind
    ~runtime_id:key.runtime_id
    ~session_id:key.session_id
;;

let handoff_text base_path key =
  match handoff base_path key with
  | Ok text -> text
  | Error error -> fail (Bridge.bridge_load_error_to_string error)
;;

let contains text part = String_util.contains_substring text part

(* (a) Agent Core takes over after official client turns: it is handed the
   turns an official client answered since the last save of the head, failed
   ones too, and not an Agent Core turn that failed before its save. *)
let test_agent_core_takes_over =
  with_workspace
  @@ fun base_path ->
  let history = history base_path in
  start base_path;
  ask history 1;
  reply history 1;
  answered base_path 1;
  close_turn base_path 1 Turn_log.Completed;
  ask history 2;
  reply history 2;
  close_turn ~own:saved_head base_path 2 Turn_log.Completed;
  ask history 3;
  reply history 3;
  answered base_path 3;
  close_turn base_path 3 Turn_log.Completed;
  ask history 4;
  answered base_path 4;
  close_turn base_path 4 Turn_log.Errored;
  ask history 5;
  close_turn base_path 5 Turn_log.Errored;
  let first = bridged_texts base_path ~existing_messages:[] in
  check
    (list string)
    "the official turns after the save, in the order they closed"
    [ "ask 3"; "reply 3"; "ask 4" ]
    first;
  let carried =
    match bridged base_path ~existing_messages:[] with
    | Ok messages -> messages
    | Error error -> fail (Bridge.bridge_load_error_to_string error)
  in
  check
    (list string)
    "a history that already holds them is handed nothing again"
    []
    (bridged_texts base_path ~existing_messages:carried)
;;

(* (b) Session A resumes after session B ran: A is told B's turns and not
   its own, nor an Agent Core turn that failed before its save. Once A settles
   again, nothing is left to tell. *)
let test_resume_after_another_session =
  with_workspace
  @@ fun base_path ->
  let history = history base_path in
  start base_path;
  ask history 1;
  reply history 1;
  answered ~session:session_a base_path 1;
  close_turn base_path 1 Turn_log.Completed;
  ask history 2;
  reply history 2;
  answered ~session:session_b base_path 2;
  close_turn base_path 2 Turn_log.Completed;
  ask history 3;
  close_turn base_path 3 Turn_log.Errored;
  ask history 4;
  reply history 4;
  answered ~session:session_b base_path 4;
  close_turn base_path 4 Turn_log.Completed;
  (match handoff_text base_path session_a with
   | None -> fail "session A must be told what ran after its turn"
   | Some text ->
     check bool "B's first turn" true (contains text "reply 2");
     check bool "B's second turn" true (contains text "reply 4");
     check bool "not A's own turn" false (contains text "ask 1");
     check bool "not the Agent Core turn that failed before its save" false
       (contains text "ask 3"));
  ask history 5;
  reply history 5;
  answered ~session:session_a base_path 5;
  close_turn base_path 5 Turn_log.Completed;
  check (option string) "after A settles again" None (handoff_text base_path session_a)
;;

(* (c) A clear drops the turns before it. A recovering purge keeps them. *)
let test_counted_reset =
  with_workspace
  @@ fun base_path ->
  let history = history base_path in
  start base_path;
  ask history 1;
  reply history 1;
  answered base_path 1;
  close_turn base_path 1 Turn_log.Completed;
  reset base_path (Turn_log.Announced Turn_log.Recovered);
  ask history 2;
  reply history 2;
  answered base_path 2;
  close_turn base_path 2 Turn_log.Completed;
  check
    (list string)
    "a recovering purge keeps the turns before it"
    [ "ask 1"; "reply 1"; "ask 2"; "reply 2" ]
    (bridged_texts base_path ~existing_messages:[]);
  reset base_path (Turn_log.Announced Turn_log.Cleared);
  ask history 3;
  reply history 3;
  answered base_path 3;
  close_turn base_path 3 Turn_log.Completed;
  check
    (list string)
    "a clear drops the turns before it"
    [ "ask 3"; "reply 3" ]
    (bridged_texts base_path ~existing_messages:[])
;;

(* (d) A turn log line that does not decode refuses the bridge. It is not
   passed over. *)
let test_undecodable_line =
  with_workspace
  @@ fun base_path ->
  let history = history base_path in
  start base_path;
  ask history 1;
  reply history 1;
  answered base_path 1;
  close_turn base_path 1 Turn_log.Completed;
  Out_channel.with_open_gen
    [ Open_append; Open_binary ]
    0o600
    (log_path base_path)
    (fun channel -> output_string channel "not a turn log line\n");
  match bridged base_path ~existing_messages:[] with
  | Error (Bridge.Turn_log_refused (Bridge.Line_undecodable { reason = Keeper_turn_log_store.Not_json; _ })) -> ()
  | Error error -> fail ("refused for another reason: " ^ Bridge.bridge_load_error_to_string error)
  | Ok (_ : Agent_core.Types.message list) ->
    fail "a line that does not decode must refuse the bridge"
;;

(* (e) A session with no ledger line is told nothing. A ledger line whose
   turn the turn log does not hold is refused: where the turns after it start
   is not known. *)
let test_session_without_a_ledger_line =
  with_workspace
  @@ fun base_path ->
  let history = history base_path in
  start base_path;
  ask history 1;
  reply history 1;
  answered ~session:session_b base_path 1;
  close_turn base_path 1 Turn_log.Completed;
  check (option string) "no ledger line, nothing told" None (handoff_text base_path session_a);
  answered ~session:session_a base_path 9;
  match handoff base_path session_a with
  | Error (Bridge.Cursor_turn_not_in_log missing) ->
    check string "the missing turn" (Ids.Turn_ref.to_string (turn 9))
      (Ids.Turn_ref.to_string missing)
  | Error error -> fail ("refused for another reason: " ^ Bridge.bridge_load_error_to_string error)
  | Ok (_ : string option) -> fail "a session whose turn is not in the turn log must be refused"
;;

let () =
  run
    "keeper_turn_bridge_turn_log"
    [ ( "turn bridge"
      , [ test_case "agent core takes over after official turns" `Quick test_agent_core_takes_over
        ; test_case "a session resumes after another session" `Quick
            test_resume_after_another_session
        ; test_case "a counted reset drops earlier turns" `Quick test_counted_reset
        ; test_case "an undecodable turn log line refuses" `Quick test_undecodable_line
        ; test_case "a session without a ledger line" `Quick test_session_without_a_ledger_line
        ] )
    ]
;;
