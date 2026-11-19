(* What the turn log reads from a Keeper's saved history
   (RFC librarian-call-only-proposes §5.1, §5.2). Every history here is
   written by the store's own save, so the counts are those of real heads. *)

open Alcotest
module Head = Masc.Keeper_turn_log_head
module Marks = Masc.Keeper_turn_log_marks
module Store = Masc.Keeper_checkpoint_store
module Objects = Agent_core.Checkpoint_objects

let session_id = "trace-1"

(* The head is read below the store's facade, so its error is the type the
   facade's own error is made from. *)
let unread_text = Masc.Keeper_checkpoint_store_session.checkpoint_load_error_to_string

let temp_session_dir () =
  let root = Filename.temp_file "test_turn_log_head_" "" in
  Unix.unlink root;
  Unix.mkdir root 0o755;
  let session_dir = Filename.concat root "session" in
  Unix.mkdir session_dir 0o755;
  root, session_dir
;;

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK -> Unix.unlink path
;;

let in_session test () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root, session_dir = temp_session_dir () in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> test ~session_dir)
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

(* Turn [n] is a question and its answer. *)
let turn_messages n =
  [ message User (Printf.sprintf "question %d" n); message Assistant (Printf.sprintf "answer %d" n) ]
;;

let checkpoint ~turn_count messages : Agent_core.Checkpoint.t =
  { provider_binding = None
  ; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "turn-log-head"
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

let save ~session_dir ~boundary ~turn_count messages =
  match
    Store.save_agent_core_classified ~session_dir ~history_retained:0 ~boundary
      (checkpoint ~turn_count messages)
  with
  | Ok (Store.Saved _) -> ()
  | Ok (Store.Stale_noop _) -> failf "save %d was read as stale" turn_count
  | Error detail -> failf "save %d: %s" turn_count detail
;;

(* [turns] closed turns, each saved as the turn path saves one. *)
let save_closed_turns ~session_dir turns =
  let rec go n messages =
    if n <= turns
    then (
      let messages = messages @ turn_messages n in
      save ~session_dir ~boundary:Objects.Turn_closes ~turn_count:n messages;
      go (n + 1) messages)
    else messages
  in
  go 1 []
;;

let read ~session_dir =
  match Head.read ~session_dir ~session_id with
  | Ok head -> head
  | Error error -> fail (unread_text error)
;;

let counts (head : Head.t) = head.closed_messages, head.open_messages

(* Skip and take of each slice. The bundle names are those the save made. *)
let run_text ~session_dir (head : Head.t) ~from ~through =
  match
    Head.with_segments_as_needed ~session_dir head.covered (fun covered ->
      Marks.slices covered ~from ~through)
  with
  | Ok slices ->
    String.concat " "
      (List.map
         (fun (slice : Masc.Keeper_turn_log.slice) -> Printf.sprintf "%d:%d" slice.skip slice.take)
         slices)
  | Error (Head.Ends_after_covered { through; last }) ->
    Printf.sprintf "range: ends at %d after %d" through last
  | Error (Head.Backwards _) -> "range: backwards"
  | Error (Head.Segment Nothing_before) -> "segment: nothing before"
  | Error (Head.Segment (Not_read Segment_missing)) -> "segment: missing"
  | Error (Head.Segment (Not_read (Segment_unreadable _))) -> "segment: unreadable"
  | Error (Head.Segment (Not_read (Segment_invalid _))) -> "segment: invalid"
  | Error (Head.Segment (Does_not_fit _)) -> "segment: does not fit"
;;

let test_no_checkpoint =
  in_session
  @@ fun ~session_dir ->
  let head = read ~session_dir in
  check (pair int int) "nothing is closed and nothing is open" (0, 0) (counts head);
  check string "an empty run of an empty history" "" (run_text ~session_dir head ~from:0 ~through:0);
  check string "there is no message to name" "range: ends at 1 after 0"
    (run_text ~session_dir head ~from:0 ~through:1)
;;

let test_closed_and_open =
  in_session
  @@ fun ~session_dir ->
  let messages = save_closed_turns ~session_dir 3 in
  let head = read ~session_dir in
  check (pair int int) "three turns of two messages" (6, 0) (counts head);
  check string "one slice per turn" "0:2 0:2 0:2" (run_text ~session_dir head ~from:0 ~through:6);
  check string "a run inside the turns" "1:1 0:1" (run_text ~session_dir head ~from:3 ~through:5);
  (* A save that does not end the turn leaves its messages open. *)
  save ~session_dir ~boundary:Objects.Turn_continues ~turn_count:4
    (messages @ [ message User "question 4" ]);
  let head = read ~session_dir in
  check (pair int int) "the open message is not counted as closed" (6, 1) (counts head);
  check string "and no run reaches it" "range: ends at 7 after 6"
    (run_text ~session_dir head ~from:6 ~through:7)
;;

(* The head keeps fewer than [Objects.turns_per_segment] turns. The rest is
   in segments, and a run that starts there needs the segment read. *)
let test_run_into_a_segment =
  in_session
  @@ fun ~session_dir ->
  let turns = Objects.turns_per_segment + 3 in
  let (_ : Agent_core.Types.message list) = save_closed_turns ~session_dir turns in
  let head = read ~session_dir in
  let in_segment = 2 * Objects.turns_per_segment in
  check (pair int int) "every message is closed" (2 * turns, 0) (counts head);
  check int "the head's own turns start after the segment" in_segment (Marks.first head.covered);
  check string "a run inside the head's turns reads no segment" "0:2"
    (run_text ~session_dir head ~from:in_segment ~through:(in_segment + 2));
  check string "a run that starts in the segment" "1:1 0:2 0:1"
    (run_text ~session_dir head ~from:(in_segment - 1) ~through:(in_segment + 3));
  check int "the whole history, one slice per turn" turns
    (List.length
       (String.split_on_char ' ' (run_text ~session_dir head ~from:0 ~through:(2 * turns))));
  (* The segment object is taken away, then replaced by other bytes. *)
  let segment =
    match
      Masc.Keeper_checkpoint_store_canonical.known_canonical
        ~canonical_path:(Store.agent_core_checkpoint_path ~session_dir ~session_id)
    with
    | Ok (Some { known_head = { history = { segment = Some segment; _ }; _ }; _ }) ->
      Masc.Keeper_checkpoint_object_store.path ~session_dir segment.segment
    | Ok (Some _) | Ok None -> fail "the head names no segment"
    | Error error -> fail (unread_text error)
  in
  Unix.unlink segment;
  check string "a missing segment is not an empty one" "segment: missing"
    (run_text ~session_dir head ~from:0 ~through:2);
  check string "and a run that needs no segment is unaffected" "0:2"
    (run_text ~session_dir head ~from:in_segment ~through:(in_segment + 2));
  Fs_compat.save_file segment "{}";
  check string "other bytes under the segment's name" "segment: invalid"
    (run_text ~session_dir head ~from:0 ~through:2)
;;

(* What the turn that starts from this state sees. *)
type turn_start =
  | Starts_fresh
  | Continues of int
  | Does_not_start

let turn_start ~session_dir =
  match
    Store.turn_history_of_load (Store.load_agent_core ~session_dir ~session_id)
  with
  | Ok (Store.No_saved_history | Saved_history_superseded _) -> Starts_fresh
  | Ok (Saved_history checkpoint) -> Continues (List.length checkpoint.messages)
  | Error (_ : Store.checkpoint_load_error) -> Does_not_start
;;

let agrees ~session_dir label =
  match turn_start ~session_dir, Head.read ~session_dir ~session_id with
  | Starts_fresh, Ok head -> check (pair int int) label (0, 0) (counts head)
  | Continues messages, Ok head ->
    check int label messages (head.closed_messages + head.open_messages)
  | Does_not_start, Error (_ : Masc.Keeper_checkpoint_store_decode.checkpoint_load_error) -> ()
  | Starts_fresh, Error error | Continues _, Error error ->
    failf "%s: the turn starts and the head was not read: %s" label (unread_text error)
  | Does_not_start, Ok head ->
    failf "%s: the turn does not start and the head counts %d" label head.closed_messages
;;

let write_canonical ~session_dir text =
  Fs_compat.save_file (Store.agent_core_checkpoint_path ~session_dir ~session_id) text
;;

let at_version version =
  match Agent_core.Checkpoint.to_json (checkpoint ~turn_count:9 (turn_messages 1)) with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc
          (List.map
             (fun (key, value) ->
                if String.equal key "version" then key, `Int version else key, value)
             fields))
  | _ -> fail "a checkpoint is written as an object"
;;

let test_same_judgement_as_the_turn =
  in_session
  @@ fun ~session_dir ->
  agrees ~session_dir "no checkpoint";
  (* An earlier build's history: the turn starts fresh, so nothing of it is
     counted. The turn's first save puts the new history under the same
     session, and from then on the head counts that one. *)
  write_canonical ~session_dir (at_version (Agent_core.Checkpoint.checkpoint_version - 1));
  check bool "an earlier version starts fresh" true (turn_start ~session_dir = Starts_fresh);
  agrees ~session_dir "an earlier version";
  save ~session_dir ~boundary:Objects.Turn_closes ~turn_count:1 (turn_messages 1);
  check (pair int int) "the first save after it is the same session's history" (2, 0)
    (counts (read ~session_dir));
  agrees ~session_dir "after the first save";
  (* A later build's history and a head that is not one are not read as
     empty: the turn does not start from them either. *)
  write_canonical ~session_dir (at_version (Agent_core.Checkpoint.checkpoint_version + 1));
  check bool "a later version does not start" true (turn_start ~session_dir = Does_not_start);
  agrees ~session_dir "a later version";
  write_canonical ~session_dir "not a head";
  check bool "bytes that are not a head do not start" true
    (turn_start ~session_dir = Does_not_start);
  agrees ~session_dir "not a head"
;;

let () =
  run "keeper_turn_log_head"
    [ ( "head"
      , [ test_case "no checkpoint" `Quick test_no_checkpoint
        ; test_case "closed and open messages of saved turns" `Quick test_closed_and_open
        ; test_case "a run that starts in a segment" `Quick test_run_into_a_segment
        ; test_case "empty exactly when the turn starts fresh" `Quick
            test_same_judgement_as_the_turn
        ] )
    ]
;;
