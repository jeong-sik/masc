(* RFC-0412 stage 2 — since_seq replay. The journaled suffix re-folded from
   [Projection.initial] reproduces the live SSE bytes, frame ids are journal
   seqs (so entries that project to [None] leave gaps), the stream request
   parser admits [since_seq] only absent or as an integer >= 0, the reconnect dedup
   keeps an event the journal lost, and the handler-side replay never raises
   into the server switch. *)

open Masc
module E = Keeper_chat_events
module L = Keeper_chat_event_log
module Blocks = Keeper_chat_blocks
module Projection = Server_keeper_chat_agui_projection
module Replay = Server_keeper_chat_replay
module Stream = Server_routes_http_keeper_stream
module Pump = Server_sse_pump
module Sse = Server_sse_response

(* Seq 3 is a connector-only block: journaled, never on the SSE wire. *)
let events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-replay"; thread_id = "keeper:replay" }
  ; E.Text_message_start { message_id = "msg-replay"; role = E.Assistant }
  ; E.Text_delta {text="alpha "; response=Unobserved_scope (None)}
  ; E.Status_block { kind = Blocks.Continuation_checkpoint }
  ; E.Text_delta {text="beta "; response=Unobserved_scope (None)}
  ; E.Text_delta {text="gamma"; response=Unobserved_scope (None)}
  ; E.Reply_details
      { terminal_stream_scope = None; reply = "alpha beta gamma"
      ; turn_outcome = Keeper_turn_outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-replay" ~absolute_turn:1
      }
  ; E.Text_message_end
  ; E.Run_finished { run_id = "run-replay" }
  ]

let timestamps =
  List.mapi (fun i _ -> 1_762_300_000.0 +. (float_of_int i *. 0.25)) events

let journaled : L.journaled_event list =
  List.mapi
    (fun seq (ts, event) -> { L.seq; ts; event })
    (List.combine timestamps events)

let frame (seq, event) = Ag_ui.event_to_sse ~id:seq event

(* What the live adapter wrote: fold every event from [initial] with its own
   timestamp and tag each frame with the seq it was read at. *)
let live_frames () =
  let _, rev =
    List.fold_left
      (fun (projection, acc) (entry : L.journaled_event) ->
         let projection, projected =
           Projection.project
             ~timestamp:entry.ts
             ~redact_text:Fun.id

             projection
             entry.event
         in
         ( projection
         , match projected with
           | Some event -> (entry.seq, frame (entry.seq, event)) :: acc
           | None -> acc ))
      (Projection.initial, [])
      journaled
  in
  List.rev rev

let replay since_seq =
  Replay.replay ~redact_text:Fun.id ~since_seq journaled

let after seq = L.After_seq seq

let seqs pairs = List.map fst pairs

let test_suffix_reproduces_live_bytes () =
  let replayed = replay (after 4) |> List.map (fun pair -> fst pair, frame pair) in
  let expected = live_frames () |> List.filter (fun (seq, _) -> seq > 4) in
  Alcotest.(check (list int)) "suffix seqs" [ 5; 6; 7; 8 ] (seqs replayed);
  Alcotest.(check (list (pair int string)))
    "suffix frames are the live frames, byte for byte"
    expected
    replayed

let test_whole_turn_replays_everything () =
  let replayed = replay L.Whole_turn in
  Alcotest.(check (list int))
    "every projected seq; 3 is absent because a status block never hits the wire"
    [ 0; 1; 2; 4; 5; 6; 7; 8 ]
    (seqs replayed);
  Alcotest.(check (list string))
    "whole-turn frames equal the live frames"
    (live_frames () |> List.map snd)
    (List.map frame replayed)

let test_cut_at_or_past_the_end_replays_nothing () =
  Alcotest.(check (list int)) "at the last seq" [] (seqs (replay (after 8)));
  Alcotest.(check (list int)) "past the last seq" [] (seqs (replay (after 40)))

