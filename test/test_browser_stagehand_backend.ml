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

let with_backend ?(configure = ignore) ?(call_hook = fun _ -> None) ?(private_ready = fun _ -> true)
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
  let backend = Backend.create ~sw ~clock ~open_session ~call ~private_ready ~shutdown ~pid:(fun _ -> 42) ~log:ignore in
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
        ~call:(fun () _ -> fail "no runtime request expected") ~private_ready:(fun () -> false) ~pid:(fun () -> 42) ~log:ignore
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
        ~call:(fun () _ -> fail "startup sent a runtime command") ~private_ready:(fun () -> false) ~pid:(fun () -> 42) ~log:ignore
        ~shutdown:(fun () -> incr shutdowns;Ok ()) in
      Eio.Fiber.fork_daemon ~sw (fun () -> ignore (Backend.execute backend open_);`Stop_daemon);
      Eio.Promise.await entered);
    check bool "parent stop cancels bootstrap work" true !cancelled;
    check bool "partial resource scope is joined" true !released;
    check int "no completed session is invented" 0 !shutdowns)

let private_ok = function Ok value -> value | Error _ -> fail "private browser operation refused"

let test_private_original_session_and_tab () = with_backend (fun h ->
  check bool "private capture does not open a browser" true
    (Backend.capture_private_session h.backend=Error Backend.Private_not_started);
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let session=private_ok (Backend.capture_private_session h.backend) in
  let dispatched=ref 0 in
  let run original ~page_id =
    incr dispatched;
    check bool "callback receives the original owned session" true (original == the_session h);
    check string "MASC tab resolves to exact CDP target, not a Chrome numeric tab" "P" page_id;
    Ok (`Assoc ["private",`String "PRIVATE_MARKER"]) in
  check bool "unknown tab is rejected before callback" true
    (Backend.execute_private h.backend ~session ~tab_id:42 ~run=Error Backend.Private_not_started);
  check int "invalid tab sent no private request" 0 !dispatched;
  check bool "private result returns through the private caller only" true
    (Backend.execute_private h.backend ~session ~tab_id:0 ~run=Ok (`Assoc ["private",`String "PRIVATE_MARKER"]));
  check int "one explicit dispatch" 1 !dispatched;
  check bool "settled private work preserves ordinary page reads" true
    (match Backend.execute h.backend Lane.Tabs_list with Lane.Answered _ -> true | _ -> false))

let test_private_read_exclusion () = with_backend (fun h -> Eio.Switch.run (fun sw ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let session=private_ok (Backend.capture_private_session h.backend) in
  let entered,enter=Eio.Promise.create () and completed,complete=Eio.Promise.create () in
  let operation=Eio.Fiber.fork_promise ~sw (fun () ->
    Backend.execute_private h.backend ~session ~tab_id:0 ~run:(fun _ ~page_id:_ ->
      Eio.Promise.resolve enter ();Eio.Promise.await completed;Ok (`Assoc []))) in
  Eio.Promise.await entered;
  let reading=Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute h.backend Lane.Tabs_list) in
  h.settle ();
  check bool "private input retains the existing whole-verb slot" false (Eio.Promise.is_resolved reading);
  (* Status is host lifecycle data and remains available without exposing a page. *)
  check bool "status does not block behind a private effect" true (is_open h);
  Eio.Promise.resolve complete ();
  ignore (private_ok (Eio.Promise.await_exn operation));
  ignore (data (Eio.Promise.await_exn reading))))

let test_private_synchronous_fence_discards_success () = with_backend (fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let original = the_session h in
  let session = private_ok (Backend.capture_private_session h.backend) in
  let returned = ref false in
  let result = Backend.execute_private h.backend ~session ~tab_id:0
    ~run:(fun _ ~page_id:_ ->
      Backend.fence_private_session h.backend ~session;
      returned := true;
      Ok (`Assoc ["private", `String "PRIVATE_SYNCHRONOUS_RESULT_MARKER"])) in
  check bool "the callback returned synchronously after fencing its pin" true !returned;
  check bool "a success returned with its own fence is discarded" true
    (result = Error Backend.Private_outcome_unknown);
  check bool "the original fenced browser cannot be privately recaptured" true
    (Backend.capture_private_session h.backend = Error Backend.Private_session_fenced);
  check bool "fencing never silently closes the unsaved original browser" false original.stopped;
  ignore (data (Backend.execute h.backend Lane.Session_close));
  check bool "explicit close still joins the exact original browser" true original.stopped)

