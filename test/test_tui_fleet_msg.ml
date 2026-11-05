(* The fleet stream's answers are [Masc_tui_fleet_results.msg] and travel in
   [async_msg] as [Fleet_msg] (#48617). Every answer is a read that never
   waits for input. A view lands only while the stream is followed. A reader
   that ended is logged and leaves the stream idle. *)

module Protocol = Masc_tui_async_protocol
module Fleet = Masc_tui_fleet_results
module Stream = Masc_tui_fleet_stream
module Types = Masc_tui_types

let fresh () = Types.create_state ~workspace:"test" ~port:0 ~refresh_interval:0. ()

(* Every constructor named: a new answer has to be placed here before this
   test compiles. *)
let name : Fleet.msg -> string = function
  | Fleet.Fleet_stream_view _ -> "view"
  | Fleet.Fleet_stream_reader_ended _ -> "ended"

let answers () =
  [ Fleet.Fleet_stream_view Stream.Awaiting_first_reading
  ; Fleet.Fleet_stream_reader_ended "not read" ]

let test_every_answer_is_a_read () =
  List.iter
    (fun answer ->
      Alcotest.(check bool)
        (name answer ^ " is a read")
        true
        (Protocol.workspace_message_is_read (Protocol.Fleet_msg answer)))
    (answers ())

let test_no_answer_waits_for_input () =
  List.iter
    (fun answer ->
      Alcotest.(check bool)
        (name answer ^ " does not wait for input")
        false
        (Protocol.message_waits_for_input
           ~resource_read:(fun _ -> true)
           ~recovery_loaded:(fun _ -> true)
           (Protocol.Fleet_msg answer)))
    (answers ())

let followed_view (state : Types.state) =
  match state.fleet_stream_reader with
  | Types.Fleet_stream_following view -> Some view
  | Types.Fleet_stream_idle -> None

let unreachable = Stream.Unreachable { since = 1. }

let test_a_view_lands_only_while_followed () =
  let state = fresh () in
  Fleet.apply state (Fleet.Fleet_stream_view unreachable);
  Alcotest.(check bool) "an idle stream takes no view" true
    (Option.is_none (followed_view state));
  state.fleet_stream_reader <- Types.Fleet_stream_following Stream.Awaiting_first_reading;
  Fleet.apply state (Fleet.Fleet_stream_view unreachable);
  Alcotest.(check bool) "a followed stream shows the new view" true
    (followed_view state = Some unreachable)

(* The ring numbers its first entry 0, so an empty ring has no cursor. *)
let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> Some entry.Log.Ring.seq
  | [] -> None

let test_an_ended_reader_is_logged_and_left_idle () =
  let state = fresh () in
  state.fleet_stream_reader <- Types.Fleet_stream_following Stream.Awaiting_first_reading;
  let before = latest_ring_seq () in
  Fleet.apply state (Fleet.Fleet_stream_reader_ended "socket closed");
  Alcotest.(check bool) "the stream is idle" true (Option.is_none (followed_view state));
  let messages =
    List.map
      (fun (entry : Log.Ring.entry) -> entry.message)
      (Log.Ring.recent ~limit:10 ~module_filter:"Transport" ?since_seq:before ())
  in
  Alcotest.(check (list string)) "the end is logged with its detail"
    [ "tui_fleet_stream_reader_ended detail=socket closed" ] messages

let () =
  Alcotest.run "tui fleet msg"
    [ ( "classifiers"
      , [ Alcotest.test_case "every Fleet answer is a read" `Quick test_every_answer_is_a_read
        ; Alcotest.test_case "no Fleet answer waits for input" `Quick
            test_no_answer_waits_for_input ] )
    ; ( "apply"
      , [ Alcotest.test_case "a view lands only while the stream is followed" `Quick
            test_a_view_lands_only_while_followed
        ; Alcotest.test_case "an ended reader is logged and left idle" `Quick
            test_an_ended_reader_is_logged_and_left_idle ] ) ]