let test_frame_id_is_the_journal_seq () =
  List.iter
    (fun (seq, event) ->
       let text = frame (seq, event) in
       let prefix = Printf.sprintf "id: %d\n" seq in
       Alcotest.(check bool)
         (Printf.sprintf "frame %d starts with its id line" seq)
         true
         (String.length text >= String.length prefix
          && String.equal (String.sub text 0 (String.length prefix)) prefix))
    (replay L.Whole_turn)

(* The fold must start at [initial]: the delta at seq 5 carries the message
   and run identity established at seqs 0 and 1, before the cut. Folding the
   suffix alone from [initial] loses both, and the bytes show it. *)
let test_projection_state_before_the_cut_is_kept () =
  let from_cut_only =
    Replay.replay
      ~redact_text:Fun.id

      ~since_seq:L.Whole_turn
      (List.filter (fun (entry : L.journaled_event) -> entry.seq > 4) journaled)
    |> List.map frame
  in
  let full_fold = replay (after 4) |> List.map frame in
  Alcotest.(check bool)
    "a suffix-only fold produces different bytes"
    false
    (List.equal String.equal from_cut_only full_fold);
  Alcotest.(check (list string))
    "the full fold equals the live suffix"
    (live_frames () |> List.filter (fun (seq, _) -> seq > 4) |> List.map snd)
    full_fold

let body ?since_seq () =
  let base =
    {|"request_id":"req-replay-fixture","name":"luna","message":"hello"|}
  in
  match since_seq with
  | None -> "{" ^ base ^ "}"
  | Some raw -> "{" ^ base ^ {|,"since_seq":|} ^ raw ^ "}"

let parse_ok body =
  match Stream.For_testing.parse_request ~media_store:(Agent_core.History.Memory_store.create ()) body with
  | Ok payload -> payload
  | Error err -> Alcotest.fail ("expected parse to succeed: " ^ err)

let position_testable =
  let pp formatter position =
    Format.pp_print_string formatter (L.replay_position_to_string position)
  in
  Alcotest.testable pp ( = )

(* The wire: an absent [since_seq] is the whole turn, [n >= 0] is the last
   seq received. There is no sentinel integer for the whole turn. *)
let test_parser_reads_since_seq () =
  Alcotest.(check position_testable)
    "absent asks for the whole turn"
    L.Whole_turn
    (parse_ok (body ())).since_seq;
  Alcotest.(check position_testable)
    "a received seq"
    (L.After_seq 12)
    (parse_ok (body ~since_seq:"12" ())).since_seq;
  Alcotest.(check position_testable)
    "0 is after seq 0"
    (L.After_seq 0)
    (parse_ok (body ~since_seq:"0" ())).since_seq

let test_parser_rejects_malformed_since_seq () =
  List.iter
    (fun raw ->
       match Stream.For_testing.parse_request ~media_store:(Agent_core.History.Memory_store.create ()) (body ~since_seq:raw ()) with
       | Ok _ -> Alcotest.fail ("since_seq " ^ raw ^ " was accepted")
       | Error message ->
         Alcotest.(check bool)
           ("rejection names the field for " ^ raw)
           true
           (Astring.String.is_infix ~affix:"since_seq" message))
    [ "-1"; "-2"; {|"12"|}; "1.5"; "null" ]

(* The two spellings of a position are inverses: the request side omits the
   whole turn, the response side writes it as null. *)
let test_replay_position_round_trips_both_spellings () =
  List.iter
    (fun position ->
       Alcotest.(check (option position_testable))
         ("request spelling round-trips " ^ L.replay_position_to_string position)
         (Some position)
         (L.replay_position_of_wire (L.replay_position_to_wire position));
       Alcotest.(check (option position_testable))
         ("response spelling round-trips " ^ L.replay_position_to_string position)
         (Some position)
         (L.replay_position_of_yojson (L.replay_position_to_yojson position)))
    [ L.Whole_turn; L.After_seq 0; L.After_seq 12 ];
  Alcotest.(check (option position_testable))
    "a negative integer is no position on the request side"
    None
    (L.replay_position_of_wire (Some (-1)));
  Alcotest.(check (option position_testable))
    "a negative integer is no position on the response side"
    None
    (L.replay_position_of_yojson (`Int (-1)));
  Alcotest.(check (option position_testable))
    "a string is no position"
    None
    (L.replay_position_of_yojson (`String "12"));
  Alcotest.(check position_testable)
    "a seq past the position advances it"
    (L.After_seq 7)
    (L.replay_position_advance (L.After_seq 3) 7);
  Alcotest.(check position_testable)
    "a seq at or before the position leaves it"
    (L.After_seq 7)
    (L.replay_position_advance (L.After_seq 7) 7);
  Alcotest.(check position_testable)
    "any seq advances the whole turn"
    (L.After_seq 0)
    (L.replay_position_advance L.Whole_turn 0)

