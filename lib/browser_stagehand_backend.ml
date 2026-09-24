module Session = Browser_stagehand_session
module Executor = Browser_stagehand_executor
module Wire = Browser_stagehand_wire

type 'session opener =
  sw:Eio.Switch.t
  -> headless:bool
  -> log:(Session.event -> unit)
  -> ('session * Yojson.Safe.t, string) result

type 'session opened =
  { session : 'session
  ; tabs : Executor.Tabs.t
  ; release : unit Eio.Promise.u
  ; stopped : unit Eio.Promise.t
  ; ended : string option ref  (* the first reason the session stopped working *)
  }

type 'session state = Closed | Opening | Open of 'session opened | Closing

type request =
  { verb : Browser_lane.verb
  ; reply : Browser_lane.answer Eio.Promise.u
  ; caller_left : unit Eio.Promise.t
  }

type 'session t =
  { sw : Eio.Switch.t
  ; sleep : float -> unit
  ; open_session : 'session opener
  ; call : 'session -> Executor.call
  ; pid : 'session -> int
  ; log : Session.event -> unit
  ; requests : request Eio.Stream.t
  ; mutable state : 'session state
  }

let backend_name = "chromium-stagehand"

(* The runtime is asked to close before its browser stops. The browser stops
   either way, so its answer is waited for only this long. *)
let close_answer_wait_s = 5.

let answered data = Browser_lane.Answered (`Assoc [ "ok", `Bool true; "data", data ])

let in_transition =
  Browser_lane.Rejected_before_effect "the stagehand session is opening or closing; ask again"
;;

let no_session =
  Browser_lane.Rejected_before_effect "no stagehand session is open: open one with BrowserSession lane=stagehand"
;;

let note_end ended event =
  let reason =
    match event with
    | Session.Worker_detached -> Some "the service worker went away"
    | Session.Connection_ended reason -> Some ("the connection ended: " ^ reason)
    (* The session ends with an answer it could not deliver. *)
    | Session.Reply_not_delivered detail -> Some ("an answer to the extension was not delivered: " ^ detail)
    | Session.Runtime_ready _ | Session.Model_request_refused _ | Session.Model_failed _ | Session.Unsupported_request _
    | Session.Unsupported_notification _ | Session.Extension_log _ | Session.Malformed_message _
    | Session.Unexpected_response _ | Session.Abandoned_call_ended _ | Session.Malformed_cdp_event _ -> None
  in
  match !ended, reason with
  | None, Some _ -> ended := reason
  | Some _, (Some _ | None) | None, None -> ()
;;

(* The session's whole life, on a daemon fiber of the backend's switch. It
   ends when close releases it, when the session fails, or when the server
   stops: a daemon is cancelled once the switch's other fibers are done, so an
   open browser never holds the server's switch open. The browser stops with
   the inner switch in every case. *)
