open Alcotest
module Resources = Masc.Http_h2_response_ledger
module Registry = Server_h2_stream_registry

type lane = {mutable pending:string}
type response = {status:int; reader:H2.Body.Reader.t; mutable waiting:bool;
  mutable ended:bool; body:Buffer.t}
type session = {server:H2.Server_connection.t; client:H2.Client_connection.t;
  upload:lane; download:lane; registry:Registry.t;
  responses:(int,response) Hashtbl.t; mutable wire_tail:string;
  errors:int ref; resets:int ref}

let transfer lane next report read observe =
  let rec drain moved = match next () with
    | `Write iovecs ->
      let text=String.concat "" (List.map (fun (v:_ H2.IOVec.t) ->
        Bigstringaf.substring v.buffer ~off:v.off ~len:v.len) iovecs) in
      observe text; report (`Ok (String.length text));
      let text=lane.pending ^ text in
      let len=String.length text in
      let n=read (Bigstringaf.of_string text ~off:0 ~len) ~off:0 ~len in
      lane.pending <- String.sub text n (len-n); drain true
    | `Yield | `Close _ -> moved in
  drain false

let observe session bytes =
  let bytes=session.wire_tail ^ bytes in
  let rec frames off =
    if String.length bytes-off < 9 then off else
    let byte n=Char.code bytes.[off+n] in
    let length=(byte 0 lsl 16) lor (byte 1 lsl 8) lor byte 2 in
    if String.length bytes-off < 9+length then off else (
      let kind=byte 3 and flags=byte 4 in
      let stream_id=Int32.to_int (String.get_int32_be bytes (off+5)) in
      if kind=3 then (incr session.resets; Registry.reset_sent session.registry ~stream_id)
      else if (kind=0 || kind=1) && flags land 1 <> 0 then
        Registry.response_ended session.registry ~stream_id;
      frames (off+9+length)) in
  let consumed=frames 0 in
  session.wire_tail <- String.sub bytes consumed (String.length bytes-consumed)

let step session =
  Eio.Fiber.yield ();
  ignore (transfer session.upload
    (fun () -> H2.Client_connection.next_write_operation session.client)
    (H2.Client_connection.report_write_result session.client)
    (H2.Server_connection.read session.server) ignore);
  ignore (transfer session.download
    (fun () -> H2.Server_connection.next_write_operation session.server)
    (H2.Server_connection.report_write_result session.server)
    (H2.Client_connection.read session.client) (observe session))

let rec until session predicate =
  if not (predicate ()) then (step session; until session predicate)

let with_session ~capacity handler test =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let resources=Resources.create ~max_pending_bytes:capacity in
        let registry=Registry.create () in
        let responses=Hashtbl.create 4 and errors=ref 0 and resets=ref 0 in
        let server=H2.Server_connection.create
          ~error_handler:(fun ?request:_ _ respond -> H2.Body.Writer.close (respond H2.Headers.empty))
          (fun reqd ->
            let id=int_of_string (H2.Reqd.request reqd).target in
            Registry.dispatch registry ~sw ~stream_id:(id*2-1) reqd
              (fun stream_sw -> Resources.with_request resources ~sw:stream_sw
                (fun () -> handler id ~stream_sw reqd))) in
        let client=H2.Client_connection.create
          ~config:{H2.Config.default with initial_window_size=65535l}
          ~error_handler:(fun _ -> fail "connection error") () in
        let session={server;client;upload={pending=""};download={pending=""};
          registry;responses;wire_tail="";errors;resets} in
        test resources session)))

let request session id =
  let writer=H2.Client_connection.request session.client
    ~flush_headers_immediately:true
    (H2.Request.create ~scheme:"http" `GET (string_of_int id)
      ~headers:(H2.Headers.of_list [":authority","localhost"]))
    ~error_handler:(fun _ -> incr session.errors)
    ~response_handler:(fun response reader -> Hashtbl.add session.responses id
      {status=H2.Status.to_code response.status;reader;waiting=false;ended=false;
       body=Buffer.create 16}) in
  H2.Body.Writer.close writer

let read_once response =
  if not response.waiting && not response.ended then (
    response.waiting <- true;
    H2.Body.Reader.schedule_read response.reader
      ~on_eof:(fun () -> response.waiting <- false; response.ended <- true)
      ~on_read:(fun buffer ~off ~len ->
        response.waiting <- false;
        Buffer.add_string response.body (Bigstringaf.substring buffer ~off ~len)))

let read_all session id =
  until session (fun () -> Hashtbl.mem session.responses id);
  let response=Hashtbl.find session.responses id in
  let rec read () =
    if not response.ended then (read_once response;step session;read ()) in
  read ();
  check bool "valid complete body" true (H2.Body.Reader.completion response.reader=Complete);
  Buffer.contents response.body

let ping session =
  let done_=ref false in
  H2.Client_connection.ping session.client (function
    | Ok () -> done_:=true | Error `EOF -> fail "PING EOF");
  until session (fun () -> !done_)