let test_private_worker_loss_joins_and_discards_returned_success () =
  with_backend (fun h -> Eio.Switch.run (fun sw ->
    ignore (data (Backend.execute h.backend open_));
    ignore (data (Backend.execute h.backend Lane.Tabs_list));
    let original = the_session h in
    let session = private_ok (Backend.capture_private_session h.backend) in
    let entered, enter = Eio.Promise.create () in
    let broker_reply, _ = Eio.Promise.create () in
    let cleanup_allowed, allow_cleanup = Eio.Promise.create () in
    let cancelled = ref false and joined = ref false and resumed = ref false in
    let operation = Eio.Fiber.fork_promise ~sw (fun () ->
      Backend.execute_private h.backend ~session ~tab_id:0 ~run:(fun _ ~page_id:_ ->
        Eio.Promise.resolve enter ();
        match Eio.Promise.await broker_reply with
        | () -> resumed := true; Ok (`Assoc ["private", `String "PRIVATE_RESUMED_RESULT_MARKER"])
        | exception (Eio.Cancel.Cancelled _) ->
          cancelled := true;
          Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup_allowed);
          joined := true;
          Ok (`Assoc ["private", `String "PRIVATE_CANCELLED_RESULT_MARKER"]))) in
    (* Resolving this promise never suspends; a failed assertion must not
       strand the callback's protected cancellation cleanup. *)
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ()))
      (fun () ->
        Eio.Promise.await entered;
        Backend.fence_private_session h.backend ~session;
        h.settle ();
        check bool "worker loss cancels an already entered private callback" true !cancelled;
        check bool "private callback cleanup is still being joined" false !joined;
        check bool "private result is withheld until cancellation cleanup joins" false
          (Eio.Promise.is_resolved operation);
        check bool "worker loss fences without stopping the unsaved browser" false original.stopped;
        check bool "status remains available while private cleanup joins" true
          (flag "private_operation_unsettled" (data (Backend.execute h.backend Lane.Session_status)));
        ignore (data (Backend.execute h.backend Lane.Session_close));
        check bool "explicit close joins the original resources while callback cleanup waits" true original.stopped;
        ignore (data (Backend.execute h.backend open_));
        let next_page = Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute h.backend Lane.Tabs_list) in
        h.settle ();
        check bool "successor pages retain the serializer until private cleanup joins" false
          (Eio.Promise.is_resolved next_page);
        Eio.Promise.resolve allow_cleanup ();
        check bool "a cancellation-ignoring private success cannot escape its original fence" true
          (Eio.Promise.await_exn operation = Error Backend.Private_outcome_unknown);
        check bool "callback cleanup finishes before the private slot returns" true !joined;
        check bool "the broker wait never resumes normally on a successor" false !resumed;
        ignore (data (Eio.Promise.await_exn next_page));
        Backend.fence_private_session h.backend ~session;
        check bool "late original cleanup and repeated old loss leave the successor open" true
          (Backend.session_observation h.backend = Lane.Browser_open);
        ignore (private_ok (Backend.capture_private_session h.backend)))))