(* ---- handler side: typed reads, dedup, and the exception boundary ---- *)

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_base prefix f =
  let base_dir = temp_base_path prefix in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () -> f base_dir)

let keeper_name = "replay-keeper"
let operation_id = "req-replay-op"

let write_journal ~base_dir entries =
  let journal = L.open_journal ~base_dir ~keeper_name ~operation_id () in
  List.iter
    (fun (entry : L.journaled_event) -> L.append journal ~seq:entry.seq ~ts:entry.ts entry.event)
    entries;
  L.journal_path ~base_dir ~keeper_name ~operation_id

let test_read_result_names_missing_corrupt_and_unreadable () =
  with_base "keeper-chat-replay-read" (fun base_dir ->
    let path = L.journal_path ~base_dir ~keeper_name ~operation_id in
    (match L.read_journal_path_result path with
     | Error (L.Journal_unsupported_version version) -> Alcotest.fail (L.version_mismatch_to_string version)
     | Error L.Journal_missing -> ()
     | Error (L.Journal_unreadable d) -> Alcotest.fail ("missing read as unreadable: " ^ d)
     | Error (L.Journal_corrupt d) -> Alcotest.fail ("missing read as corrupt: " ^ d)
     | Ok _ -> Alcotest.fail "missing journal read as entries");
    let path = write_journal ~base_dir journaled in
    (match L.read_journal_path_result path with
     | Ok entries ->
       Alcotest.(check int) "every line decodes" (List.length journaled) (List.length entries)
     | Error _ -> Alcotest.fail "a written journal must read back");
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o600 path in
    output_string oc "this line is not an envelope\n";
    close_out oc;
    (match L.read_journal_path_result path with
     | Error (L.Journal_corrupt _) -> ()
     | Error (L.Journal_unsupported_version version) -> Alcotest.fail (L.version_mismatch_to_string version)
     | Error L.Journal_missing -> Alcotest.fail "corrupt read as missing"
     | Error (L.Journal_unreadable d) -> Alcotest.fail ("corrupt read as unreadable: " ^ d)
     | Ok _ -> Alcotest.fail "a corrupt line decoded");
    (* root reads a 0o000 file, so the classification cannot be observed there. *)
    if Unix.geteuid () <> 0
    then begin
      Unix.chmod path 0o000;
      Fun.protect
        ~finally:(fun () -> Unix.chmod path 0o600)
        (fun () ->
           match L.read_journal_path_result path with
           | Error (L.Journal_unreadable _) -> ()
           | Error (L.Journal_unsupported_version version) -> Alcotest.fail (L.version_mismatch_to_string version)
           | Error L.Journal_missing -> Alcotest.fail "unreadable read as missing"
           | Error (L.Journal_corrupt d) -> Alcotest.fail ("unreadable read as corrupt: " ^ d)
           | Ok _ -> Alcotest.fail "an unreadable file yielded entries")
    end)

(* Seq 4's append failed (fail-open), 5's succeeded; the client reconnects
   with since_seq = 3. The replay wrote 5. The live sink still holds 4, and
   4 must go out: a highest-seq mark would have dropped it. *)
let test_dedup_keeps_the_event_the_journal_lost () =
  let replayed = Hashtbl.create 4 in
  Hashtbl.replace replayed 5 ();
  let is_new = Stream.For_testing.live_event_is_new ~replayed in
  Alcotest.(check bool) "seq 4 was never replayed, so it is new" true (is_new (Some 4));
  Alcotest.(check bool) "seq 5 was replayed, so it is a duplicate" false (is_new (Some 5));
  Alcotest.(check bool) "seq 6 arrives live only" true (is_new (Some 6));
  Alcotest.(check bool) "a seq-less settle event always passes" true (is_new None)

