(* RFC-0412 stage 2 — since_seq replay. The journaled suffix re-folded from
   [Projection.initial] reproduces the live SSE bytes, frame ids are journal
   seqs (so entries that project to [None] leave gaps), and the stream request
   parser admits [since_seq] only as an integer >= -1. *)

open Masc
module E = Keeper_chat_events
module L = Keeper_chat_event_log
module Blocks = Keeper_chat_blocks
module Projection = Server_keeper_chat_agui_projection
module Replay = Server_keeper_chat_replay
module Stream = Server_routes_http_keeper_stream

(* Seq 3 is a connector-only block: journaled, never on the SSE wire. *)
let events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-replay"; thread_id = "keeper:replay" }
  ; E.Text_message_start { message_id = "msg-replay"; role = E.Assistant }
  ; E.Text_delta "alpha "
  ; E.Status_block { kind = Blocks.Continuation_checkpoint }
  ; E.Text_delta "beta "
  ; E.Text_delta "gamma"
  ; E.Reply_details
      { reply = "alpha beta gamma"
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
             ~redact_json:Fun.id
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
  Replay.replay ~redact_text:Fun.id ~redact_json:Fun.id ~since_seq journaled

let seqs pairs = List.map fst pairs

let test_suffix_reproduces_live_bytes () =
  let replayed = replay 4 |> List.map (fun pair -> fst pair, frame pair) in
  let expected = live_frames () |> List.filter (fun (seq, _) -> seq > 4) in
  Alcotest.(check (list int)) "suffix seqs" [ 5; 6; 7; 8 ] (seqs replayed);
  Alcotest.(check (list (pair int string)))
    "suffix frames are the live frames, byte for byte"
    expected
    replayed

let test_minus_one_replays_the_whole_turn () =
  let replayed = replay (-1) in
  Alcotest.(check (list int))
    "every projected seq; 3 is absent because a status block never hits the wire"
    [ 0; 1; 2; 4; 5; 6; 7; 8 ]
    (seqs replayed);
  Alcotest.(check (list string))
    "whole-turn frames equal the live frames"
    (live_frames () |> List.map snd)
    (List.map frame replayed)

let test_cut_at_or_past_the_end_replays_nothing () =
  Alcotest.(check (list int)) "at the last seq" [] (seqs (replay 8));
  Alcotest.(check (list int)) "past the last seq" [] (seqs (replay 40))

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
    (replay (-1))

(* The fold must start at [initial]: the delta at seq 5 carries the message
   and run identity established at seqs 0 and 1, before the cut. Folding the
   suffix alone from [initial] loses both, and the bytes show it. *)
let test_projection_state_before_the_cut_is_kept () =
  let from_cut_only =
    Replay.replay
      ~redact_text:Fun.id
      ~redact_json:Fun.id
      ~since_seq:(-1)
      (List.filter (fun (entry : L.journaled_event) -> entry.seq > 4) journaled)
    |> List.map frame
  in
  let full_fold = replay 4 |> List.map frame in
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
  match Stream.For_testing.parse_request body with
  | Ok payload -> payload
  | Error err -> Alcotest.fail ("expected parse to succeed: " ^ err)

let test_parser_reads_since_seq () =
  Alcotest.(check (option int)) "absent" None (parse_ok (body ())).since_seq;
  Alcotest.(check (option int))
    "a received seq"
    (Some 12)
    (parse_ok (body ~since_seq:"12" ())).since_seq;
  Alcotest.(check (option int))
    "-1 asks for the whole turn"
    (Some (-1))
    (parse_ok (body ~since_seq:"-1" ())).since_seq

let test_parser_rejects_malformed_since_seq () =
  List.iter
    (fun raw ->
       match Stream.For_testing.parse_request (body ~since_seq:raw ()) with
       | Ok _ -> Alcotest.fail ("since_seq " ^ raw ^ " was accepted")
       | Error message ->
         Alcotest.(check bool)
           ("rejection names the field for " ^ raw)
           true
           (Astring.String.is_infix ~affix:"since_seq" message))
    [ "-2"; {|"12"|}; "1.5"; "null" ]

let () =
  Alcotest.run
    "keeper_chat_replay"
    [ ( "replay"
      , [ Alcotest.test_case "suffix reproduces live bytes" `Quick
            test_suffix_reproduces_live_bytes
        ; Alcotest.test_case "-1 replays the whole turn" `Quick
            test_minus_one_replays_the_whole_turn
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
        ] )
    ]