let test_private_unknown_fences_and_never_rebinds () = with_backend (fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let first=the_session h in
  let session=private_ok (Backend.capture_private_session h.backend) in
  check bool "callback exception cannot echo private exception text" true
    (Backend.execute_private h.backend ~session ~tab_id:0
      ~run:(fun _ ~page_id:_ -> failwith "PRIVATE_EXCEPTION_MARKER")=Error Backend.Private_outcome_unknown);
  check bool "unknown private work fences public page reads" true
    (match Backend.execute h.backend Lane.Tabs_list with Lane.Rejected_before_effect _ -> true | _ -> false);
  check bool "fenced session cannot be recaptured" true
    (Backend.capture_private_session h.backend=Error Backend.Private_session_fenced);
  let calls=ref 0 in
  let run _ ~page_id:_ = incr calls;Ok (`Assoc []) in
  check bool "unknown operation is never retried" true
    (Backend.execute_private h.backend ~session ~tab_id:0 ~run=Error Backend.Private_session_fenced);
  check bool "open cannot silently replace an unsettled session" true
    (match Backend.execute h.backend open_ with Lane.Rejected_before_effect _ -> true | _ -> false);
  check bool "no automatic shutdown hides the unknown effect" false first.stopped;
  ignore (data (Backend.execute h.backend Lane.Session_close));
  check bool "explicit close settles the original browser" true first.stopped;
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  check bool "old pin cannot follow a freshly opened browser" true
    (Backend.execute_private h.backend ~session ~tab_id:1 ~run=Error Backend.Private_not_started);
  check int "refused and stale calls never reach the adapter" 0 !calls)

let test_private_cancel_after_dispatch_fences () = with_backend (fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let session=private_ok (Backend.capture_private_session h.backend) in
  let entered,enter=Eio.Promise.create () and never,_=Eio.Promise.create () in
  let cancelled=ref false in
  ignore (Eio.Fiber.first
    (fun () -> ignore (Backend.execute_private h.backend ~session ~tab_id:0
      ~run:(fun _ ~page_id:_ -> Eio.Promise.resolve enter ();
        match Eio.Promise.await never with
        | () -> Ok (`Assoc [])
        | exception (Eio.Cancel.Cancelled _ as exn) -> cancelled:=true;raise exn)))
    (fun () -> Eio.Promise.await entered));
  h.settle ();
  check bool "caller cancellation reaches original private work" true !cancelled;
  check bool "cancellation does not just return the page semaphore" true
    (Backend.capture_private_session h.backend=Error Backend.Private_session_fenced);
  check bool "page readers cannot run while extension input may continue" true
    (match Backend.execute h.backend Lane.Tabs_list with Lane.Rejected_before_effect _ -> true | _ -> false))

let test_private_cancel_before_dispatch_preserves_session () = with_backend (fun h -> Eio.Switch.run (fun sw ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  let session=private_ok (Backend.capture_private_session h.backend) in
  let entered,enter=Eio.Promise.create () and ended,finish=Eio.Promise.create () in
  let first=Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute_private h.backend ~session ~tab_id:0
    ~run:(fun _ ~page_id:_ -> Eio.Promise.resolve enter ();Eio.Promise.await ended;Ok (`Assoc []))) in
  Eio.Promise.await entered;
  let calls=ref 0 in
  ignore (Eio.Fiber.first
    (fun () -> ignore (Backend.execute_private h.backend ~session ~tab_id:0
      ~run:(fun _ ~page_id:_ -> incr calls;Ok (`Assoc []))))
    (fun () -> h.settle ()));
  Eio.Promise.resolve finish ();ignore (private_ok (Eio.Promise.await_exn first));
  h.settle ();
  check int "cancelled queued private operation never ran" 0 !calls;
  ignore (private_ok (Backend.capture_private_session h.backend));
  ignore (data (Backend.execute h.backend Lane.Tabs_list))))