(* The fixture's live events as the live sink hands them over: the projected
   event with the seq the bus gave it. *)
let live_events () =
  let _, rev =
    List.fold_left
      (fun (projection, acc) (entry : L.journaled_event) ->
         let projection, projected =
           Projection.project ~timestamp:entry.ts ~redact_text:Fun.id projection entry.event
         in
         ( projection
         , match projected with
           | Some event -> (entry.seq, event) :: acc
           | None -> acc ))
      (Projection.initial, [])
      journaled
  in
  List.rev rev

let live_event_of_type event_type =
  match
    List.find_opt (fun (_, (event : Ag_ui.event)) -> event.event_type = event_type) (live_events ())
  with
  | Some (_, event) -> event
  | None -> Alcotest.fail "the live fixture lacks the event type"

(* The SSE frames in what one send carried, each with its blank-line
   terminator: the pump writes the frames already queued in one send. *)
let split_frames bytes =
  let length = String.length bytes in
  let rec go ~start ~pos acc =
    match String.index_from_opt bytes pos '\n' with
    | Some at when at + 1 < length && bytes.[at + 1] = '\n' ->
      go ~start:(at + 2) ~pos:(at + 2) (String.sub bytes start (at + 2 - start) :: acc)
    | Some at -> go ~start ~pos:(at + 1) acc
    | None -> List.rev acc
  in
  go ~start:0 ~pos:0 []

let ending_name = function
  | Pump.Client_gone -> "Client_gone"
  | Pump.Source_stopped -> "Source_stopped"
  | Pump.Stalled -> "Stalled"
  | Pump.Finished -> "Finished"

(* Runs the stream's own step through the real pump over [items] already
   queued. Returns every frame written, in order, and how the stream ended. *)
let serve_chat ~replayed items =
  Eio_main.run (fun env ->
    let queue = Pump.Queue.create ~max_queued_events:64 in
    let written = ref [] in
    let send bytes = written := List.rev_append (split_frames bytes) !written; Sse.Written in
    List.iter (Pump.Queue.push queue) items;
    let ending =
      Pump.run ~source:(Pump.Queue.source queue)
        ~step:(Stream.For_testing.keeper_chat_step ~replayed)
        ~idle:(fun () -> Pump.Finish)
        ~clock:(Eio.Stdenv.clock env)
        ~ping_interval_s:30.0
        ~closed:Eio.Fiber.await_cancel
        ~send
    in
    List.rev !written, ending_name ending)

let live_item (seq, event) = Stream.For_testing.Live (Some seq, event)

let acceptance = "event: accepted\n\n"

(* A ping interval no queued event waits for. A stream that should have ended
   and asks [idle] fails the test instead. *)
let short_ping_interval_s = 0.05

let idle_must_not_be_asked () = Alcotest.fail "the stream waited for more events"

(* Runs the handler's code after an accepted submit with a [send] that
   records each frame. [after_send n] gives the live events the sink
   publishes right after the [n]th frame (the acceptance is the first), and
   [closed_from n] makes the client leave at the [n]th frame. *)
let serve_accepted ?(queued = []) ?(after_send = fun _ -> []) ?closed_from
    ?(missed_terminal = fun ~replayed:_ -> None) ?(settled = false) ~replay () =
  Eio_main.run (fun env ->
    let queue = Pump.Queue.create ~max_queued_events:64 in
    List.iter (Pump.Queue.push queue) queued;
    let written = ref [] and sends = ref 0 in
    let send frame =
      incr sends;
      match closed_from with
      | Some n when !sends >= n -> Sse.Closed
      | Some _ | None ->
        written := List.rev_append (split_frames frame) !written;
        List.iter (Pump.Queue.push queue) (after_send !sends);
        Sse.Written
    in
    let ending =
      (* The stub response never closes; the stream ends through [send]. *)
      Stream.For_testing.serve_accepted_chat ~send ~closed:Eio.Fiber.await_cancel ~queue
        ~acceptance_frame:acceptance
        ~replay:(fun () -> replay) ~missed_terminal ~settled ~idle:idle_must_not_be_asked
        ~clock:(Eio.Stdenv.clock env) ~ping_interval_s:short_ping_interval_s
    in
    List.rev !written, Option.map ending_name ending)

