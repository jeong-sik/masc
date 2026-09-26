(* The Stagehand backend with a fake opener and a fake call. The mock clock
   advances only when every fiber is blocked, so [settle] returns once the
   backend has run as far as it can. *)
open Alcotest
module Backend = Masc.Browser_stagehand_backend
module Wire = Masc.Browser_stagehand_wire
module Session = Masc.Browser_stagehand_session
module Lane = Browser_lane

(* Shorter than the backend's close wait, so the clock reaches it only after
   every other fiber has blocked. *)
let settle_s = 0.001

type fake_session = { mutable stopped : bool; log : Session.event -> unit }
type opening = Opens | Fails | Raises

exception Opener_bug
exception Close_bug

(* How the fake runtime meets stagehand.close. *)
type closing = Answers | Silent | Raises_on_close

type behaviour =
  { mutable opening : opening
  ; mutable open_gate : unit Eio.Promise.t option
  ; mutable close : closing
  ; mutable act_cancelled : bool
  ; mutable answer_on_cancel : bool
  }

type harness =
  { backend : fake_session Backend.t
  ; sessions : fake_session list ref
  ; behaviour : behaviour
  ; settle : unit -> unit
  ; past_the_sentence_deadline : unit -> unit
  }

let page = `Assoc [ "page_id", `String "P"; "url", `String "http://127.0.0.1:1/" ]

let summary =
  `Assoc [ "value", `String {|{"url":"http://127.0.0.1:1/","title":"Shop","viewport":null}|} ]
;;

let with_backend ?(configure = ignore) f =
  Eio_mock.Backend.run_full
  @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run
  @@ fun sw ->
  let behaviour =
    { opening = Opens; open_gate = None; close = Answers
    ; act_cancelled = false; answer_on_cancel = false }
  in
  configure behaviour;
  let sessions = ref [] in
  let never, _ = Eio.Promise.create () in
  let open_session ~sw ~headless:_ ~log =
    Option.iter Eio.Promise.await behaviour.open_gate;
    match behaviour.opening with
    | Fails -> Error "no Chromium"
    | Raises -> raise Opener_bug
    | Opens ->
      let session = { stopped = false; log } in
      Eio.Switch.on_release sw (fun () -> session.stopped <- true);
      sessions := session :: !sessions;
      Ok (session, `Assoc [ "pages", `List [ page ] ])
  in
  let call session request =
    match request with
    | Wire.Context_pages -> Ok (`List [ page ])
    | Wire.Context_active_page -> Ok page
    | Wire.Page_evaluate _ -> Ok summary
    | Wire.Close ->
      (match behaviour.close with
       | Answers -> Ok (`Assoc [ "closed", `Bool true ])
       | Silent -> Eio.Promise.await never
       | Raises_on_close -> raise Close_bug)
    | Wire.Act _ ->
      (match Eio.Promise.await never with
       | answer -> answer
       | exception (Eio.Cancel.Cancelled _ as exn) ->
         behaviour.act_cancelled <- true;
         if behaviour.answer_on_cancel then
           session.log (Session.Abandoned_call_ended
             { method_ = "stagehand.act"; rejected = false });
         raise exn)
    | Wire.Observe _ | Wire.Extract _ | Wire.Page_goto _ | Wire.Page_screenshot _ ->
      failf "the backend sent %s" (Wire.method_name request)
  in
  let backend = Backend.create ~sw ~clock ~open_session ~call ~pid:(fun _ -> 42) ~log:ignore in
  f
    { backend
    ; sessions
    ; behaviour
    ; settle = (fun () -> Eio.Time.sleep clock settle_s)
    ; past_the_sentence_deadline =
        (fun () -> Eio.Time.sleep clock ((float_of_int (Wire.timeout_ms Wire.sentence_timeout) /. 1000.) +. 1.))
    }
;;

let data = function
  | Lane.Answered (`Assoc fields) ->
    (match List.assoc_opt "ok" fields, List.assoc_opt "data" fields with
     | Some (`Bool true), Some data -> data
     | _ -> fail "an answer without ok data")
  | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ | Lane.Rejected_before_effect _ ->
    fail "the verb was not served"
