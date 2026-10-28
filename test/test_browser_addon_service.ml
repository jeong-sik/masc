open Alcotest
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
module Service = Masc.Browser_addon_service
module B = Browser_lane
let ok = function Ok value -> value | Error message -> fail message
let incarnation = "0b000000-0000-4000-8000-000000000001"
let client_id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000101")
let client = {B.client_id;browser=B.Firefox;version="test";engine_version="test";
  transport=B.Webdriver_bidi;space=None}
let live_request = {W.incarnation;command=W.Issue {route=B.Live_route (Some client_id);
  verb=B.Page_document {tab_id=7};actor=None;timeout_sec=30.;only_if_idle=true}}
let raw_request = Yojson.Safe.to_string (W.to_json live_request)

let framing_preflight () =
  let calls = ref 0 in
  let dispatch _ = incr calls; W.Receipt in
  let check_blocked label input =
    let reader=Eio.Buf_read.of_string input in
    check bool label true
      (Option.is_none (Service.For_testing.read_request ~dispatch ~reader ~max_message_bytes:4096));
    check int "preflight starts no dispatch" 0 !calls in
  check_blocked "buffered trailing byte is refused" (raw_request ^ "\nextra");
  check_blocked "EOF without terminator is refused" raw_request;
  let snapshot=Yojson.Safe.to_string (W.to_json {W.incarnation;command=W.Snapshot}) in
  let call input bound =
    let reader=Eio.Buf_read.of_string input in
    Service.For_testing.read_request ~dispatch ~reader ~max_message_bytes:bound in
  check bool "unwatched EOF frame remains accepted at the limit" true
    (match call snapshot (String.length snapshot) with Some W.Receipt -> true
     | Some (W.Snapshot_result _ | W.Model_reply _ | W.Extension_reply _
       | W.Download_reply _ | W.Poll_result _ | W.Issue_result _ | W.Service_refusal _)
     | None -> false);
  check bool "one byte over the limit is refused" true
    (match call (snapshot ^ "\n") (String.length snapshot - 1) with
     | Some (W.Service_refusal {disposition=W.Not_started;_}) -> true
     | Some (W.Service_refusal {disposition=W.Outcome_unknown;_} | W.Snapshot_result _
       | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ | W.Poll_result _
       | W.Issue_result _ | W.Receipt) | None -> false)

let cancellation_scope () =
  let issue route verb = W.Issue {route;verb;actor=None;timeout_sec=30.;only_if_idle=false} in
  check bool "selected live document is watched" true
    (W.ends_with_caller live_request.command);
  List.iter (fun (label,command) ->
    check bool label false (W.ends_with_caller command))
    [ "unselected live", issue (B.Live_route None) B.Tabs_list
    ; "automation", issue B.Automation_route B.Tabs_list
    ; "stagehand", issue B.Stagehand_route B.Tabs_list
    ; "downloads", issue (B.Live_route (Some client_id)) (B.Page_downloads {tab_id=7})
    ; "snapshot", W.Snapshot
    ; "retire", W.Retire
    ; "poll", W.Poll {client;window_sec=1.} ]

let bounded_flow_framing () =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
      Eio.Switch.run (fun sw ->
        let snapshot=Yojson.Safe.to_string (W.to_json {W.incarnation;command=W.Snapshot}) in
        let bound=String.length snapshot in
        let calls=ref 0 in
        let dispatch _ = incr calls; W.Receipt in
        let read input =
          let source,sink=Eio_unix.pipe sw in
          Eio.Flow.copy_string input sink;
          Eio.Flow.close sink;
          let reader=Eio.Buf_read.of_flow source ~initial_size:(min 4096 (bound+2))
            ~max_size:(bound+2) in
          Service.For_testing.read_request ~dispatch ~reader ~max_message_bytes:bound in
        check bool "LF frame at the flow bound is accepted" true
          (match read (snapshot ^ "\n") with Some W.Receipt -> true
           | Some (W.Snapshot_result _ | W.Model_reply _ | W.Extension_reply _
             | W.Download_reply _ | W.Poll_result _ | W.Issue_result _ | W.Service_refusal _)
           | None -> false);
        check bool "CRLF frame at the flow bound is accepted" true
          (match read (snapshot ^ "\r\n") with Some W.Receipt -> true
           | Some (W.Snapshot_result _ | W.Model_reply _ | W.Extension_reply _
             | W.Download_reply _ | W.Poll_result _ | W.Issue_result _ | W.Service_refusal _)
           | None -> false);
        check bool "flow exceeding the bound is refused" true
          (match read (snapshot ^ " \n") with
           | Some (W.Service_refusal {disposition=W.Not_started;_}) -> true
           | Some (W.Service_refusal {disposition=W.Outcome_unknown;_} | W.Snapshot_result _
             | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ | W.Poll_result _
             | W.Issue_result _ | W.Receipt) | None -> false);
        check bool "CRLF flow exceeding the bound is refused" true
          (match read (snapshot ^ " \r\n") with
           | Some (W.Service_refusal {disposition=W.Not_started;_}) -> true
           | Some (W.Service_refusal {disposition=W.Outcome_unknown;_} | W.Snapshot_result _
             | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ | W.Poll_result _
             | W.Issue_result _ | W.Receipt) | None -> false);
        check int "only the bounded frames are dispatched" 2 !calls)))