(* A reconnect replays the first three live seqs while the live sink keeps
   publishing: two events were queued before the replay began and the rest
   arrive after its first frame. Each replayed seq goes out once, from the
   replay, and the stream writes byte-for-byte what the live adapter wrote,
   ending at the turn's terminal. *)
let test_live_events_queued_during_the_replay_follow_it () =
  let live = live_events () in
  let replay = List.filteri (fun i _ -> i < 3) live in
  let queued = List.map live_item (List.filteri (fun i _ -> i < 2) live) in
  let arriving = List.map live_item (List.filteri (fun i _ -> i >= 2) live) in
  let written, ending =
    serve_accepted ~queued ~after_send:(fun n -> if n = 2 then arriving else []) ~replay ()
  in
  Alcotest.(check (option string)) "the live terminal ends the stream" (Some "Finished") ending;
  Alcotest.(check (list string))
    "the acceptance, the replay, then the live frames once each"
    (acceptance :: List.map snd (live_frames ())) written

let delta () = live_event_of_type Ag_ui.Text_message_content
let finished () = live_event_of_type Ag_ui.Run_finished

let failure =
  Ag_ui.run_error ~thread_id:"keeper:replay" ~run_id:"keeper-operation-run-op"
    ~message:"failed" ~code:"failed" ()

(* The missed terminal is asked after the replay, with the seqs it wrote, and
   goes out behind the live event that arrived during the replay. *)
let test_the_missed_terminal_follows_the_live_events_of_the_replay () =
  let delta = delta () in
  let asked_with = ref [] in
  let missed_terminal ~replayed =
    asked_with := Hashtbl.fold (fun seq () acc -> seq :: acc) replayed [];
    Some failure
  in
  let written, ending =
    serve_accepted ~replay:[ 0, delta ] ~missed_terminal
      ~after_send:(fun n -> if n = 2 then [ Stream.For_testing.Live (Some 1, delta) ] else [])
      ()
  in
  Alcotest.(check (list int)) "asked with the replayed seqs" [ 0 ] !asked_with;
  Alcotest.(check (option string)) "the missed terminal ends the stream" (Some "Finished") ending;
  Alcotest.(check (list string)) "acceptance, replay, live, then the terminal without a seq"
    [ acceptance; Ag_ui.event_to_sse ~id:0 delta; Ag_ui.event_to_sse ~id:1 delta
    ; Ag_ui.event_to_sse failure ]
    written

(* An operation that had settled, or a replay that wrote the terminal, ends
   the stream once the live events queued during the replay are out. *)
let test_a_settled_turn_ends_after_the_live_events_of_the_replay () =
  let delta = delta () and finished = finished () in
  let arriving n = if n = 2 then [ Stream.For_testing.Live (Some 1, delta) ] else [] in
  let written, ending = serve_accepted ~replay:[ 0, delta ] ~settled:true ~after_send:arriving () in
  Alcotest.(check (option string)) "a settled operation ends the stream" (Some "Finished") ending;
  Alcotest.(check (list string)) "acceptance, replay, then the queued live event"
    [ acceptance; Ag_ui.event_to_sse ~id:0 delta; Ag_ui.event_to_sse ~id:1 delta ] written;
  let arriving n = if n = 2 then [ Stream.For_testing.Live (Some 2, delta) ] else [] in
  let written, ending =
    serve_accepted ~replay:[ 0, delta; 1, finished ] ~after_send:arriving ()
  in
  Alcotest.(check (option string)) "a replayed terminal ends the stream" (Some "Finished") ending;
  Alcotest.(check (list string)) "the replay with its terminal, then the queued live event"
    [ acceptance; Ag_ui.event_to_sse ~id:0 delta; Ag_ui.event_to_sse ~id:1 finished
    ; Ag_ui.event_to_sse ~id:2 delta ]
    written

(* A client gone during the replay ends the stream there: nothing more is
   written and the missed terminal is not looked up. *)
let test_a_client_gone_during_the_replay_ends_before_the_live_part () =
  let delta = delta () in
  let asked = ref false in
  let written, ending =
    serve_accepted ~replay:[ 0, delta; 1, delta ] ~closed_from:3
      ~missed_terminal:(fun ~replayed:_ -> asked := true; None)
      ~queued:[ Stream.For_testing.Live (Some 2, delta) ] ()
  in
  Alcotest.(check (option string)) "no live part" None ending;
  Alcotest.(check bool) "the missed terminal was not looked up" false !asked;
  Alcotest.(check (list string)) "the acceptance and the first replay frame"
    [ acceptance; Ag_ui.event_to_sse ~id:0 delta ] written

(* How long the test waits for the submit while the retry frame has no
   answer. The submit takes no time, so reaching it means the submit waited
   for the frame. *)
let submit_patience_s = 2.0

(* A client that left before the head went out leaves the retry frame
   without an answer until the stall bound. The durable submit runs during
   that wait, and the answer comes back with the submit's result. *)
let test_the_submit_runs_while_the_retry_frame_waits () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let answer, give_answer = Eio.Promise.create () in
    let submitted, mark_submitted = Eio.Promise.create () in
    let frames = ref [] in
    let send frame =
      frames := frame :: !frames;
      Eio.Promise.await answer
    in
    let (retry, accepted), submitted_during_the_wait =
      Eio.Fiber.pair
        (fun () ->
          Stream.For_testing.send_retry_beside_submit ~send ~retry_frame:"retry: 1\n\n"
            (fun () ->
              Eio.Promise.resolve mark_submitted ();
              "accepted"))
        (fun () ->
          let during =
            match
              Eio.Time.with_timeout clock submit_patience_s (fun () ->
                Ok (Eio.Promise.await submitted))
            with
            | Ok () -> true
            | Error `Timeout -> false
          in
          Eio.Promise.resolve give_answer Sse.Stalled;
          during)
    in
    Alcotest.(check bool) "the submit ran while the frame waited" true submitted_during_the_wait;
    Alcotest.(check (list string)) "only the retry frame was sent" [ "retry: 1\n\n" ] !frames;
    Alcotest.(check bool) "the frame's answer comes back" true (retry = Sse.Stalled);
    Alcotest.(check string) "the submit's result comes back" "accepted" accepted)

let idle_name = function
  | Pump.Keepalive -> "Keepalive"
  | Pump.Quiet -> "Quiet"
  | Pump.Finish -> "Finish"

(* A quiet stream ends when its client is gone without reading the operation,
   keeps a queued or running operation's stream alive, ends a settled one so
   the TUI settles it from the record, and waits when the record is
   unreadable. *)
let test_a_quiet_stream_follows_the_client_and_the_operation () =
  let idle ?(client_gone = false) state =
    idle_name
      (Stream.For_testing.keeper_chat_idle ~client_gone:(fun () -> client_gone)
         ~operation_state:(fun () -> state))
  in
  let module Op = Keeper_owner.Chat_operation in
  Alcotest.(check string) "the client is gone"
    "Finish"
    (idle_name
       (Stream.For_testing.keeper_chat_idle ~client_gone:(fun () -> true)
          ~operation_state:(fun () -> Alcotest.fail "the operation was read")));
  Alcotest.(check string) "queued" "Keepalive" (idle (Some Op.Queued));
  Alcotest.(check string) "running" "Keepalive" (idle (Some (Op.Running { started_at = 1.0 })));
  Alcotest.(check string) "settled" "Finish"
    (idle (Some (Op.Succeeded { completed_at = 2.0; outcome_ref = "receipt" })));
  Alcotest.(check string) "unreadable" "Quiet" (idle None)

(* Seq 4's append failed (fail-open) and the replay wrote 5. Live 5 is the
   replay's duplicate; 4, 6 and an event that never went through the bus go
   out. *)
let test_the_step_drops_only_what_the_replay_wrote () =
  let replayed = Hashtbl.create 4 in
  Hashtbl.replace replayed 5 ();
  let delta = live_event_of_type Ag_ui.Text_message_content in
  let written, ending =
    serve_chat ~replayed
      Stream.For_testing.
        [ Live (Some 4, delta); Live (Some 5, delta); Live (Some 6, delta); Live (None, delta)
        ; Settled ]
  in
  Alcotest.(check string) "Settled ends the stream" "Finished" ending;
  Alcotest.(check (list string))
    "replay duplicates drop; journal gaps and seq-less events survive"
    [ Ag_ui.event_to_sse ~id:4 delta; Ag_ui.event_to_sse ~id:6 delta; Ag_ui.event_to_sse delta ]
    written

(* The handler queues a missed terminal and [Settled] after the live events
   that arrived during its replay, and the live sink may push more after
   them. The stream writes the earlier live frames, then the missed terminal
   without a seq, and nothing after it. A live terminal ends the stream the
   same way, and [Settled] ends it without a frame. *)
let test_terminals_and_settled_end_the_stream () =
  let replayed = Hashtbl.create 1 in
  let delta = live_event_of_type Ag_ui.Text_message_content in
  let finished = live_event_of_type Ag_ui.Run_finished in
  let failure =
    Ag_ui.run_error ~thread_id:"keeper:replay" ~run_id:"keeper-operation-run-op"
      ~message:"failed" ~code:"failed" ()
  in
  let open Stream.For_testing in
  let written, ending =
    serve_chat ~replayed
      [ Live (Some 7, delta); Missed_terminal failure; Live (Some 8, delta); Settled ]
  in
  Alcotest.(check string) "a missed terminal ends the stream" "Finished" ending;
  Alcotest.(check (list string)) "live first, then the terminal without a seq"
    [ Ag_ui.event_to_sse ~id:7 delta; Ag_ui.event_to_sse failure ] written;
  let written, ending =
    serve_chat ~replayed [ Live (Some 9, finished); Live (Some 10, delta); Settled ]
  in
  Alcotest.(check string) "a live terminal ends the stream" "Finished" ending;
  Alcotest.(check (list string)) "nothing after a live terminal"
    [ Ag_ui.event_to_sse ~id:9 finished ] written;
  let written, ending = serve_chat ~replayed [ Settled; Live (Some 11, delta) ] in
  Alcotest.(check string) "Settled ends the stream" "Finished" ending;
  Alcotest.(check (list string)) "Settled writes nothing" [] written

let test_handler_replay_matches_the_pure_fold () =
  with_base "keeper-chat-replay-handler" (fun base_dir ->
    ignore (write_journal ~base_dir journaled : string);
    let frames =
      Stream.For_testing.journal_replay_frames
        ~base_path:base_dir
        ~keeper_name
        ~operation_id
        ~since_seq:(after 4)
      |> List.map frame
    in
    (* No secret is registered under this base, so the redaction the handler
       takes is the identity on this fixture and the bytes must match. *)
    Alcotest.(check (list string))
      "handler replay equals the pure fold"
      (replay (after 4) |> List.map frame)
      frames)

let test_handler_replay_degrades_to_nothing () =
  with_base "keeper-chat-replay-degrade" (fun base_dir ->
    let replay_frames () =
      Stream.For_testing.journal_replay_frames
        ~base_path:base_dir
        ~keeper_name
        ~operation_id
        ~since_seq:L.Whole_turn
    in
    Alcotest.(check int) "missing journal replays nothing" 0 (List.length (replay_frames ()));
    let path = write_journal ~base_dir journaled in
    (* An append cut before its newline is not a row: the complete rows
       replay, so a client resumes from the last seq it was handed. *)
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o600 path in
    output_string oc "{\"v\":2,\"seq\":99,\"ts\":9.0,\"event\":{\"type\":\"text_de";
    close_out oc;
    Alcotest.(check (list string))
      "a torn tail replays the complete rows"
      (replay L.Whole_turn |> List.map frame)
      (replay_frames () |> List.map frame);
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o600 path in
    output_string oc "lta\",\"delta\":\"x\"}}\n{\"v\":2,\"seq\":100}\n";
    close_out oc;
    Alcotest.(check int)
      "corrupt journal replays nothing rather than a prefix"
      0
      (List.length (replay_frames ())));
  (* An empty internal diagnostic is still an actual error fact. The public
     projection supplies its fixed safe message and keeps the terminal. *)
  with_base "keeper-chat-replay-refused" (fun base_dir ->
    ignore
      (write_journal
         ~base_dir
         [ { L.seq = 0; ts = 1.0; event = E.Run_started { run_id = "r"; thread_id = "keeper:r" } }
         ; { L.seq = 1; ts = 1.5; event = E.Event_error { message = "" } }
         ]
        : string);
    match
      Stream.For_testing.journal_replay_frames
        ~base_path:base_dir
        ~keeper_name
        ~operation_id
        ~since_seq:L.Whole_turn
    with
    | frames ->
      Alcotest.(check int) "a safe terminal remains replayable" 2 (List.length frames)
    | exception exn ->
      Alcotest.fail ("replay raised into the caller: " ^ Printexc.to_string exn))

let () =
  Alcotest.run
    "keeper_chat_replay"
    [ ( "replay"
      , [ Alcotest.test_case "suffix reproduces live bytes" `Quick
            test_suffix_reproduces_live_bytes
        ; Alcotest.test_case "the whole turn replays everything" `Quick
            test_whole_turn_replays_everything
        ; Alcotest.test_case "cut at or past the end replays nothing" `Quick
            test_cut_at_or_past_the_end_replays_nothing
        ; Alcotest.test_case "frame id is the journal seq" `Quick
            test_frame_id_is_the_journal_seq
        ; Alcotest.test_case "projection state before the cut is kept" `Quick
            test_projection_state_before_the_cut_is_kept
        ] )
    ; ( "request"
      , [ Alcotest.test_case "parser reads since_seq" `Quick
            test_parser_reads_since_seq
        ; Alcotest.test_case "parser rejects malformed since_seq" `Quick
            test_parser_rejects_malformed_since_seq
        ; Alcotest.test_case "a position round-trips both wire spellings" `Quick
            test_replay_position_round_trips_both_spellings
        ] )
    ; ( "handler"
      , [ Alcotest.test_case "read result names missing, corrupt and unreadable" `Quick
            test_read_result_names_missing_corrupt_and_unreadable
        ; Alcotest.test_case "dedup keeps the event the journal lost" `Quick
            test_dedup_keeps_the_event_the_journal_lost
        ; Alcotest.test_case "live events queued during the replay follow it" `Quick
            test_live_events_queued_during_the_replay_follow_it
        ; Alcotest.test_case "the missed terminal follows the live events of the replay" `Quick
            test_the_missed_terminal_follows_the_live_events_of_the_replay
        ; Alcotest.test_case "a settled turn ends after the live events of the replay" `Quick
            test_a_settled_turn_ends_after_the_live_events_of_the_replay
        ; Alcotest.test_case "a client gone during the replay ends before the live part" `Quick
            test_a_client_gone_during_the_replay_ends_before_the_live_part
        ; Alcotest.test_case "the submit runs while the retry frame waits" `Quick
            test_the_submit_runs_while_the_retry_frame_waits
        ; Alcotest.test_case "a quiet stream follows the client and the operation" `Quick
            test_a_quiet_stream_follows_the_client_and_the_operation
        ; Alcotest.test_case "the step drops only what the replay wrote" `Quick
            test_the_step_drops_only_what_the_replay_wrote
        ; Alcotest.test_case "terminals and Settled end the stream" `Quick
            test_terminals_and_settled_end_the_stream
        ; Alcotest.test_case "handler replay matches the pure fold" `Quick
            test_handler_replay_matches_the_pure_fold
        ; Alcotest.test_case "handler replay degrades to nothing" `Quick
            test_handler_replay_degrades_to_nothing
        ] )
    ]