let test_private_close_joins_callback_and_releases_reopened_pages () =
  with_backend (fun h -> Eio.Switch.run (fun sw ->
    ignore (data (Backend.execute h.backend open_));
    ignore (data (Backend.execute h.backend Lane.Tabs_list));
    let original = the_session h in
    let session = private_ok (Backend.capture_private_session h.backend) in
    let entered, enter = Eio.Promise.create () in
    let broker_reply, _ = Eio.Promise.create () in
    let cleanup_allowed, allow_cleanup = Eio.Promise.create () in
    let cancelled = ref false and joined = ref false and resumed = ref false in
    let operation = Eio.Fiber.fork_promise ~sw (fun () ->
      Backend.execute_private h.backend ~session ~tab_id:0 ~run:(fun owned ~page_id:_ ->
        check bool "private work stays with the original browser" true (owned == original);
        Eio.Promise.resolve enter ();
        match Eio.Promise.await broker_reply with
        | () -> resumed := true; Ok (`Assoc [])
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          check bool "only confirmed original retirement cancels this wait" true original.stopped;
          cancelled := true;
          Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup_allowed);
          joined := true;
          raise exn)) in
    (* Resolving this promise cannot suspend. Release protected cleanup even
       if an assertion fails, so the regression fails instead of hanging. *)
    Fun.protect
      ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ()))
      (fun () ->
        Eio.Promise.await entered;
        let queued_page = Eio.Fiber.fork_promise ~sw (fun () ->
          Backend.execute h.backend Lane.Tabs_list) in
        h.settle ();
        check bool "active private work excludes page observations" false
          (Eio.Promise.is_resolved queued_page);
        ignore (data (Backend.execute h.backend Lane.Session_close));
        check bool "explicit close confirms the original browser stopped" true original.stopped;
        ignore (data (Backend.execute h.backend open_));
        check int "a distinct browser was opened" 2 (List.length !(h.sessions));
        let next_page = Eio.Fiber.fork_promise ~sw (fun () ->
          Backend.execute h.backend Lane.Tabs_list) in
        h.settle ();
        check bool "original shutdown cancels a broker wait outside its transport" true !cancelled;
        check bool "callback cleanup remains joined before slot release" false !joined;
        check bool "new page waits for original callback cleanup" false
          (Eio.Promise.is_resolved next_page);
        Eio.Promise.resolve allow_cleanup ();
        check bool "terminated private work has a fixed unknown outcome" true
          (Eio.Promise.await_exn operation = Error Backend.Private_outcome_unknown);
        check bool "original callback cleanup has finished" true !joined;
        check bool "the broker wait never resumes on the successor" false !resumed;
        ignore (data (Eio.Promise.await_exn queued_page));
        ignore (data (Eio.Promise.await_exn next_page));
        check bool "late original cleanup never fences the successor" true
          (Backend.session_observation h.backend = Lane.Browser_open);
        ignore (private_ok (Backend.capture_private_session h.backend)))))

let test_private_requires_settled_public_input () =
  let settled=ref true in
  with_backend ~private_ready:(fun _ -> !settled) (fun h ->
    ignore (data (Backend.execute h.backend open_));
    ignore (data (Backend.execute h.backend Lane.Tabs_list));
    let session=private_ok (Backend.capture_private_session h.backend) in
    settled:=false;
    check bool "capture refuses an abandoned public extension call" true
      (Backend.capture_private_session h.backend=Error Backend.Private_not_started);
    let calls=ref 0 in
    let run _ ~page_id:_ = incr calls;Ok (`Assoc []) in
    check bool "a previously captured pin must recheck public settlement" true
      (Backend.execute_private h.backend ~session ~tab_id:0 ~run=Error Backend.Private_not_started);
    check int "unsettled public input admits no companion effect" 0 !calls;
    settled:=true;
    ignore (private_ok (Backend.execute_private h.backend ~session ~tab_id:0 ~run));
    check int "the exact original session remains usable after settlement" 1 !calls)

let private_page_discarded = function
  | Lane.Refused detail ->
    check string "only a fixed refusal leaves the original page operation"
      "the original browser was fenced during page work; its result was discarded; explicitly close the original session before new work"
      detail
  | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Rejected_before_effect _ ->
    fail "an active fenced page operation must discard its result with a fixed refusal"

let test_companion_loss_cancels_and_joins_active_page ~capture =
  let entered, enter = Eio.Promise.create () in
  let broker_reply, _ = Eio.Promise.create () in
  let cleanup_allowed, allow_cleanup = Eio.Promise.create () in
  let armed = ref false and cancelled = ref false and joined = ref false in
  let calls = ref 0 and followups = ref 0 in
  let call_hook = function
    | Wire.Page_evaluate _ when !armed ->
      incr calls;
      Eio.Promise.resolve enter ();
      (match Eio.Promise.await broker_reply with
       | () -> fail "the held page operation must not resume normally"
       | exception (Eio.Cancel.Cancelled _) ->
         cancelled := true;
         Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup_allowed);
         joined := true;
         (* A transport adapter can return a value while handling cancellation.
            Neither that value nor a later executor call may leave the fence. *)
         Some (Ok (`Assoc ["value", `String {|{"url":"http://127.0.0.1:1/","title":"PRIVATE_READ_MARKER","viewport":null}|} ])))
    | Wire.Page_screenshot _ ->
      incr followups;
      Some (Ok (`Assoc ["data", `String "PRIVATE_CAPTURE_MARKER"]))
    | Wire.Close | Wire.Act _ | Wire.Observe _ | Wire.Extract _ | Wire.Context_pages
    | Wire.Context_active_page | Wire.Context_new_page
    | Wire.Page_close _ | Wire.Page_reload _ | Wire.Page_go_back _ | Wire.Page_go_forward _ | Wire.Page_goto _
    | Wire.Page_evaluate _ | Wire.Page_hover _ | Wire.Page_set_viewport_size _
    | Wire.Page_click _ | Wire.Page_double_click _ | Wire.Page_scroll _ | Wire.Page_drag_and_drop _
    | Wire.Page_type _ | Wire.Page_key_press _ -> None in
  with_backend ~call_hook (fun h -> Eio.Switch.run (fun sw ->
    ignore (data (Backend.execute h.backend open_));
    ignore (data (Backend.execute h.backend Lane.Tabs_list));
    let original = the_session h in
    let session = private_ok (Backend.capture_private_session h.backend) in
    armed := true;
    let reading = Eio.Fiber.fork_promise ~sw (fun () ->
      let verb = if capture then Lane.Page_capture {tab_id=0;options=None}
        else Lane.Page_read {tab_id=Some 0; max_chars=None} in
      Backend.execute h.backend verb) in
    (* Promise resolution cannot suspend: an assertion failure must still let
       the callback's protected cancellation cleanup finish. *)
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ()))
      (fun () ->
        Eio.Promise.await entered;
        Backend.fence_private_session h.backend ~session;
        h.settle ();
        check bool "companion loss reaches the already active page callback" true !cancelled;
        check bool "the page callback's cancellation cleanup is joined" false !joined;
        check bool "no page result is published before cleanup joins" false (Eio.Promise.is_resolved reading);
        check int "no later ordinary call follows companion loss" 1 !calls;
        check bool "fencing keeps the unsaved original browser running" false original.stopped;
        check bool "status remains available while page cancellation joins" true
          (flag "private_operation_unsettled" (data (Backend.execute h.backend Lane.Session_status)));
        ignore (data (Backend.execute h.backend Lane.Session_close));
        check bool "explicit close joins the exact original browser" true original.stopped;
        ignore (data (Backend.execute h.backend open_));
        armed := false;
        Backend.fence_private_session h.backend ~session;
        check bool "a repeated old companion loss cannot fence the successor" true
          (Backend.session_observation h.backend = Lane.Browser_open);
        let next_page = Eio.Fiber.fork_promise ~sw (fun () -> Backend.execute h.backend Lane.Tabs_list) in
        h.settle ();
        check bool "successor pages wait for original page cleanup" false (Eio.Promise.is_resolved next_page);
        Eio.Promise.resolve allow_cleanup ();
        private_page_discarded (Eio.Promise.await_exn reading);
        check bool "cancellation-ignoring callback finishes before slot release" true !joined;
        ignore (data (Eio.Promise.await_exn next_page));
        check int "the old callback never dispatches another ordinary call" 1 !calls;
        check int "cancelled capture never dispatches its later screenshot" 0 !followups;
        check bool "late page cleanup leaves the successor open" true
          (Backend.session_observation h.backend = Lane.Browser_open);
        ignore (private_ok (Backend.capture_private_session h.backend)))))