let buffered_violation_wins_completion () =
  Eio_main.run (fun _env ->
    let reader=Eio.Buf_read.of_string "extra" in
    let calls=ref 0 in
    let result=Service.For_testing.handle_watched
      ~dispatch:(fun _ -> incr calls; W.Receipt) reader live_request in
    check int "dispatch reached the completion boundary" 1 !calls;
    check bool "buffered violation prevents response commit" true (Option.is_none result))

let watched_completion_order () =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
      Eio.Switch.run (fun sw ->
        let source,sink=Eio_unix.pipe sw in
        let reader=Eio.Buf_read.of_flow source ~max_size:1024 in
        let entered,notify_entered=Eio.Promise.create () in
        let blocked,_release=Eio.Promise.create () in
        let cancelled=ref false in
        let result=Eio.Fiber.fork_promise ~sw (fun () ->
          Service.For_testing.handle_watched ~dispatch:(fun _ ->
            Eio.Promise.resolve notify_entered ();
            Fun.protect ~finally:(fun () -> cancelled:=true) (fun () ->
              Eio.Promise.await blocked; W.Receipt)) reader live_request) in
        Eio.Promise.await entered;
        Eio.Flow.copy_string "extra" sink;
        check bool "observed violation cancels waiting dispatch" true
          (Option.is_none (Eio.Promise.await_exn result) && !cancelled);
        let source2,sink2=Eio_unix.pipe sw in
        let reader2=Eio.Buf_read.of_flow source2 ~max_size:1024 in
        let result=Service.For_testing.handle_watched ~dispatch:(fun _ -> W.Receipt)
          reader2 live_request in
        Eio.Flow.copy_string "late" sink2;
        check bool "completion committed before a later byte" true
          (match result with Some W.Receipt -> true
           | Some (W.Snapshot_result _ | W.Model_reply _ | W.Extension_reply _
               | W.Download_reply _ | W.Poll_result _ | W.Issue_result _ | W.Service_refusal _)
           | None -> false))))

let simultaneous_completion_and_observation () =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
      Eio.Switch.run (fun sw ->
        let source,sink=Eio_unix.pipe sw in
        let reader=Eio.Buf_read.of_flow source ~max_size:1024 in
        let dispatch_ready,notify_dispatch=Eio.Promise.create () in
        let dispatch_returning,notify_returning=Eio.Promise.create () in
        let watcher_ready,notify_watcher=Eio.Promise.create () in
        let dispatch_gate,release_dispatch=Eio.Promise.create () in
        let watcher_gate,_release_watcher=Eio.Promise.create () in
        let result=Eio.Fiber.fork_promise ~sw (fun () ->
          Service.For_testing.handle_watched_with_hook
            ~dispatch:(fun _ -> Eio.Promise.resolve notify_dispatch ();
              Eio.Promise.await dispatch_gate; Eio.Promise.resolve notify_returning (); W.Receipt)
            ~before_observation:(fun () -> Eio.Promise.resolve notify_watcher ();
              Eio.Promise.await watcher_gate)
            reader live_request) in
        Eio.Promise.await dispatch_ready;
        Eio.Flow.copy_string "extra" sink;
        Eio.Promise.await watcher_ready;
        (* Both branches are ready. Keep the observer from registering its
           result while dispatch returns; the buffered-byte check must win. *)
        Eio.Promise.resolve release_dispatch ();
        Eio.Promise.await dispatch_returning;
        check bool "prepared violation prevents a simultaneous completion" true
          (Option.is_none (Eio.Promise.await_exn result)))))

