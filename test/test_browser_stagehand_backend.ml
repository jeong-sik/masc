(* The Stagehand backend with a fake opener and a fake call. The mock clock
   advances only when every fiber is blocked, so [settle] returns once the
   backend has run as far as it can. *)
open Alcotest
module Backend = Masc.Browser_stagehand_backend
module Wire = Masc.Browser_stagehand_wire
module Session = Masc.Browser_stagehand_session
module Executor = Masc.Browser_stagehand_executor
module Feedback = Masc.Browser_pointer_feedback
module Lane = Browser_lane

(* Shorter than the backend's close wait, so the clock reaches it only after
   every other fiber has blocked. *)
let settle_s = 0.001

type fake_session = { mutable stopped : bool; log : Session.event -> unit }
type opening = Opens | Fails | Raises | Unconfirmed

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

let with_backend ?(configure = ignore) ?(call_hook = fun _ -> None)
    ?(shutdown = fun _ -> Ok ()) f =
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
    | Fails -> Error (Backend.Not_opened "no Chromium")
    | Raises -> raise Opener_bug
    | Unconfirmed -> Error (Backend.Cleanup_unconfirmed "partial cleanup unconfirmed")
    | Opens ->
      let session = { stopped = false; log } in
      Eio.Switch.on_release sw (fun () -> session.stopped <- true);
      sessions := session :: !sessions;
      Ok (session, `Assoc [ "pages", `List [ page ] ])
  in
  let call session request =
    match call_hook request with
    | Some answer -> answer
    | None ->
      (match request with
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
              session.log (Session.Cancelled_call_answered
                { method_ = "stagehand.act"; rejected = false });
            raise exn)
       | Wire.Context_new_page | Wire.Page_close _ | Wire.Page_reload _ | Wire.Page_go_back _ | Wire.Page_go_forward _
       | Wire.Observe _ | Wire.Extract _ | Wire.Page_goto _ | Wire.Page_screenshot _ | Wire.Page_hover _ | Wire.Page_set_viewport_size _ | Wire.Page_click _
       | Wire.Page_scroll _ | Wire.Page_drag_and_drop _ | Wire.Page_double_click _ | Wire.Page_type _ | Wire.Page_key_press _ ->
         failf "the backend sent %s" (Wire.method_name request))

  in
  let backend = Backend.create ~sw ~clock ~open_session ~call ~shutdown ~pid:(fun _ -> 42) ~log:ignore in
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

let test_nonblocking_lifecycle_observation () =
  let gate,release=Eio.Promise.create () in
  with_backend ~configure:(fun behaviour -> behaviour.open_gate<-Some gate;behaviour.close<-Silent)
    (fun h -> Eio.Switch.run (fun sw ->
      let opening=Eio.Fiber.fork_promise ~sw (fun ()->Backend.execute h.backend open_) in
      h.settle ();
      check bool "opening is observed without waiting for the opener" true
        (Backend.session_observation h.backend=Lane.Browser_changing);
      Eio.Promise.resolve release ();ignore (data (Eio.Promise.await_exn opening));
      check bool "owned browser is open" true (Backend.session_observation h.backend=Lane.Browser_open);
      let closing=Eio.Fiber.fork_promise ~sw (fun ()->Backend.execute h.backend Lane.Session_close) in
      h.settle ();
      check bool "closing is observed without waiting for the runtime" true
        (Backend.session_observation h.backend=Lane.Browser_changing);
      ignore (data (Eio.Promise.await_exn closing));
      check bool "released browser is closed" true (Backend.session_observation h.backend=Lane.Browser_closed)))
;;