let reset session id =
  (* The peer cancels delivery as well as sending RST_STREAM. Return the
     unread connection credits so siblings can keep receiving DATA. *)
  Option.iter (fun response -> H2.Body.Reader.discard response.reader)
    (Hashtbl.find_opt session.responses id);
  let bytes=Bytes.make 13 '\000' in
  Bytes.set bytes 2 '\004';Bytes.set bytes 3 '\003';
  Bytes.set_int32_be bytes 5 (Int32.of_int (id*2-1));Bytes.set_int32_be bytes 9 8l;
  Registry.peer_reset session.registry ~stream_id:(id*2-1);
  let text=Bytes.to_string bytes in
  ignore (H2.Server_connection.read session.server
    (Bigstringaf.of_string text ~off:0 ~len:13) ~off:0 ~len:13)

let whole_payload=String.init 131070 (fun n -> Char.chr (97+n mod 26))

let test_whole_response_and_scope_release () =
  let lease_seen=ref None in
  let handler _ ~stream_sw:_ reqd =
    let lease=Resources.reserve (Resources.current_exn ()) ~bytes:(String.length whole_payload)
      |> Result.get_ok in
    lease_seen:=Some lease;
    let writer=H2.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd
      (H2.Response.create `OK) in
    Resources.write_reserved lease writer whole_payload;
    H2.Body.Writer.flush writer (function `Written | `Closed -> H2.Body.Writer.close writer) in
  with_session ~capacity:(String.length whole_payload) handler (fun resources session ->
    request session 1;
    until session (fun () -> Hashtbl.mem session.responses 1);
    check int "whole blocked payload remains charged" (String.length whole_payload)
      (Resources.pending_bytes resources);
    ping session;
    check string "slow reads preserve complete payload" whole_payload (read_all session 1);
    check int "flush releases reservation" 0 (Resources.pending_bytes resources);
    request session 2;
    until session (fun () -> Hashtbl.mem session.responses 2);
    reset session 2;
    until session (fun () -> Resources.pending_bytes resources=0);
    Option.iter Resources.release !lease_seen;
    request session 3;
    check string "same connection reuses released capacity" whole_payload (read_all session 3))

let test_scope_cleanup_and_late_flush_are_idempotent () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun outer ->
    let resources=Resources.create ~max_pending_bytes:10 in
    let previous=ref None in
    Eio.Switch.run (fun sw -> Resources.with_request resources ~sw (fun () ->
      let context=Resources.current_exn () in
      let lease=Resources.reserve context ~bytes:10 |> Result.get_ok in
      previous:=Some lease;
      check bool "exact capacity rejects an additional byte" true
        (Resources.reserve context ~bytes:1=Error Capacity_exhausted)));
    check int "scope releases a writer that never flushed" 0 (Resources.pending_bytes resources);
    Resources.with_request resources ~sw:outer (fun () ->
      let lease=Resources.reserve (Resources.current_exn ()) ~bytes:10 |> Result.get_ok in
      Option.iter Resources.release !previous;
      check int "late callback cannot release another request's lease" 10 (Resources.pending_bytes resources);
      Resources.release lease;
      check int "explicit release returns the capacity" 0 (Resources.pending_bytes resources))))

module Writer = Masc.Http_reqd.Body_writer

let test_stream_overflow_resets_and_sibling_progresses () =
  let streams=Hashtbl.create 2 in
  let frame=String.make 8192 'e' in
  let handler id ~stream_sw reqd =
    let handle=Masc.Http_reqd.of_h2 ~stream_sw ~ledger:(Resources.current_exn ()) reqd in
    let writer=Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true handle
      (Httpun.Response.create `OK) in
    Hashtbl.add streams id writer;
    Writer.write_string writer frame;
    check bool "initial frame accepted" false (Writer.is_closed writer) in
  with_session ~capacity:131072 handler (fun resources session ->
    request session 1;
    until session (fun () -> Hashtbl.mem streams 1 && Hashtbl.mem session.responses 1);
    let writer=Hashtbl.find streams 1 in
    (* Models the shared publisher lock: no fiber switch or network wait while
       frames are offered. *)
    let mutex=Stdlib.Mutex.create () in
    Stdlib.Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) (fun () ->
      while not (Writer.is_closed writer) do Writer.write_string writer frame done);
    let outcome=ref None in
    Writer.flush writer (fun answer -> outcome:=Some answer);
    check bool "flush after the refusal answers closed at once" true (!outcome=Some `Closed);
    until session (fun () -> !(session.resets)>0 && Resources.pending_bytes resources=0);
    check int "overflow is a stream error" 1 !(session.errors);
    request session 2;
    until session (fun () -> Hashtbl.mem streams 2 && Hashtbl.mem session.responses 2);
    let healthy=Hashtbl.find streams 2 in
    Writer.write_string healthy "next";
    check bool "another stream can accept a frame" false (Writer.is_closed healthy);
    let response=Hashtbl.find session.responses 2 in
    until session (fun () ->
      read_once response;
      Buffer.length response.body=String.length frame+4);
    check string "healthy subscriber keeps frame order" (frame^"next") (Buffer.contents response.body);
    reset session 2;
    until session (fun () -> Resources.pending_bytes resources=0))

module Stream = Masc.Http_h2_stream

exception Handler_failed
exception First_report
exception Second_report

(* A fiber forked on the stream switch that waits for something h2 will not
   answer, like a producer whose flush never comes back. It keeps the cause
   its stream ended with. *)
let wait_for_stream_end ended () =
  try Eio.Fiber.await_cancel () with
  | Eio.Cancel.Cancelled (Stream.Stream_reset cause) as exn -> ended:=Some cause; raise exn

let test_handler_failure_after_headers_ends_the_scope () =
  let ended=ref None in
  let handler _ ~stream_sw reqd =
    ignore (H2.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd
      (H2.Response.create `OK) : H2.Body.Writer.t);
    Eio.Fiber.fork ~sw:stream_sw (wait_for_stream_end ended);
    raise Handler_failed in
  with_session ~capacity:1024 handler (fun _ session ->
    request session 1;
    until session (fun () ->
      Option.is_some !ended && !(session.resets)>0
      && Registry.active_streams session.registry=0);
    check bool "the waiting fiber ended with the handler's failure" true
      (match !ended with Some (Stream.Raised Handler_failed) -> true | _ -> false);
    check int "the client saw the stream reset" 1 !(session.errors))