let dispatch_failure_boundary () =
  let effects=ref 0 in
  let reply=Service.For_testing.handle_dispatch
    ~dispatch:(fun _ -> incr effects; raise Exit) live_request in
  check int "effect preceded failure" 1 !effects;
  check bool "failure after an effect has unknown outcome" true
    (match reply with
     | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
     | W.Service_refusal {disposition=W.Not_started;_} | W.Snapshot_result _
     | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ | W.Poll_result _
     | W.Receipt | W.Issue_result _ -> false);
  check bool "Eio cancellation propagates" true
    (match Service.For_testing.handle_dispatch
       ~dispatch:(fun _ -> raise (Eio.Cancel.Cancelled Exit)) live_request with
     | exception Eio.Cancel.Cancelled _ -> true
     | _ -> false)

let exercise_departure ~connect owner =
  (match Owner.poll_live owner ~client ~window_sec:0.001 with
   | Ok None -> () | Ok (Some _) -> fail "unexpected initial work" | Error detail -> fail detail);
  ok (Owner.attach_live owner ~client_id ~cleanup:(fun () -> Ok ()));
  let start terminator =
    let flow=connect () in
    Eio.Flow.copy_string (raw_request ^ terminator) flow;
    flow in
  let poll () = match Owner.poll_live owner ~client ~window_sec:1. with
    | Ok (Some command) -> command
    | Ok None -> fail "live command was not queued"
    | Error detail -> fail detail in
  let first=start "\n" in
  let command_a=poll () in
  let interrupt = match Owner.live_request_window owner ~client_id ~id:command_a.B.id with
    | B.Live_waiting_until (_, signal) | B.Live_executor_owned signal -> signal
    | B.No_live_waiter -> fail "first command lacks a waiter" in
  Eio.Flow.close first;
  Eio.Promise.await interrupt;
  let rec await_removed () =
    match Owner.live_request_window owner ~client_id ~id:command_a.id with
    | B.No_live_waiter -> ()
    | B.Live_waiting_until _ | B.Live_executor_owned _ -> Eio.Fiber.yield (); await_removed () in
  await_removed ();
  let second=start "\r\n" in
  let command_b=poll () in
  let payload = `Assoc ["ok",`Bool true;"data",`Assoc ["html",`String "fixture"]] in
  check bool "late A result is rejected" true
    (Result.is_error (Owner.deliver_live owner ~client_id ~id:command_a.id ~payload));
  check bool "late A result does not complete B" true
    (match Owner.live_request_window owner ~client_id ~id:command_b.id with
     | B.Live_waiting_until _ | B.Live_executor_owned _ -> true
     | B.No_live_waiter -> false);
  ok (Owner.deliver_live owner ~client_id ~id:command_b.id ~payload);
  let response=Eio.Buf_read.line (Eio.Buf_read.of_flow second ~max_size:4096) in
  check bool "B receives its own result" true
    (match ok (W.reply_of_json (Yojson.Safe.from_string response)) with
     | W.Issue_result (Ok (B.Answered actual)) -> actual=payload
     | W.Issue_result (Ok (B.Lane_absent|B.Timed_out|B.Refused _|B.Rejected_before_effect _))
     | W.Issue_result (Error _) | W.Snapshot_result _ | W.Poll_result _ | W.Receipt
     | W.Service_refusal _ | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ -> false);
  let third=start "\n" in
  let command_c=poll () in
  let interrupt_c = match Owner.live_request_window owner ~client_id ~id:command_c.id with
    | B.Live_waiting_until (_, signal) | B.Live_executor_owned signal -> signal
    | B.No_live_waiter -> fail "third command lacks a waiter" in
  Eio.Flow.copy_string "extra" third;
  Eio.Promise.await interrupt_c;
  let output=match Eio.Buf_read.take_all (Eio.Buf_read.of_flow third ~max_size:4096) with
    | output -> output
    | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> "" in
  check string "later framing violation gets no reply" "" output;
  let rec await_removed_id id =
    match Owner.live_request_window owner ~client_id ~id with
    | B.No_live_waiter -> ()
    | B.Live_waiting_until _ | B.Live_executor_owned _ -> Eio.Fiber.yield (); await_removed_id id in
  await_removed_id command_c.id;
  let queued=start "\n" in
  let rec await_queue () =
    let present=Eio.Mutex.use_ro B.clients_mutex (fun () ->
      match Hashtbl.find_opt B.clients (B.client_id_to_string client_id) with
      | Some live -> Eio.Stream.length live.commands > 0
      | None -> false) in
    if not present then (Eio.Fiber.yield (); await_queue ()) in
  await_queue ();
  let queued_id = match fst (B.activity_for client) with
    | [activity] -> activity.B.request_id
    | _ -> fail "expected exactly the queued request" in
  Eio.Flow.close queued;
  await_removed_id queued_id;
  let busy=start "\n" in
  let raw=Eio.Buf_read.line (Eio.Buf_read.of_flow busy ~max_size:4096) in
  check bool "queued cancelled work keeps idle admission busy" true
    (match ok (W.reply_of_json (Yojson.Safe.from_string raw)) with
     | W.Issue_result (Ok (B.Refused "optional_document_observation_busy")) -> true
     | W.Issue_result (Ok (B.Answered _ | B.Lane_absent | B.Timed_out
         | B.Refused _ | B.Rejected_before_effect _))
     | W.Issue_result (Error _) | W.Snapshot_result _ | W.Poll_result _ | W.Receipt
     | W.Service_refusal _ | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ -> false);
  (match Owner.poll_live owner ~client ~window_sec:0.01 with
   | Ok None -> () | Ok (Some _) -> fail "cancelled queued request was delivered"
   | Error detail -> fail detail);
  let after_drain=start "\n" in
  let fresh=poll () in
  ok (Owner.deliver_live owner ~client_id ~id:fresh.id ~payload);
  let reply=Eio.Buf_read.line (Eio.Buf_read.of_flow after_drain ~max_size:4096) in
  check bool "new idle work succeeds after queue drain" true
    (match ok (W.reply_of_json (Yojson.Safe.from_string reply)) with
     | W.Issue_result (Ok (B.Answered actual)) -> actual=payload
     | W.Issue_result (Ok (B.Lane_absent | B.Timed_out | B.Refused _ | B.Rejected_before_effect _))
     | W.Issue_result (Error _) | W.Snapshot_result _ | W.Poll_result _ | W.Receipt
     | W.Service_refusal _ | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ -> false)