let test_companion_loss_discards_synchronous_capture ~during_screenshot =
  let armed = ref false and observations = ref 0 and screenshots = ref 0 in
  let notify_loss = ref ignore in
  let call_hook = function
    | Wire.Page_evaluate _ when !armed ->
      incr observations;
      if not during_screenshot then !notify_loss ();
      Some (Ok summary)
    | Wire.Page_screenshot _ when !armed ->
      incr screenshots;
      !notify_loss ();
      Some (Ok (`Assoc ["data", `String "PRIVATE_CAPTURE_MARKER"]))
    | Wire.Close | Wire.Act _ | Wire.Observe _ | Wire.Extract _ | Wire.Context_pages
    | Wire.Context_active_page | Wire.Context_new_page
    | Wire.Page_close _ | Wire.Page_reload _ | Wire.Page_go_back _ | Wire.Page_go_forward _ | Wire.Page_goto _
    | Wire.Page_screenshot _ | Wire.Page_evaluate _ | Wire.Page_hover _ | Wire.Page_set_viewport_size _
    | Wire.Page_click _ | Wire.Page_double_click _ | Wire.Page_scroll _ | Wire.Page_drag_and_drop _
    | Wire.Page_type _ | Wire.Page_key_press _ -> None in
  with_backend ~call_hook (fun h ->
    ignore (data (Backend.execute h.backend open_));
    ignore (data (Backend.execute h.backend Lane.Tabs_list));
    let session = private_ok (Backend.capture_private_session h.backend) in
    notify_loss := (fun () -> Backend.fence_private_session h.backend ~session);
    armed := true;
    private_page_discarded (Backend.execute h.backend (Lane.Page_capture {tab_id=0;options=None}));
    check int "a synchronous fence prevents all capture follow-up observations" 1 !observations;
    check int "loss during the initial observation prevents screenshot dispatch"
      (if during_screenshot then 1 else 0) !screenshots;
    check bool "queued page work is refused before any effect" true
      (match Backend.execute h.backend Lane.Tabs_list with
       | Lane.Rejected_before_effect _ -> true
       | Lane.Answered _ | Lane.Lane_absent | Lane.Timed_out | Lane.Refused _ -> false);
    ignore (data (Backend.execute h.backend Lane.Session_close)))