;;

let flag key json = Yojson.Safe.Util.(member key json |> to_bool)
let text key json = Yojson.Safe.Util.(member key json |> to_string)
let open_ = Lane.Session_open { headless = Some true }
let is_open h = flag "open" (data (Backend.execute h.backend Lane.Session_status))

let refused = function
  | Lane.Refused _ -> true
  | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Rejected_before_effect _ -> false
;;

let the_session h =
  match !(h.sessions) with
  | [ session ] -> session
  | sessions -> failf "expected one session, got %d" (List.length sessions)
;;

(* Starts [verb] on a fiber of its own, lets it reach its wait, and leaves,
   as the lane deadline does. *)
let leave_during h verb =
  try
    Eio.Switch.run (fun caller ->
      Eio.Fiber.fork ~sw:caller (fun () -> ignore (Backend.execute h.backend verb));
      h.settle ();
      Eio.Switch.fail caller Exit)
  with
  | Exit -> ()
;;

let test_lifecycle () =
  with_backend
  @@ fun h ->
  check bool "closed at start" false (is_open h);
  check bool "open starts a session" false (flag "reused" (data (Backend.execute h.backend open_)));
  check bool "a second open reuses it" true (flag "reused" (data (Backend.execute h.backend open_)));
  let status = data (Backend.execute h.backend Lane.Session_status) in
  check int "status names the browser pid" 42 Yojson.Safe.Util.(member "pid" status |> to_int);
  (match data (Backend.execute h.backend Lane.Tabs_list) with
   | `List [ _ ] -> ()
   | _ -> fail "the open session lists its page");
  let closed = data (Backend.execute h.backend Lane.Session_close) in
  check string "the runtime was asked to close" "closed" (text "runtime" closed);
  check bool "the browser stopped" true (the_session h).stopped;
  check bool "closed again" false (is_open h);
  check bool "closing a closed session answers closed" true
    (flag "closed" (data (Backend.execute h.backend Lane.Session_close)))
;;

let test_page_verb_without_a_session () =
  with_backend
  @@ fun h ->
  match Backend.execute h.backend Lane.Tabs_list with
  | Lane.Rejected_before_effect _ -> ()
  | _ -> fail "a page verb with no session is refused before effect"
;;

let test_open_failures () =
  with_backend ~configure:(fun behaviour -> behaviour.opening <- Fails)
  @@ fun h ->
  check bool "a failed open is refused" true (refused (Backend.execute h.backend open_));
  h.settle ();
  check bool "and leaves the backend closed" false (is_open h);
  check bool "closed, not opening" false
    (Yojson.Safe.Util.member "opening" (data (Backend.execute h.backend Lane.Session_status)) = `Bool true);
  h.behaviour.opening <- Raises;
  check bool "an opener that raises is refused" true (refused (Backend.execute h.backend open_));
  h.behaviour.opening <- Opens;
  check bool "the backend still opens afterwards" false (flag "reused" (data (Backend.execute h.backend open_)))
;;

let test_open_outlives_its_caller () =
  let gate, release_gate = Eio.Promise.create () in
  with_backend ~configure:(fun behaviour -> behaviour.open_gate <- Some gate)
  @@ fun h ->
  leave_during h open_;
  Eio.Promise.resolve release_gate ();
  h.settle ();
  check bool "the open finished after its caller left" true (is_open h);
  check bool "its browser is running" false (the_session h).stopped
;;

(* The session is shared: a sentence whose caller left keeps it open while
   the extension may still answer, and retires it only once the sentence's
   own deadline has passed without an answer. *)
let test_sentence_caller_retires_its_session () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let first = the_session h in
  leave_during h (Lane.Page_instruct { tab_id = 0; instruction = "click Buy" });
  h.settle ();
  check bool "the call was cancelled with its caller" true h.behaviour.act_cancelled;
  check bool "the session outlives its caller leaving" false first.stopped;
  check bool "and stays open for the other callers" true (is_open h);
  h.past_the_sentence_deadline ();
  check bool "an unanswered sentence retires its session after its deadline" true first.stopped;
  check bool "the backend is closed" false (is_open h);
  check bool "the next open makes a new session" false (flag "reused" (data (Backend.execute h.backend open_)));
  check int "two distinct sessions existed" 2 (List.length !(h.sessions))