(* An independent extension-client fixture keeps A executing after its caller
   leaves. Queueing B cannot be mistaken for an idle or completed executor. *)
let exercise_extension_departure ~sw ~connect owner =
  let extension_id=ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000102") in
  let extension={client with B.client_id=extension_id;transport=B.Web_extension} in
  (match Owner.poll_live owner ~client:extension ~window_sec:0.001 with
   | Ok None -> () | Ok (Some _) -> fail "unexpected extension work" | Error detail -> fail detail);
  let request={W.incarnation;command=W.Issue {route=B.Live_route (Some extension_id);
    verb=B.Tabs_list;actor=None;timeout_sec=30.;only_if_idle=false}} in
  let start () =
    let flow=connect () in
    Eio.Flow.copy_string (Yojson.Safe.to_string (W.to_json request) ^ "\n") flow;
    flow in
  let poll () = match Owner.poll_live owner ~client:extension ~window_sec:1. with
    | Ok (Some command) -> command
    | Ok None -> fail "extension command was not queued"
    | Error detail -> fail detail in
  let first=start () in
  let entered,notify_entered=Eio.Promise.create () in
  let release,release_executor=Eio.Promise.create () in
  let payload name = `Assoc ["ok",`Bool true;"data",`String name] in
  let executor=Eio.Fiber.fork_promise ~sw (fun () ->
    let a=poll () in
    Eio.Promise.resolve notify_entered a;
    Eio.Promise.await release;
    let late=Owner.deliver_live owner ~client_id:extension_id ~id:a.B.id ~payload:(payload "A") in
    let b=poll () in
    ok (Owner.deliver_live owner ~client_id:extension_id ~id:b.B.id ~payload:(payload "B"));
    late) in
  let a=Eio.Promise.await entered in
  Eio.Flow.close first;
  let rec await_removed () =
    match Owner.live_request_window owner ~client_id:extension_id ~id:a.B.id with
    | B.No_live_waiter -> ()
    | B.Live_waiting_until _ | B.Live_executor_owned _ -> Eio.Fiber.yield (); await_removed () in
  await_removed ();
  let second=start () in
  let response=Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Buf_read.line (Eio.Buf_read.of_flow second ~max_size:4096)) in
  let rec await_queued () =
    let queued=Eio.Mutex.use_ro B.clients_mutex (fun () ->
      match Hashtbl.find_opt B.clients (B.client_id_to_string extension_id) with
      | Some live -> Eio.Stream.length live.commands > 0
      | None -> false) in
    if not queued then (Eio.Fiber.yield (); await_queued ()) in
  await_queued ();
  check bool "queued B does not mean the held executor finished A" true
    (Eio.Promise.peek executor=None && Eio.Promise.peek response=None);
  Eio.Promise.resolve release_executor ();
  check bool "late extension A is not delivered to B" true
    (Result.is_error (Eio.Promise.await_exn executor));
  let raw=Eio.Promise.await_exn response in
  check bool "extension B receives only its own result" true
    (match ok (W.reply_of_json (Yojson.Safe.from_string raw)) with
     | W.Issue_result (Ok (B.Answered actual)) -> actual=payload "B"
     | W.Issue_result (Ok (B.Lane_absent | B.Timed_out | B.Refused _ | B.Rejected_before_effect _))
     | W.Issue_result (Error _) | W.Snapshot_result _ | W.Poll_result _ | W.Receipt
     | W.Service_refusal _ | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _ -> false)
let scenario () =
  let directory = Filename.temp_file "ba" "" in
  Unix.unlink directory;Unix.mkdir directory 0o700;
  let directory = Unix.realpath directory in
  Fun.protect ~finally:(fun () -> Unix.rmdir directory) (fun () ->
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
        let net = Eio.Stdenv.net env in
        let owner = ok (Owner.create ~incarnation) in
        Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
        let path = Filename.concat directory "s" and small = Filename.concat directory "t"
        and failing = Filename.concat directory "f" and exact = Filename.concat directory "e" in
        let ready path =
          let rec wait () = match Unix.lstat path with
            | _ -> ()
            | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Eio.Fiber.yield ();wait () in wait () in
        let connect path = Eio.Net.connect ~sw net (`Unix path) in
        Eio.Fiber.first
          (fun () -> Service.serve ~net ~owner ~socket_path:path ~max_message_bytes:4096)
          (fun () ->
            ready path;
            let idle = connect path in Eio.Flow.copy_string "{" idle;
            let live = connect path in
            Eio.Flow.copy_string (Yojson.Safe.to_string (W.to_json {W.incarnation;command=W.Snapshot}) ^ "\n") live;
            let raw = Eio.Buf_read.line (Eio.Buf_read.of_flow live ~max_size:4096) in
            check bool "idle client does not block another request" true
              (match ok (W.reply_of_json (Yojson.Safe.from_string raw)) with
               | W.Snapshot_result _ -> true
               | W.Poll_result _|Receipt|Issue_result _|Service_refusal _
               | Model_reply _|Extension_reply _|Download_reply _ -> false);
            let malformed = connect path in
            Eio.Flow.copy_string "{\"private\":PRIVATE_FRAME_MARKER}\n" malformed;
            let reply = Eio.Buf_read.line (Eio.Buf_read.of_flow malformed ~max_size:4096) in
            check bool "JSON parser fragments never enter the private transport reply" true
              (match ok (W.reply_of_json (Yojson.Safe.from_string reply)) with
               | W.Service_refusal {disposition=W.Not_started;message="invalid browser worker JSON"} -> true
               | Snapshot_result _|Poll_result _|Receipt|Issue_result _|Service_refusal _|Model_reply _|Extension_reply _|Download_reply _ -> false);
            exercise_departure ~connect:(fun () -> connect path) owner;
            exercise_extension_departure ~sw ~connect:(fun () -> connect path) owner;
            let effects=ref 0 in
            let entered,notify_entered=Eio.Promise.create () in
            let released,release=Eio.Promise.create () in
            let write_error,notify_error=Eio.Promise.create () in
            Eio.Fiber.first
              (fun () -> Service.For_testing.serve_with_dispatch ~net ~socket_path:failing
                ~on_error:(fun error -> ignore (Eio.Promise.try_resolve notify_error error))
                ~before_write:(fun () -> if !effects=2 then
                  (Eio.Promise.resolve notify_entered (); Eio.Promise.await released))
                ~max_message_bytes:4096 ~dispatch:(fun _ ->
                  incr effects;
                  if !effects=1 then raise Exit
                  else W.Receipt))
              (fun () ->
                ready failing;
                let first=connect failing in
                Eio.Flow.copy_string (raw_request ^ "\n") first;
                let response=Eio.Buf_read.line (Eio.Buf_read.of_flow first ~max_size:4096) in
                check bool "effect failure over socket is outcome unknown" true
                  (match ok (W.reply_of_json (Yojson.Safe.from_string response)) with
                   | W.Service_refusal {disposition=W.Outcome_unknown;_} -> true
                   | W.Service_refusal {disposition=W.Not_started;_} | W.Snapshot_result _
                   | W.Model_reply _ | W.Extension_reply _ | W.Download_reply _
                   | W.Poll_result _ | W.Receipt | W.Issue_result _ -> false);
                let second=connect failing in
                Eio.Flow.copy_string (Yojson.Safe.to_string
                  (W.to_json {W.incarnation;command=W.Snapshot}) ^ "\n") second;
                Eio.Promise.await entered;
                Eio.Flow.close second;
                Eio.Promise.resolve release ();
                check bool "write after peer close is a connection reset" true
                  (match Eio.Promise.await write_error with
                   | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> true
                   | _ -> false);
                let third=connect failing in
                Eio.Flow.copy_string (Yojson.Safe.to_string
                  (W.to_json {W.incarnation;command=W.Snapshot}) ^ "\n") third;
                let response=Eio.Buf_read.line (Eio.Buf_read.of_flow third ~max_size:4096) in
                check bool "same listener accepts the next request" true
                  (match ok (W.reply_of_json (Yojson.Safe.from_string response)) with
                   | W.Receipt -> true
                   | W.Snapshot_result _ | W.Model_reply _ | W.Extension_reply _
                   | W.Download_reply _ | W.Poll_result _ | W.Issue_result _
                   | W.Service_refusal _ -> false);
                check int "all connections reached dispatch" 3 !effects);
            let exact_calls=ref 0 in
            Eio.Fiber.first
              (fun () -> Service.For_testing.serve_with_dispatch ~net ~socket_path:exact
                ~on_error:(fun _ -> ()) ~before_write:(fun () -> ())
                ~max_message_bytes:(String.length raw_request) ~dispatch:(fun _ ->
                  incr exact_calls; W.Receipt))
              (fun () ->
                ready exact;
                let flow=connect exact in
                Eio.Flow.copy_string (raw_request ^ "\r\n") flow;
                let raw=Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:4096) in
                check bool "watched service request accepts CRLF at its exact payload limit" true
                  (match ok (W.reply_of_json (Yojson.Safe.from_string raw)) with
                   | W.Receipt -> true
                   | W.Snapshot_result _ | W.Model_reply _ | W.Extension_reply _
                   | W.Download_reply _ | W.Poll_result _ | W.Issue_result _
                   | W.Service_refusal _ -> false);
                check int "exact CRLF dispatches once" 1 !exact_calls);
            Eio.Fiber.first
              (fun () -> Service.serve ~net ~owner ~socket_path:small ~max_message_bytes:1)
              (fun () ->
                ready small;let flow=connect small in Eio.Flow.copy_string "{}\n" flow;
                let reader=Eio.Buf_read.of_flow flow ~max_size:4096 in
                (* No reply fits a 1-byte bound, so the service closes without
                   reading the rest of the request. Linux then resets the
                   connection where macOS sends EOF; neither carries a byte. *)
                let output=match Eio.Buf_read.take_all reader with
                  | output -> output
                  | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> "" in
                check int "small bound is never exceeded by fallback" 0 (String.length output));
            Owner.revoke owner);
        check bool "normal socket removed after cancellation" false (Sys.file_exists path);
        check bool "test socket removed after cancellation" false (Sys.file_exists failing);
        check bool "exact bound socket removed after cancellation" false (Sys.file_exists exact);
        check bool "small socket removed after cancellation" false (Sys.file_exists small)))))
let () = run "browser addon service" ["transport",[
  test_case "framing preflight" `Quick framing_preflight;
  test_case "departure cancellation scope" `Quick cancellation_scope;
  test_case "bounded flow framing" `Quick bounded_flow_framing;
  test_case "buffered violation wins completion" `Quick buffered_violation_wins_completion;
  test_case "watched completion ordering" `Quick watched_completion_order;
  test_case "simultaneous completion and observation" `Quick simultaneous_completion_and_observation;
  test_case "dispatch failure boundary" `Quick dispatch_failure_boundary;
  test_case "idle cancellation and tiny bound" `Quick scenario]]
