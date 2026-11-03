(** A Keeper's and an installation's questions to the operator announce each
    change to their log, and a reader that answers the announcement sees the
    change: the question is open when its asking is heard, answered or
    withdrawn when that is heard. A refused write announces nothing. *)

open Masc
module Asks = Lane_addon_asks

let keeper = "announcing-asker"
let declaration_id = "quiz"

let require = function Ok value -> value | Error detail -> Alcotest.fail detail

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let field_of_frame ~field frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> None
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       (match List.assoc_opt "type" fields, List.assoc_opt field fields with
        | Some (`String event), Some (`String value) -> Some (event, value)
        | _ -> None)
     | _ -> None
     | exception Yojson.Json_error _ -> None)
;;

(* Calls [f] with a list that gains [read ()] each time [event] naming [who]
   in [field] is heard. *)
let hearing ~event ~field ~who ~read f =
  let id = Printf.sprintf "operator-asks-announce-%d-%s" (Unix.getpid ()) event in
  let heard = ref [] in
  Sse.subscribe_external ~id
    ~callback:(fun (ev : Sse.external_event) ->
      match field_of_frame ~field ev.Sse.ext_frame with
      | Some (name, value) when String.equal name event && String.equal value who ->
        heard := read () :: !heard
      | Some _ | None -> ())
    ();
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () -> f heard)
;;

let resolution_word = function
  | Keeper_ask.Open -> "open"
  | Keeper_ask.Answered_by _ -> "answered"
  | Keeper_ask.Withdrawn_because _ -> "withdrawn"
;;

let check_heard label expected heard =
  Alcotest.(check (list string)) label expected (List.rev !heard);
  heard := []
;;

let question () =
  let choice id label =
    match Keeper_ask.choice ~choice_id:id ~label () with
    | Ok choice -> choice
    | Error e -> Alcotest.fail (Keeper_ask.invalid_choice_to_string e)
  in
  match
    Keeper_ask.question ~question_id:"q1" ~header:"Route" ~prompt:"Which way?"
      ~choices:[ choice "a" "Now"; choice "b" "Later" ]
      ~mode:Keeper_ask.Single ~free_text:Keeper_ask.Choices_only
  with
  | Ok question -> question
  | Error e -> Alcotest.fail (Keeper_ask.invalid_question_to_string e)
;;

let responder =
  { Keeper_ask.surface = Surface_ref.Dashboard { session_id = None }
  ; actor_id = None
  ; display_name = None
  }
;;

let choose id = [ "q1", Keeper_ask.Chose { choice_ids = [ id ] } ]

let keeper_ask ~ask_id =
  let continuation = require (Keeper_continuation_channel.dashboard ~thread_id:"thread-1") in
  match
    Keeper_ask.ask ~ask_id ~keeper_name:keeper ~questions:[ question () ] ~continuation
      ~asked_at:1000.0 ()
  with
  | Ok ask -> ask
  | Error e -> Alcotest.fail (Keeper_ask.invalid_ask_to_string e)
;;

let test_each_keeper_question_write_announces_its_change () =
  let base_path = temp_dir "operator_asks_announce_keeper_" in
  let read ask_id () =
    match Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id with
    | Some resolution -> resolution_word resolution
    | None -> "absent"
  in
  hearing ~event:Keeper_ask_broadcast.asks_changed_event ~field:"name" ~who:keeper
    ~read:(read "ask-1") (fun heard ->
      require (Keeper_ask_store.record_ask ~base_path (keeper_ask ~ask_id:"ask-1"));
      check_heard "asked" [ "open" ] heard;
      ignore
        (require
           (Result.map_error Keeper_ask_store.answer_failure_to_string
              (Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
                 ~submissions:(choose "a") ~responder ~now:1100.)));
      check_heard "answered" [ "answered" ] heard;
      (match
         Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
           ~submissions:(choose "b") ~responder ~now:1200.
       with
       | Error (Keeper_ask_store.Already_answered _) -> ()
       | Ok _ | Error _ -> Alcotest.fail "a second answer must be refused");
      check_heard "a refused answer" [] heard);
  hearing ~event:Keeper_ask_broadcast.asks_changed_event ~field:"name" ~who:keeper
    ~read:(read "ask-2") (fun heard ->
      require (Keeper_ask_store.record_ask ~base_path (keeper_ask ~ask_id:"ask-2"));
      check_heard "asked again" [ "open" ] heard;
      require
        (Result.map_error Keeper_ask_store.withdraw_failure_to_string
           (Keeper_ask_store.withdraw ~base_path ~keeper_name:keeper ~ask_id:"ask-2"
              ~reason:"no longer needed" ~now:1300.));
      check_heard "withdrawn" [ "withdrawn" ] heard)
;;

let installation_ask ~ask_id =
  let questions =
    require
      (Asks.questions_of_json
         (`List [ Keeper_ask.question_to_json (question ()) ]))
  in
  require (Asks.ask ~ask_id ~declaration_id ~title:"Operator quiz" ~questions ~asked_at:1.0 ())
;;

let with_store f =
  let dir = temp_dir "operator_asks_announce_lane_" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f (Lane_addon_store.create ~root:(Filename.concat dir "lane-addons"))))
;;

let test_each_installation_question_write_announces_its_change () =
  with_store (fun store ->
    let read ask_id () =
      match List.assoc_opt ask_id (require (Asks.rows store ~declaration_id)) with
      | Some (_, resolution) -> resolution_word resolution
      | None -> "absent"
    in
    hearing ~event:Lane_addon_ask_broadcast.asks_changed_event ~field:"declaration_id"
      ~who:declaration_id ~read:(read "quiz-1") (fun heard ->
        Alcotest.(check bool) "recorded" true
          (Asks.record store (installation_ask ~ask_id:"quiz-1") = Ok Asks.Recorded);
        check_heard "asked" [ "open" ] heard;
        Alcotest.(check bool) "the same request again" true
          (Asks.record store (installation_ask ~ask_id:"quiz-1") = Ok Asks.Already_recorded);
        check_heard "a repeated request" [] heard;
        Alcotest.(check bool) "answered" true
          (Result.is_ok
             (Asks.answer store ~declaration_id ~ask_id:"quiz-1" ~submissions:(choose "a")
                ~responder ~now:2.0));
        check_heard "answered" [ "answered" ] heard;
        Alcotest.(check bool) "a second answer is refused" true
          (Result.is_error
             (Asks.answer store ~declaration_id ~ask_id:"quiz-1" ~submissions:(choose "b")
                ~responder ~now:3.0));
        check_heard "a refused answer" [] heard);
    hearing ~event:Lane_addon_ask_broadcast.asks_changed_event ~field:"declaration_id"
      ~who:declaration_id ~read:(read "quiz-2") (fun heard ->
        ignore (require (Asks.record store (installation_ask ~ask_id:"quiz-2")));
        check_heard "asked again" [ "open" ] heard;
        Alcotest.(check bool) "withdrawn" true
          (Result.is_ok
             (Asks.withdraw store ~declaration_id ~ask_id:"quiz-2" ~reason:"no longer needed"
                ~now:4.0));
        check_heard "withdrawn" [ "withdrawn" ] heard))
;;

let () =
  Alcotest.run
    "operator_asks_announce"
    [ ( "keeper questions"
      , [ Alcotest.test_case "each write announces its change" `Quick
            (fun () -> Eio_main.run (fun _ -> test_each_keeper_question_write_announces_its_change ()))
        ] )
    ; ( "installation questions"
      , [ Alcotest.test_case "each write announces its change" `Quick
            test_each_installation_question_write_announces_its_change
        ] )
    ]
;;
