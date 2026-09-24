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

type behaviour =
  { mutable opening : opening
  ; mutable open_gate : unit Eio.Promise.t option
  ; mutable close_answers : bool
  ; mutable act_cancelled : bool
  }

type harness =
  { backend : fake_session Backend.t
  ; sessions : fake_session list ref
  ; behaviour : behaviour
  ; settle : unit -> unit
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
  let behaviour = { opening = Opens; open_gate = None; close_answers = true; act_cancelled = false } in
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
  let call _session request =
    match request with
    | Wire.Context_pages -> Ok (`List [ page ])
    | Wire.Context_active_page -> Ok page
    | Wire.Page_evaluate _ -> Ok summary
    | Wire.Close ->
      if behaviour.close_answers then Ok (`Assoc [ "closed", `Bool true ]) else Eio.Promise.await never
    | Wire.Act _ ->
      (match Eio.Promise.await never with
       | answer -> answer
       | exception (Eio.Cancel.Cancelled _ as exn) ->
         behaviour.act_cancelled <- true;
         raise exn)
    | Wire.Init _ | Wire.Observe _ | Wire.Extract _ | Wire.Page_goto _ | Wire.Page_screenshot _ | Wire.Page_click _
    | Wire.Page_scroll _ | Wire.Page_drag_and_drop _ ->
      failf "the backend sent %s" (Wire.method_name request)
  in
  let backend = Backend.create ~sw ~clock ~open_session ~call ~pid:(fun _ -> 42) ~log:ignore in
  f { backend; sessions; behaviour; settle = (fun () -> Eio.Time.sleep clock settle_s) }
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

let test_page_verb_follows_its_caller () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  ignore (data (Backend.execute h.backend Lane.Tabs_list));
  leave_during h (Lane.Page_instruct { tab_id = 0; instruction = "click Buy" });
  h.settle ();
  check bool "the call was cancelled with its caller" true h.behaviour.act_cancelled;
  check bool "the session stays open" true (is_open h)
;;

let test_close_does_not_wait_forever () =
  with_backend ~configure:(fun behaviour -> behaviour.close_answers <- false)
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  let closed = data (Backend.execute h.backend Lane.Session_close) in
  check bool "closed" true (flag "closed" closed);
  check bool "the runtime's silence is reported" true (text "runtime" closed <> "closed");
  check bool "the browser stopped anyway" true (the_session h).stopped
;;

let test_status_reports_an_ended_session () =
  with_backend
  @@ fun h ->
  ignore (data (Backend.execute h.backend open_));
  (the_session h).log (Session.Connection_ended "Chromium exited");
  let status = data (Backend.execute h.backend Lane.Session_status) in
  check string "why it stopped working" "the connection ended: Chromium exited" (text "ended" status)
;;

let () =
  run "browser_stagehand_backend" [
    "lifecycle", [
      test_case "open, reuse, list, close" `Quick test_lifecycle;
      test_case "a page verb needs a session" `Quick test_page_verb_without_a_session;
      test_case "a failed or raising open leaves the backend usable" `Quick test_open_failures;
      test_case "an open finishes after its caller leaves" `Quick test_open_outlives_its_caller;
      test_case "close waits for the runtime only so long" `Quick test_close_does_not_wait_forever;
      test_case "status reports why a session ended" `Quick test_status_reports_an_ended_session;
    ];
    "callers", [ test_case "a page verb is cancelled with its caller" `Quick test_page_verb_follows_its_caller ];
  ]
;;