(* With no response started, h2 answers the failure with its error handler's
   response. The scope stays until that answer is out: its END_STREAM, then
   the RST_STREAM h2 writes after an answer it opened for an error. *)
let test_handler_failure_before_headers_keeps_the_error_answer () =
  let ended=ref None in
  let handler _ ~stream_sw _ =
    Eio.Fiber.fork ~sw:stream_sw (wait_for_stream_end ended);
    raise Handler_failed in
  with_session ~capacity:1024 handler (fun _ session ->
    request session 1;
    until session (fun () ->
      Option.is_some !ended && Registry.active_streams session.registry=0);
    check bool "the error answer reached the client" true (Hashtbl.mem session.responses 1);
    check bool "the scope ended with the RST_STREAM h2 wrote after the answer" true
      (match !ended with Some Stream.Reset_by_us -> true | _ -> false))

let test_second_report_raises_nothing () =
  let second=ref None in
  let handler _ ~stream_sw reqd =
    H2.Reqd.report_exn reqd First_report;
    second:=Some (match Stream.reset ~stream_sw reqd (Stream.Raised Second_report) with
      | () -> Ok () | exception exn -> Error (Printexc.to_string exn)) in
  with_session ~capacity:1024 handler (fun _ session ->
    request session 1;
    until session (fun () ->
      Option.is_some !second && Registry.active_streams session.registry=0);
    check (option (result unit string)) "the second report raised nothing" (Some (Ok ())) !second)

module Http_reqd = Masc.Http_reqd

let reqd_of ~stream_sw h2_reqd =
  Http_reqd.of_h2 ~stream_sw ~ledger:(Resources.current_exn ()) h2_reqd

(* h2 answers an error reported before any response, and the stream then
   takes no response of its own. *)