;;

(* A sentence the extension answers after its caller left leaves the session
   open for everyone else. *)
let test_an_answered_sentence_keeps_the_session () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let first = the_session h in
  leave_during h (Lane.Page_instruct { tab_id = 0; instruction = "click Buy" });
  h.settle ();
  first.log (Session.Abandoned_call_ended { method_ = "stagehand.act"; rejected = false });
  h.past_the_sentence_deadline ();
  check bool "the answered sentence stopped nothing" false first.stopped;
  check bool "the session is still open" true (is_open h);
  check bool "an open reuses it" true (flag "reused" (data (Backend.execute h.backend open_)))
;;

(* The reply can arrive while the losing work fiber is unwinding, before the
   backend starts waiting for an abandoned answer. It must see that reply. *)
let test_answer_during_cancellation_keeps_the_session () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let first = the_session h in
  h.behaviour.answer_on_cancel <- true;
  leave_during h (Lane.Page_instruct { tab_id = 0; instruction = "click Buy" });
  h.settle ();
  check bool "the call was cancelled" true h.behaviour.act_cancelled;
  h.past_the_sentence_deadline ();
  check bool "the already answered sentence did not retire the session" false first.stopped;
  check bool "the session stays open" true (is_open h)
;;

(* A tab id read before a close reaches no page after the next open, even
   when the new session's first page has the same page id. *)
let test_tab_ids_do_not_cross_sessions () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  ignore (data (Backend.execute h.backend Lane.Session_close));
  ignore (data (Backend.execute h.backend open_));
  (match data (Backend.execute h.backend Lane.Tabs_list) with
   | `List [ tab ] -> check int "the new session's page gets a new id" 1 Yojson.Safe.Util.(member "id" tab |> to_int)
   | _ -> fail "the new session lists its page");
  match Backend.execute h.backend (Lane.Page_goto { url = "http://127.0.0.1:1/next"; tab_id = Some 0 }) with
  | Lane.Rejected_before_effect _ -> ()
  | _ -> fail "an id from the closed session is refused before effect"
;;

(* A page verb waits while another is in flight: the session's one-call slot
   alone would let a second verb's calls run between a first verb's. *)
let test_page_verbs_take_turns () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  Eio.Switch.run
  @@ fun sw ->
  let leave, left = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    try
      Eio.Switch.run (fun caller ->
        Eio.Fiber.fork ~sw:caller (fun () ->
          ignore (Backend.execute h.backend (Lane.Page_instruct { tab_id = 0; instruction = "click Buy" })));
        Eio.Promise.await leave;
        Eio.Switch.fail caller Exit)
    with
    | Exit -> ());
  h.settle ();
  let listed = Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute h.backend Lane.Tabs_list) in
  h.settle ();
  check bool "the second verb waits for the first" false (Eio.Promise.is_resolved listed);
  Eio.Promise.resolve left ();
  h.settle ();
  check bool "and runs once the first has ended" true (Eio.Promise.is_resolved listed)
;;

(* A sentence whose caller leaves while it still waits for the verb slot sent
   nothing, so the session is not retired on its account. *)
let test_a_queued_caller_leaves_the_session_open () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  Eio.Switch.run
  @@ fun sw ->
  let instruct = Lane.Page_instruct { tab_id = 0; instruction = "click Buy" } in
  let first_leave, first_left = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    try
      Eio.Switch.run (fun caller ->
        Eio.Fiber.fork ~sw:caller (fun () -> ignore (Backend.execute h.backend instruct));
        Eio.Promise.await first_leave;
        Eio.Switch.fail caller Exit)
    with
    | Exit -> ());
  h.settle ();
  leave_during h instruct;
  h.settle ();
  check bool "the queued caller's leaving stopped nothing" false (the_session h).stopped;
  check bool "the session is still open" true (is_open h);
  Eio.Promise.resolve first_left ();
  h.settle ();
  check bool "the sentence that began keeps the session while it may be answered" false (the_session h).stopped;
  h.past_the_sentence_deadline ();
  check bool "and retires it once unanswered past its deadline" true (the_session h).stopped
;;

let test_close_does_not_wait_forever () =
  with_backend ~configure:(fun behaviour -> behaviour.close <- Silent)
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  let closed = data (Backend.execute h.backend Lane.Session_close) in
  check bool "closed" true (flag "closed" closed);
  check bool "the runtime's silence is reported" true (text "runtime" closed <> "closed");
  check bool "the browser stopped anyway" true (the_session h).stopped
;;

(* A close whose runtime call raised still stops the browser and leaves the
   backend closed, not stuck closing. *)
let test_close_that_raises_still_closes () =
  with_backend ~configure:(fun behaviour -> behaviour.close <- Raises_on_close)
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  let closed = data (Backend.execute h.backend Lane.Session_close) in
  check bool "closed" true (flag "closed" closed);
  check bool "the failure is reported" true (String.starts_with ~prefix:"did not close" (text "runtime" closed));
  check bool "the browser stopped" true (the_session h).stopped;
  h.behaviour.close <- Answers;
  check bool "the next open starts a new session" false (flag "reused" (data (Backend.execute h.backend open_)))
;;

(* A session that stopped working is let go: its browser stops, status keeps
   the reason, and the next open starts a new session instead of reusing
   one every page verb would find gone. *)
let test_an_ended_session_is_let_go () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  let first = the_session h in
  first.log (Session.Worker_detached);
  h.settle ();
  check bool "the browser stopped" true first.stopped;
  let status = data (Backend.execute h.backend Lane.Session_status) in
  check bool "closed" false (flag "open" status);
  check string "why" "the service worker went away" (text "ended" status);
  check bool "the next open is new" false (flag "reused" (data (Backend.execute h.backend open_)));
  check int "two sessions" 2 (List.length !(h.sessions));
  check bool "a working session says nothing ended" true
    (Yojson.Safe.Util.member "ended" (data (Backend.execute h.backend Lane.Session_status)) = `Null)
;;

let test_status_reports_an_ended_session () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  (the_session h).log (Session.Connection_ended "Chromium exited");
  let status = data (Backend.execute h.backend Lane.Session_status) in
  check string "why it stopped working" "the connection ended: Chromium exited" (text "ended" status)
;;

let test_status_reports_an_undelivered_answer () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  (the_session h).log (Session.Reply_not_delivered "Execution context was destroyed.");
  let status = data (Backend.execute h.backend Lane.Session_status) in
  check string "why it stopped working" "an answer to the extension was not delivered: Execution context was destroyed."
    (text "ended" status)
;;

let () =
  run "browser_stagehand_backend" [
    "lifecycle", [
      test_case "open, reuse, list, close" `Quick test_lifecycle;
      test_case "a page verb needs a session" `Quick test_page_verb_without_a_session;
      test_case "a failed or raising open leaves the backend usable" `Quick test_open_failures;
      test_case "an open finishes after its caller leaves" `Quick test_open_outlives_its_caller;
      test_case "close waits for the runtime only so long" `Quick test_close_does_not_wait_forever;
      test_case "tab ids do not cross sessions" `Quick test_tab_ids_do_not_cross_sessions;
      test_case "page verbs take turns" `Quick test_page_verbs_take_turns;
      test_case "a caller who leaves while queued leaves the session open" `Quick test_a_queued_caller_leaves_the_session_open;
      test_case "status reports why a session ended" `Quick test_status_reports_an_ended_session;
      test_case "a close that raises still closes" `Quick test_close_that_raises_still_closes;
      test_case "an ended session is let go" `Quick test_an_ended_session_is_let_go;
      test_case "status reports an answer the session could not deliver" `Quick test_status_reports_an_undelivered_answer;
    ];
    ( "callers",
      [ test_case "an unanswered sentence whose caller left retires its session" `Quick
          test_sentence_caller_retires_its_session;
        test_case "an answered sentence keeps the shared session" `Quick test_an_answered_sentence_keeps_the_session;
        test_case "an answer during cancellation keeps the shared session" `Quick
          test_answer_during_cancellation_keeps_the_session
      ] );
  ]
;;