let run_session t ~headless ~opened ~resolve_opened =
  let ended = ref None in
  let log event =
    note_end ended event;
    t.log event
  in
  let stopped, resolve_stopped = Eio.Promise.create () in
  let not_opened detail =
    if not (Eio.Promise.is_resolved opened) then Eio.Promise.resolve resolve_opened (Error detail)
  in
  let finish () =
    t.state <- Closed;
    Eio.Promise.resolve resolve_stopped ()
  in
  (match
    Eio.Switch.run (fun session_sw ->
      match t.open_session ~sw:session_sw ~headless ~log with
      | Error detail ->
        (* The browser may be running; it stops as this switch ends, and
           until then the backend is closing, not opening. *)
        t.state <- Closing;
        not_opened detail
      | Ok (session, _init) ->
        let released, release = Eio.Promise.create () in
        t.state <- Open { session; tabs = Executor.Tabs.create (); release; stopped; ended };
        Eio.Promise.resolve resolve_opened (Ok ());
        Eio.Promise.await released)
  with
  | () -> finish ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    not_opened "the server is stopping";
    finish ();
    raise exn
  | exception exn ->
    (* The opener and the session's fibers fail this session, not the server
       whose switch this fiber is on. *)
    not_opened ("the stagehand session failed: " ^ Printexc.to_string exn);
    finish ());
  `Stop_daemon
;;

let open_session t ~headless =
  match t.state with
  | Open _ -> answered (`Assoc [ "opened", `Bool true; "reused", `Bool true; "backend", `String backend_name ])
  | Opening | Closing -> in_transition
  | Closed ->
    t.state <- Opening;
    let opened, resolve_opened = Eio.Promise.create () in
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () -> run_session t ~headless ~opened ~resolve_opened);
    (match Eio.Promise.await opened with
     | Ok () -> answered (`Assoc [ "opened", `Bool true; "reused", `Bool false; "backend", `String backend_name ])
     | Error detail -> Browser_lane.Refused ("the stagehand browser did not open: " ^ detail))
;;

let close_session t =
  match t.state with
  | Closed -> answered (`Assoc [ "closed", `Bool true ])
  | Opening | Closing -> in_transition
  | Open opened ->
    t.state <- Closing;
    let runtime =
      Watched_work.run
        ~watcher:(fun () ->
          t.sleep close_answer_wait_s;
          Printf.sprintf "no answer within %.0f s" close_answer_wait_s)
        (fun () ->
          match t.call opened.session Wire.Close with
          | Ok _ -> "closed"
          | Error failure -> "did not close: " ^ Executor.failure_message failure)
    in
    Eio.Promise.resolve opened.release ();
    Eio.Promise.await opened.stopped;
    answered (`Assoc [ "closed", `Bool true; "runtime", `String runtime ])
;;

let status t =
  let fields =
    match t.state with
    | Closed -> [ "open", `Bool false ]
    | Opening -> [ "open", `Bool false; "opening", `Bool true ]
    | Closing -> [ "open", `Bool true; "closing", `Bool true ]
    | Open opened ->
      [ "open", `Bool true; "backend", `String backend_name; "pid", `Int (t.pid opened.session) ]
      @ (match !(opened.ended) with Some reason -> [ "ended", `String reason ] | None -> [])
  in
  answered (`Assoc fields)
;;

let page t verb =
  match t.state with
  | Open opened -> Executor.execute ~tabs:opened.tabs ~call:(t.call opened.session) verb
  | Closed | Opening | Closing -> no_session
;;

(* A verb's exception answers its own request instead of failing the switch
   every request is served on. Cancellation passes through. *)
let guarded work =
  match work () with
  | answer -> answer
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Browser_lane.Refused ("the stagehand backend failed: " ^ Printexc.to_string exn)
;;

let is_sentence = function
  | Browser_lane.Page_instruct _ | Browser_lane.Page_locate _ | Browser_lane.Page_extract _ -> true
  | Browser_lane.Session_open _ | Browser_lane.Session_close | Browser_lane.Session_status
  | Browser_lane.Tabs_list | Browser_lane.Page_read _ | Browser_lane.Page_document _ | Browser_lane.Page_downloads _
  | Browser_lane.Page_capture _ | Browser_lane.Page_scene _ | Browser_lane.Page_interact _ | Browser_lane.Page_goto _
  | Browser_lane.Page_elements _ | Browser_lane.Page_act _ | Browser_lane.Page_context _ -> false
;;

(* A sentence whose caller left can remain Abandoned if the extension never
   replies. The stopped browser drops that session; a later open starts a
   fresh one. Match the session captured before the call so a late cleanup
   cannot close a newer session. *)
let retire_sentence_session t expected =
  match expected, t.state with
  | Some expected, Open current when expected == current ->
    t.state <- Closing;
    Eio.Promise.resolve current.release ();
    Eio.Promise.await current.stopped
  | (Some _ | None), (Closed | Opening | Closing | Open _) -> ()
;;

let serve t { verb; reply; caller_left } =
  let run_to_the_end work = Eio.Promise.resolve reply (guarded work) in
  match verb with
  | Browser_lane.Session_open { headless } ->
    (* DET-OK: BrowserSession declares headless true; the verb carries none
       only when a caller left it out. *)
    run_to_the_end (fun () -> open_session t ~headless:(Option.value headless ~default:true))
  | Browser_lane.Session_close -> run_to_the_end (fun () -> close_session t)
  | Browser_lane.Session_status -> run_to_the_end (fun () -> status t)
  | Browser_lane.Tabs_list | Browser_lane.Page_read _ | Browser_lane.Page_document _ | Browser_lane.Page_downloads _
  | Browser_lane.Page_capture _ | Browser_lane.Page_scene _ | Browser_lane.Page_interact _ | Browser_lane.Page_goto _
  | Browser_lane.Page_elements _ | Browser_lane.Page_act _ | Browser_lane.Page_context _ | Browser_lane.Page_instruct _
  | Browser_lane.Page_locate _ | Browser_lane.Page_extract _ ->
    let requested_session = match t.state with Open opened -> Some opened | Closed | Opening | Closing -> None in
    (* A caller that leaves cancels the call it asked for; the session then
       holds it as abandoned until the runtime answers it or the sentence
       session is retired below. *)
    (match
       Watched_work.run
         ~watcher:(fun () ->
           Eio.Promise.await caller_left;
           None)
         (fun () -> Some (guarded (fun () -> page t verb)))
     with
     | Some answer -> Eio.Promise.resolve reply answer
     | None -> if is_sentence verb then retire_sentence_session t requested_session)
;;

let create ~sw ~clock ~open_session ~call ~pid ~log =
  let t =
    { sw
    ; sleep = Eio.Time.sleep clock
    ; open_session
    ; call
    ; pid
    ; log
    ; requests = Eio.Stream.create max_int
    ; state = Closed
    }
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec next () =
      let request = Eio.Stream.take t.requests in
      (* A request waiting on a call that never answers must not hold the
         switch open either; the session it waits on ends with the switch. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
        serve t request;
        `Stop_daemon);
      next ()
    in
    next ());
  t
;;

let execute t verb =
  let answer, reply = Eio.Promise.create () in
  let caller_left, leave = Eio.Promise.create () in
  Eio.Stream.add t.requests { verb; reply; caller_left };
  match Eio.Promise.await answer with
  | answer -> answer
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    Eio.Promise.resolve leave ();
    raise exn
;;
