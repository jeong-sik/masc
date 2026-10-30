open Alcotest
module Resources = Server_h2_response_resources
module Registry = Server_h2_stream_registry

type lane = {mutable pending:string}
type response = {reader:H2.Body.Reader.t; mutable waiting:bool;
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
      if kind=3 || ((kind=0 || kind=1) && flags land 1 <> 0) then (
        if kind=3 then incr session.resets;
        Registry.response_ended session.registry
          ~stream_id:(Int32.to_int (String.get_int32_be bytes (off+5))));
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
                (fun () -> handler id reqd))) in
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
    ~response_handler:(fun _ reader -> Hashtbl.add session.responses id
      {reader;waiting=false;ended=false;body=Buffer.create 16}) in
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
  let handler _ reqd =
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

let test_stream_overflow_is_explicit_and_other_stream_progresses () =
  let streams=Hashtbl.create 2 in
  let frame=String.make 8192 'e' in
  let handler id reqd =
    let writer=H2.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd
      (H2.Response.create `OK) in
    let stream=Resources.stream writer in
    Hashtbl.add streams id stream;
    check bool "initial frame enqueued" true (Resources.offer stream frame);
    Resources.run stream in
  with_session ~capacity:131072 handler (fun resources session ->
    request session 1;
    until session (fun () -> Hashtbl.mem streams 1 && Hashtbl.mem session.responses 1);
    let stream=Hashtbl.find streams 1 in
    (* Models the actual shared publisher lock: no fiber switch/network wait
       is allowed while offering notifications. *)
    let mutex=Stdlib.Mutex.create () in
    Stdlib.Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) (fun () ->
      while Resources.offer stream frame do () done);
    check bool "overflow closes the producer" true (Resources.is_closed stream);
    until session (fun () -> !(session.resets)>0 && Resources.pending_bytes resources=0);
    check int "overflow is a stream error" 1 !(session.errors);
    request session 2;
    until session (fun () -> Hashtbl.mem streams 2 && Hashtbl.mem session.responses 2);
    let healthy=Hashtbl.find streams 2 in
    check bool "another stream can accept an event" true (Resources.offer healthy "next");
    let response=Hashtbl.find session.responses 2 in
    until session (fun () ->
      read_once response;
      Buffer.length response.body=String.length frame+4);
    check string "healthy subscriber keeps event order" (frame^"next") (Buffer.contents response.body);
    reset session 2;
    until session (fun () -> Resources.pending_bytes resources=0))

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

let () = run "H2 response resource boundary"
  ["transport",[
    test_case "whole response, slow consumption and reset reuse" `Quick test_whole_response_and_scope_release;
    test_case "subscription overflow resets without blocking siblings" `Quick test_stream_overflow_is_explicit_and_other_stream_progresses;
    test_case "scope cleanup and late flush do not double release" `Quick test_scope_cleanup_and_late_flush_are_idempotent]]