let () =
  run "browser_stagehand_backend" [
    "private companion", [
      test_case "synchronous private success is discarded after fencing its pin" `Quick
        test_private_synchronous_fence_discards_success;
      test_case "worker loss joins private cleanup and discards returned success" `Quick
        test_private_worker_loss_joins_and_discards_returned_success;
      test_case "companion loss cancels active reads and joins returned cleanup" `Quick
        (fun () -> test_companion_loss_cancels_and_joins_active_page ~capture:false);
      test_case "companion loss cancels capture before later dispatch" `Quick
        (fun () -> test_companion_loss_cancels_and_joins_active_page ~capture:true);
      test_case "synchronous companion loss discards capture bytes" `Quick
        (fun () -> test_companion_loss_discards_synchronous_capture ~during_screenshot:true);
      test_case "synchronous companion loss blocks later capture dispatch" `Quick
        (fun () -> test_companion_loss_discards_synchronous_capture ~during_screenshot:false);
      test_case "private work waits for public extension settlement" `Quick test_private_requires_settled_public_input;
      test_case "original session and CDP target are pinned" `Quick test_private_original_session_and_tab;
      test_case "private operations exclude page observations" `Quick test_private_read_exclusion;
      test_case "unknown private effect fences until original retirement" `Quick test_private_unknown_fences_and_never_rebinds;
      test_case "private cancellation after dispatch fences reads" `Quick test_private_cancel_after_dispatch_fences;
      test_case "private cancellation while queued sends nothing" `Quick test_private_cancel_before_dispatch_preserves_session;
      test_case "explicit close joins private work and releases reopened pages" `Quick
        test_private_close_joins_callback_and_releases_reopened_pages;
    ];
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