let test_response_after_a_report_gets_a_closed_writer () =
  let ran=ref false and closed=ref None and ended=ref None in
  let handler _ ~stream_sw h2_reqd =
    ran:=true;
    let reqd=reqd_of ~stream_sw h2_reqd in
    Http_reqd.report_exn reqd First_report;
    let writer=Http_reqd.respond_with_streaming reqd (Httpun.Response.create `OK) in
    Http_reqd.Body_writer.write_string writer "dropped";
    closed:=Some (Http_reqd.Body_writer.is_closed writer);
    ended:=Some (match Http_reqd.Body_writer.stream_end writer with
      | Some signal -> Eio.Promise.is_resolved signal
      | None -> false) in
  with_session ~capacity:1024 handler (fun _ session ->
    request session 1;
    until session (fun () -> !ran && Registry.active_streams session.registry=0);
    check (option bool) "the response opened after the report got a closed writer"
      (Some true) !closed;
    check (option bool) "the closed writer reports the stream's end at once"
      (Some true) !ended)

let contains ~sub text =
  let n=String.length sub and m=String.length text in
  let rec at i = i+n <= m && (String.equal (String.sub text i n) sub || at (i+1)) in
  at 0

(* A string response after the report is refused without asking h2. Asked,
   h2 raises [Failure "... currently handling error"], and that reaches the
   log as a warning with a backtrace. *)
let test_string_response_after_a_report_is_refused_without_h2 () =
  let lines=ref [] in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun line -> lines:=line :: !lines));
  Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
    let accepted=ref None in
    let handler _ ~stream_sw h2_reqd =
      let reqd=reqd_of ~stream_sw h2_reqd in
      Http_reqd.report_exn reqd First_report;
      accepted:=Some (Http_reqd.try_respond_with_string reqd
        (Httpun.Response.create `OK) "late") in
    with_session ~capacity:1024 handler (fun _ session ->
      request session 1;
      until session (fun () -> Option.is_some !accepted && Hashtbl.mem session.responses 1);
      check bool "the late response was refused" true
        (!accepted = Some Http_reqd.Rejected_by_writer);
      check int "the client got the report's 500" 500
        (Hashtbl.find session.responses 1).status;
      check bool "h2 was not asked for a second response" false
        (List.exists (contains ~sub:"currently handling error") !lines)))

(* A fiber of the stream failed its switch before the handler answered. The
   handler's response then gets a closed writer, and the client sees the 500
   that the failure's report brings. Before, h2 opened the handler's 200 and
   the report cut it with RST_STREAM. *)
let test_response_after_the_scope_failed_gets_a_closed_writer () =
  let ran=ref false and closed=ref None in
  let handler _ ~stream_sw h2_reqd =
    ran:=true;
    let reqd=reqd_of ~stream_sw h2_reqd in
    Eio.Fiber.fork ~sw:stream_sw (fun () -> raise Handler_failed);
    let writer=Http_reqd.respond_with_streaming reqd (Httpun.Response.create `OK) in
    closed:=Some (Http_reqd.Body_writer.is_closed writer) in
  with_session ~capacity:1024 handler (fun _ session ->
    request session 1;
    until session (fun () ->
      !ran && Registry.active_streams session.registry=0 && Hashtbl.mem session.responses 1);
    check (option bool) "the response opened after the switch failed got a closed writer"
      (Some true) !closed;
    check int "the client saw the failure's 500" 500
      (Hashtbl.find session.responses 1).status)

let test_refused_write_ends_the_scope_with_the_refusal () =
  let ended=ref None in
  let handler _ ~stream_sw h2_reqd =
    let reqd=reqd_of ~stream_sw h2_reqd in
    let writer=Http_reqd.respond_with_streaming reqd (Httpun.Response.create `OK) in
    Eio.Fiber.fork ~sw:stream_sw (wait_for_stream_end ended);
    Http_reqd.Body_writer.write_string writer (String.make 64 'x') in
  with_session ~capacity:16 handler (fun _ session ->
    request session 1;
    until session (fun () ->
      Option.is_some !ended && Registry.active_streams session.registry=0);
    check bool "the scope ended with the ledger's refusal" true
      (match !ended with
       | Some (Stream.Out_of_capacity Resources.Capacity_exhausted) -> true
       | _ -> false);
    check int "the client saw the stream reset" 1 !(session.errors))

let () = run "H2 response resource boundary"
  ["transport",[
    test_case "whole response, slow consumption and reset reuse" `Quick test_whole_response_and_scope_release;
    test_case "overflow resets the stream and siblings progress" `Quick test_stream_overflow_resets_and_sibling_progresses;
    test_case "scope cleanup and late flush do not double release" `Quick test_scope_cleanup_and_late_flush_are_idempotent;
    test_case "a handler failure after the headers ends the stream scope" `Quick test_handler_failure_after_headers_ends_the_scope;
    test_case "a handler failure before the headers keeps h2's error answer" `Quick test_handler_failure_before_headers_keeps_the_error_answer;
    test_case "a second report on a reported stream raises nothing" `Quick test_second_report_raises_nothing;
    test_case "a response after a report gets a closed writer" `Quick test_response_after_a_report_gets_a_closed_writer;
    test_case "a string response after a report is refused without h2" `Quick test_string_response_after_a_report_is_refused_without_h2;
    test_case "a response after the scope failed gets a closed writer" `Quick test_response_after_the_scope_failed_gets_a_closed_writer;
    test_case "a refused write ends the scope with the refusal" `Quick test_refused_write_ends_the_scope_with_the_refusal]]