let test_lifecycle () =
  with_backend
  @@ fun h ->
  check bool "closed at start" false (is_open h);
  check bool "registration alone is not open" true (Backend.session_observation h.backend=Lane.Browser_closed);
  check bool "open starts a session" false (flag "reused" (data (Backend.execute h.backend open_)));
  check bool "a second open reuses it" true (flag "reused" (data (Backend.execute h.backend open_)));
  check bool "confirmed owned session is observed" true (Backend.session_observation h.backend=Lane.Browser_open);
  let status = data (Backend.execute h.backend Lane.Session_status) in
  check int "status names the browser pid" 42 Yojson.Safe.Util.(member "pid" status |> to_int);
  (match data (Backend.execute h.backend Lane.Tabs_list) with
   | `List [ _ ] -> ()
   | _ -> fail "the open session lists its page");
  let closed = data (Backend.execute h.backend Lane.Session_close) in
  check string "the runtime was asked to close" "closed" (text "runtime" closed);
  check bool "the browser stopped" true (the_session h).stopped;
  check bool "closed again" false (is_open h);
  check bool "stopped owned browser is closed" true (Backend.session_observation h.backend=Lane.Browser_closed);
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

(* The guard of one pointer verb must still own the page when its native
   input arrives. A navigation queued during the guard cannot run between
   that guard and the click. A sentence cancelled while queued must not
   retire the active session either. *)
let test_actor_stays_with_queued_interaction () =
  let entered, mark_entered = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  let trace = ref [] and input_count = ref 0 in
  let args_of body expression =
    let sample = Executor.evaluate_expression ~runtime:Executor.No_runtime ~body ~args:`Null in
    let prefix = String.sub sample 0 (String.length sample - String.length "null)") in
    if String.starts_with ~prefix expression then
      Some (Yojson.Safe.from_string (String.sub expression (String.length prefix)
        (String.length expression - String.length prefix - 1))) else None in
  let call_hook = function
    | Wire.Page_evaluate {expression;_} ->
      let feedback = match args_of Feedback.begin_script expression with
        | Some args -> Some ("begin",args)
        | None -> Option.map (fun args -> "finish",args) (args_of Feedback.finish_script expression) in
      (match feedback with
       | None -> None
       | Some (phase,args) -> trace := (phase,args)::!trace;
         Some (Ok (`Assoc ["value",`String "null"])))
    | Wire.Page_hover _ ->
      incr input_count;
      if !input_count=1 then (Eio.Promise.resolve mark_entered ();Eio.Promise.await released);
      Some (Ok (`Assoc []))
    | _ -> None in
  with_backend ~call_hook (fun h ->
    ignore (data (Backend.execute h.backend open_));
    ignore (data (Backend.execute h.backend Lane.Tabs_list));
    let point = {Lane.Pointer.x=0.5;y=0.25} in
    let viewport = {Lane.Pointer.document_id="d1";width=800.;height=600.;scroll_x=0.;scroll_y=0.} in
    let verb = Lane.Page_interact {frame_path=[];tab_id=0;expected_url=Some "http://127.0.0.1:1/";
      action=Lane.Hover_at {point;viewport}} in
    Eio.Switch.run (fun sw ->
      let first=Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute h.backend ~actor:"keeper-a" verb) in
      Eio.Promise.await entered;
      let second=Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute h.backend ~actor:"keeper-b" verb) in
      h.settle ();
      check int "queued owner cannot replace the active badge" 1 (List.length !trace);
      Eio.Promise.resolve release ();
      ignore (data (Eio.Promise.await_exn first));ignore (data (Eio.Promise.await_exn second));
      let trace=List.rev !trace in
      check (list string) "each serialized operation retains its concrete owner"
        ["begin:keeper-a";"finish:keeper-a";"begin:keeper-b";"finish:keeper-b"]
        (List.map (fun (phase,args)->phase^":"^text "actor" args) trace);
      (match trace with
       | [_,a;_,a_end;_,b;_,b_end] ->
         check string "first finish binds first request" (text "requestId" a) (text "requestId" a_end);
         check string "second finish binds second request" (text "requestId" b) (text "requestId" b_end);
         check bool "each operation has its own identity" false (String.equal (text "requestId" a) (text "requestId" b))
       | _ -> fail "expected two complete serialized feedback operations")))
;;

let test_pointer_guard_and_input_keep_the_verb_slot () =
  let guard_entered, mark_guard = Eio.Promise.create () in
  let release_guard, allow_guard = Eio.Promise.create () in
  let recording = ref false and evaluations = ref 0 and trace = ref [] in
  let note name = trace := name :: !trace in
  let url = "http://127.0.0.1:1/" in
  let reply json = Some (Ok (`Assoc [ "value", `String (Yojson.Safe.to_string json) ])) in
  let call_hook = function
    | Wire.Page_evaluate _ when !recording ->
      incr evaluations;
      (match !evaluations with
       | 1 ->
         note "guard";
         Eio.Promise.resolve mark_guard ();
         Eio.Promise.await release_guard;
         reply (`Assoc [ "url", `String url ])
       | 2 ->
         note "receipt";
         reply (`Assoc [ "url", `String url; "title", `String "Shop" ])
       | 3 ->
         note "goto summary";
         reply (`Assoc [ "url", `String (url ^ "next"); "title", `String "Next" ])
       | _ -> fail "unexpected page evaluation")
    | Wire.Page_click _ when !recording ->
      note "click";
      Some (Ok (`Assoc [ "ok", `Bool true ]))
    | Wire.Page_goto _ when !recording ->
      note "goto";
      Some (Ok (`Assoc [ "page", page ]))
    | Wire.Close | Wire.Act _ | Wire.Observe _ | Wire.Extract _ | Wire.Context_pages
    | Wire.Context_active_page | Wire.Context_new_page
    | Wire.Page_close _ | Wire.Page_reload _ | Wire.Page_go_back _ | Wire.Page_go_forward _ | Wire.Page_goto _ | Wire.Page_screenshot _ | Wire.Page_evaluate _
    | Wire.Page_hover _ | Wire.Page_set_viewport_size _ | Wire.Page_click _ | Wire.Page_scroll _ | Wire.Page_drag_and_drop _
    | Wire.Page_double_click _ | Wire.Page_type _ | Wire.Page_key_press _ -> None
  in
  with_backend ~call_hook
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let first = the_session h in
  recording := true;
  let point = { Lane.Pointer.x = 0.5; y = 0.25 } in
  let viewport = { Lane.Pointer.document_id = "d1"; width = 800.; height = 600.; scroll_x = 0.; scroll_y = 0. } in
  Eio.Switch.run
  @@ fun callers ->
  let pointer =
    Eio.Fiber.fork_promise ~sw:callers (fun () ->
      Backend.execute h.backend
        (Lane.Page_interact
           { frame_path = []; tab_id = 0; expected_url = Some url; action = Lane.Click_at { point; viewport; button = Lane.Pointer.Primary } }))
  in
  Eio.Promise.await guard_entered;
  let navigation =
    Eio.Fiber.fork_promise ~sw:callers (fun () ->
      Backend.execute h.backend (Lane.Page_goto { tab_id = Some 0; url = url ^ "next" }))
  in
  h.settle ();
  check (list string) "navigation has not reached the browser during the guard" [ "guard" ] (List.rev !trace);
  leave_during h (Lane.Page_instruct { tab_id = 0; instruction = "click Buy" });
  h.settle ();
  check bool "queued sentence cancellation keeps this session" false first.stopped;
  Eio.Promise.resolve allow_guard ();
  ignore (data (Eio.Promise.await_exn pointer));
  ignore (data (Eio.Promise.await_exn navigation));
  check (list string) "guard, click, receipt finish before navigation"
    [ "guard"; "click"; "receipt"; "goto"; "goto summary" ] (List.rev !trace);
  check bool "the session remains usable" true (is_open h)
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

let test_native_keyboard_quarantine () =
  let key=match Lane.Keyboard.of_wire ~key:"a" ~modifiers:["Meta"] with Ok key->key|Error detail->fail detail in
  List.iter (fun failure ->
    let inputs=ref 0 in
    with_backend ~call_hook:(function Wire.Page_key_press _ -> incr inputs;Some (Error failure)|_->None) (fun h ->
      ignore (data (Backend.execute h.backend open_));ignore (data (Backend.execute h.backend Lane.Tabs_list));
      let verb=Lane.Page_interact {frame_path=[];tab_id=0;expected_url=Some "http://127.0.0.1:1/";
        action=Lane.Press_key {document_id="d1";key}} in
      (match Backend.execute h.backend verb with Lane.Refused _->()|_->fail "failed native keys must remain uncertain");
      let status=data (Backend.execute h.backend Lane.Session_status) in
      check bool "unconfirmed native key release quarantines" true (Yojson.Safe.Util.(status |> member "quarantined" |> to_bool));
      check bool "quarantine is not an available open browser" true (Backend.session_observation h.backend=Lane.Browser_unknown);
      check bool "quarantine preserves the unsaved browser" false (the_session h).stopped;
      List.iter (fun verb -> match Backend.execute h.backend verb with Lane.Rejected_before_effect _ -> ()
        | _ -> fail "quarantined session must refuse work and reuse") [verb;open_;Lane.Tabs_list];
      check int "unknown chord is never replayed" 1 !inputs;
      ignore (data (Backend.execute h.backend Lane.Session_close));
      check bool "explicit close ends the exact quarantined browser" true (the_session h).stopped;
      ignore (data (Backend.execute h.backend open_));
      check int "explicit reopen creates fresh owned session" 2 (List.length !(h.sessions))))
    [Session.Lost "native key reply missing";Session.Rejected {code= -32603;message="keyDown failed"}];
  with_backend ~call_hook:(function Wire.Page_key_press _ -> Some (Error (Session.Not_delivered "never written"))|_->None) (fun h ->
    ignore (data (Backend.execute h.backend open_));ignore (data (Backend.execute h.backend Lane.Tabs_list));
    ignore (Backend.execute h.backend (Lane.Page_interact {frame_path=[];tab_id=0;expected_url=Some "http://127.0.0.1:1/";
      action=Lane.Press_key {document_id="d1";key}}));
    check bool "proven unsent keyboard input does not quarantine" true (Backend.session_observation h.backend=Lane.Browser_open))

let test_cancelled_native_keyboard_quarantines () =
  let entered,enter=Eio.Promise.create () and never,_=Eio.Promise.create () in
  with_backend ~call_hook:(function Wire.Page_type _ -> Eio.Promise.resolve enter ();Eio.Promise.await never | _->None) (fun h ->
    ignore (data (Backend.execute h.backend open_));ignore (data (Backend.execute h.backend Lane.Tabs_list));
    Eio.Fiber.first (fun () -> ignore (Backend.execute h.backend (Lane.Page_interact {frame_path=[];tab_id=0;
      expected_url=Some "http://127.0.0.1:1/";action=Lane.Type_text {document_id="d1";text="owned"}})))
      (fun () -> Eio.Promise.await entered);
    h.settle ();
    check bool "cancelled dispatched native input quarantines" true (Backend.session_observation h.backend=Lane.Browser_unknown);
    check bool "cancellation never silently closes unsaved page" false (the_session h).stopped;
    ignore (data (Backend.execute h.backend Lane.Session_close)))

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

let test_status_keeps_first_end_during_shutdown () =
  let entered,enter=Eio.Promise.create () and released,release=Eio.Promise.create () in
  with_backend ~shutdown:(fun _ ->
    ignore (Eio.Promise.try_resolve enter ());
    Eio.Promise.await released;Ok ()) (fun h ->
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve release ())) (fun () ->
      ignore (data (Backend.execute h.backend open_));
      let first=the_session h in
      first.log (Session.Connection_ended "Chromium exited");
      Eio.Promise.await entered;
      let status=data (Backend.execute h.backend Lane.Session_status) in
      check bool "shutdown is still in progress" true (flag "closing" status);
      check string "pending shutdown keeps the original reason"
        "the connection ended: Chromium exited" (text "ended" status);
      check bool "status does not certify pending cleanup" true (Result.is_error (Backend.settlement h.backend));
      first.log (Session.Reply_not_delivered "later teardown reply failed");
      check string "later shutdown events do not replace the first reason"
        "the connection ended: Chromium exited"
        (text "ended" (data (Backend.execute h.backend Lane.Session_status)));
      Eio.Promise.resolve release ();
      h.settle ();
      let status=data (Backend.execute h.backend Lane.Session_status) in
      check bool "confirmed shutdown is closed" false (flag "open" status);
      check string "joined shutdown retains the same reason"
        "the connection ended: Chromium exited" (text "ended" status);
      ignore (data (Backend.execute h.backend open_));
      check bool "a new session starts with no previous end reason" true
        (Yojson.Safe.Util.member "ended" (data (Backend.execute h.backend Lane.Session_status))=`Null)))
;;

let test_uncertain_opening_is_retained () =
  List.iter (fun opening ->
    with_backend ~configure:(fun behaviour -> behaviour.opening<-opening) (fun h ->
      check bool "uncertain original opening is refused" true (refused (Backend.execute h.backend open_));
      h.settle ();
      h.behaviour.opening<-Opens;
      check bool "uncertain cleanup cannot be replaced by reopening" true (refused (Backend.execute h.backend open_));
      check bool "owner sees failed partial cleanup" true (Result.is_error (Backend.settlement h.backend));
      check int "no replacement session was launched" 0 (List.length !(h.sessions))))
    [Raises;Unconfirmed]

let test_shutdown_failure_is_retained () =
  let shutdowns=ref 0 in
  with_backend ~shutdown:(fun session ->
    incr shutdowns;
    check bool "shutdown precedes transport release" false session.stopped;
    Error "profile flush unconfirmed") (fun h ->
    ignore (data (Backend.execute h.backend open_));
    List.iter (fun verb ->
      check bool "failed shutdown never becomes successful close or reuse" true
        (refused (Backend.execute h.backend verb)))
      [Lane.Session_close;Lane.Session_close;open_];
    check int "original shutdown is not replayed" 1 !shutdowns;
    check bool "fallback resource scope joins" true (the_session h).stopped;
    check bool "uncertain cleanup stays visible" true
      (Backend.session_observation h.backend=Lane.Browser_unknown);
    check bool "owner reads the retained failure" true
      (Backend.settlement h.backend=Error "profile flush unconfirmed"))

let test_parent_stop_keeps_shutdown_transport () =
  Eio_mock.Backend.run_full (fun env ->
    let shutdowns=ref 0 and released=ref false and retained=ref None in
    Eio.Switch.run (fun sw ->
      let request,send=Eio.Promise.create () and response,reply=Eio.Promise.create () in
      let open_session ~sw ~headless:_ ~log:_ =
        Eio.Switch.on_release sw (fun () -> released:=true);
        Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Promise.await request;
          Eio.Promise.resolve reply ();
          Eio.Fiber.await_cancel ());
        Ok ((),`Null) in
      let backend=Backend.create ~sw ~clock:env#clock ~open_session
        ~call:(fun () _ -> fail "no runtime request expected") ~pid:(fun () -> 42) ~log:ignore
        ~shutdown:(fun () ->
          incr shutdowns;
          check bool "parent stop leaves transport open for shutdown" false !released;
          Eio.Promise.resolve send ();Eio.Promise.await response;Ok ()) in
      retained:=Some backend;
      ignore (data (Backend.execute backend open_)));
    check int "parent stop shuts down exactly once" 1 !shutdowns;
    check bool "transport is released after the shutdown reply" true !released;
    match !retained with
    | Some backend -> check bool "owner settlement is terminal" true (Backend.settlement backend=Ok ())
    | None -> fail "backend was not created")

let test_parent_stop_cancels_opening () =
  Eio_mock.Backend.run_full (fun env ->
    let entered,enter=Eio.Promise.create () and never,_=Eio.Promise.create () in
    let cancelled=ref false and released=ref false and shutdowns=ref 0 in
    Eio.Switch.run (fun sw ->
      let open_session ~sw ~headless:_ ~log:_ =
        Eio.Switch.on_release sw (fun () -> released:=true);
        Eio.Promise.resolve enter ();
        match Eio.Promise.await never with
        | () -> fail "startup must not survive its parent"
        | exception (Eio.Cancel.Cancelled _ as exn) -> cancelled:=true;raise exn in
      let backend=Backend.create ~sw ~clock:env#clock ~open_session
        ~call:(fun () _ -> fail "startup sent a runtime command") ~pid:(fun () -> 42) ~log:ignore
        ~shutdown:(fun () -> incr shutdowns;Ok ()) in
      Eio.Fiber.fork_daemon ~sw (fun () -> ignore (Backend.execute backend open_);`Stop_daemon);
      Eio.Promise.await entered);
    check bool "parent stop cancels bootstrap work" true !cancelled;
    check bool "partial resource scope is joined" true !released;
    check int "no completed session is invented" 0 !shutdowns)

let () =
  run "browser_stagehand_backend" [
    "lifecycle", [
      test_case "uncertain partial opening retains original failure" `Quick test_uncertain_opening_is_retained;
      test_case "shutdown failure remains uncertain without replay" `Quick test_shutdown_failure_is_retained;
      test_case "parent stop keeps transport alive through shutdown" `Quick test_parent_stop_keeps_shutdown_transport;
      test_case "parent stop cancels unfinished startup" `Quick test_parent_stop_cancels_opening;
      test_case "uncertain keyboard release quarantines without closing" `Quick test_native_keyboard_quarantine;
      test_case "cancelled keyboard dispatch quarantines" `Quick test_cancelled_native_keyboard_quarantines;
      test_case "open, reuse, list, close" `Quick test_lifecycle;
      test_case "lifecycle observations never wait on browser I/O" `Quick test_nonblocking_lifecycle_observation;
      test_case "a page verb needs a session" `Quick test_page_verb_without_a_session;
      test_case "a cleanly refused open leaves the backend usable" `Quick test_open_failures;
      test_case "an open finishes after its caller leaves" `Quick test_open_outlives_its_caller;
      test_case "close waits for the runtime only so long" `Quick test_close_does_not_wait_forever;
      test_case "tab ids do not cross sessions" `Quick test_tab_ids_do_not_cross_sessions;
      test_case "page verbs take turns" `Quick test_page_verbs_take_turns;
      test_case "a caller who leaves while queued leaves the session open" `Quick test_a_queued_caller_leaves_the_session_open;
      test_case "status reports why a session ended" `Quick test_status_reports_an_ended_session;
      test_case "a close that raises still closes" `Quick test_close_that_raises_still_closes;
      test_case "an ended session is let go" `Quick test_an_ended_session_is_let_go;
      test_case "status reports an answer the session could not deliver" `Quick test_status_reports_an_undelivered_answer;
      test_case "status keeps the first end reason through pending shutdown" `Quick test_status_keeps_first_end_during_shutdown;
    ];
    ( "callers",
      [ test_case "an unanswered sentence whose caller left retires its session" `Quick
          test_sentence_caller_retires_its_session;
        test_case "an answered sentence keeps the shared session" `Quick test_an_answered_sentence_keeps_the_session;
        test_case "an answer during cancellation keeps the shared session" `Quick
          test_answer_during_cancellation_keeps_the_session;
        test_case "pointer guard and input exclude navigation" `Quick test_pointer_guard_and_input_keep_the_verb_slot;
        test_case "actor stays bound through the serialized queue" `Quick test_actor_stays_with_queued_interaction
      ] );
  ]
;;
