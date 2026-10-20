open Alcotest

module Helpers = Server_h2_gateway_helpers
module Subs = Mcp_subscriptions
module Protocol = Mcp_transport_protocol

type mode = H2_only | Auto
type client = {
  connection : H2_eio.Client.t;
  authorization : string;
  write_raw : string -> unit;
  close : unit -> unit;
  mutable next_id : int;
}
type response = {
  response : H2.Response.t;
  reader : H2.Body.Reader.t;
  bytes : Buffer.t;
}
type exchange = {
  id : int;
  received : (response, unit) result Eio.Promise.t;
  failed : unit Eio.Promise.t;
}

let rec remove_tree path =
  match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | {Unix.st_kind=(Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK
      | Unix.S_FIFO | Unix.S_SOCK);_} -> Unix.unlink path

let with_listener mode ~capacity make_handler run =
  Masc_test_deps.with_process_env "MASC_H2_MAX_PENDING_RESPONSE_BYTES"
    (Some (string_of_int capacity)) @@ fun () ->
  let base_path=Filename.temp_file "masc-h2-listener-resources" "" in
  Sys.remove base_path; Unix.mkdir base_path 0o700;
  let previous=Server_auth.For_testing.snapshot_server_state () in
  let previous_fs=Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous;
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    remove_tree base_path) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    (* Only a fixture deadlock bound; no production request deadline. *)
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
      let state=Masc.Mcp_server.For_testing.create_state ~base_path in
      ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config state) ~agent_name:None);
      Auth.save_auth_config base_path
        {Masc_domain.default_auth_config with enabled=true;require_token=true};
      let token=match Auth.create_token base_path ~agent_name:"resource-fixture" ~role:Masc_domain.Admin with
        | Ok (token,_) -> token | Error _ -> fail "fixture authentication could not be created" in
      Server_auth.For_testing.restore_server_state (Some state);
      let socket=Eio.Net.listen ~sw ~backlog:8 (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let addr=Eio.Net.listening_addr socket in
      let port=match addr with `Tcp (_,port) -> port | `Unix _ -> fail "expected TCP listener" in
      let trust_policy=match Server_request_authority.make_trust_policy
        ~bind_host:"localhost" ~bind_port:port ~explicit_base_url:None with
        | Ok policy -> policy
        | Error error -> fail (Server_request_authority.trust_policy_error_to_string error) in
      let gateway=Server_h2_gateway.make_request_handler ~trust_policy ~sw
        ~clock:(Eio.Stdenv.clock env) ~server_start_time:0. in
      let handler=make_handler ~gateway in
      let clients=ref [] in
      let connect ?(window=65535l) () =
        let flow=Eio.Net.connect ~sw (Eio.Stdenv.net env) addr in
        let closing=ref false in
        let connection=H2_eio.Client.create_connection ~sw
          ~config:{H2.Config.default with initial_window_size=window}
          ~error_handler:(fun _ -> if not !closing then fail "unexpected H2 connection failure") flow in
        let close ()=if not !closing then (
          closing:=true; Eio.Flow.shutdown flow `All) in
        let client={connection;authorization="Bearer "^token;
          write_raw=(fun bytes -> Eio.Flow.copy_string bytes flow);
          close;next_id=1} in
        clients:=client::!clients; client in
      Eio.Fiber.first
        (fun () ->
          let h2_error_handler=Server_h2_gateway.make_error_handler () in
          match mode with
          | H2_only -> Server_bootstrap_http.serve_h2 ~sw ~clock:(Eio.Stdenv.clock env)
            ~socket ~addr_label:"resource-fixture" ~h2_request_handler:handler ~h2_error_handler
          | Auto -> Server_bootstrap_http.serve_auto ~sw ~clock:(Eio.Stdenv.clock env)
            ~socket ~addr_label:"resource-fixture" ~h2_request_handler:handler ~h2_error_handler
            ~request_handler:(fun _ _ -> fail "H2 preface was routed as HTTP/1"))
        (fun () -> Fun.protect ~finally:(fun () -> List.iter (fun client -> client.close ()) !clients)
          (fun () -> run ~connect ~port))))

let request ?(body="") ?(headers=[]) ?(on_error=fun _ -> ()) client ~port path =
  let received,receive=Eio.Promise.create () in
  let failed,fail_stream=Eio.Promise.create () in
  let id=client.next_id in client.next_id<-id+2;
  let writer=H2_eio.Client.request client.connection ~flush_headers_immediately:true
    (H2.Request.create ~scheme:"http" (if body="" then `GET else `POST) path
      ~headers:(H2.Headers.of_list ((":authority","localhost:"^string_of_int port)
        ::("authorization",client.authorization)::headers)))
    ~error_handler:(fun error ->
      on_error error;
      if not (Eio.Promise.is_resolved received) then Eio.Promise.resolve receive (Error ());
      if not (Eio.Promise.is_resolved failed) then Eio.Promise.resolve fail_stream ())
    ~response_handler:(fun response reader ->
      Eio.Promise.resolve receive (Ok {response;reader;bytes=Buffer.create 256})) in
  if body="" then H2.Body.Writer.close writer else (
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.flush writer (function `Written | `Closed -> H2.Body.Writer.close writer));
  {id;received;failed}

let response exchange = match Eio.Promise.await exchange.received with
  | Ok response -> response | Error () -> fail "stream failed before response headers"

let read_chunk response =
  let chunk,resolve=Eio.Promise.create () in
  H2.Body.Reader.schedule_read response.reader
    ~on_eof:(fun () -> Eio.Promise.resolve resolve false)
    ~on_read:(fun data ~off ~len ->
      Buffer.add_string response.bytes (Bigstringaf.substring data ~off ~len);
      Eio.Promise.resolve resolve true);
  Eio.Promise.await chunk

let rec read_complete response =
  if read_chunk response then read_complete response
  else (
    check bool "response completed normally" true (H2.Body.Reader.completion response.reader=Complete);
    Buffer.contents response.bytes)

let rec read_through response count =
  if Buffer.length response.bytes<count then (
    if not (read_chunk response) then fail "SSE ended before the complete expected frame";
    read_through response count)

let ping client = match Eio.Promise.await (H2_eio.Client.ping client.connection) with
  | Ok () -> () | Error `EOF -> fail "sibling connection unexpectedly closed"

let reset client exchange response =
  H2.Body.Reader.discard response.reader;
  let frame=Bytes.of_string "\000\000\004\003\000\000\000\000\000\000\000\000\008" in
  Bytes.set_int32_be frame 5 (Int32.of_int exchange.id);
  client.write_raw (Bytes.to_string frame);
  ping client

(* Two stream windows, so an unread response cannot flush its whole body. *)
let payload=String.init 131070 (fun i -> Char.chr (97+i mod 26))

let test_listener_shares_capacity mode () =
  let released,release=Eio.Promise.create () in
  let make_handler ~gateway:_ ~request_sw _ reqd =
    match (H2.Reqd.request reqd).target with
    | "/held" ->
      Eio.Switch.on_release request_sw (fun () -> Eio.Promise.resolve release ());
      Helpers.h2_respond_json ~compress:false reqd payload
    | "/large" -> Helpers.h2_respond_json ~compress:false reqd payload
    | _ -> fail "unexpected fixture route" in
  with_listener mode ~capacity:(String.length payload) make_handler (fun ~connect ~port ->
    let blocked=connect () and sibling=connect () in
    let held=request blocked ~port "/held" in
    let held_response=response held in
    check int "first connection admitted" 200 (H2.Status.to_code held_response.response.status);
    ping blocked;
    let refused=response (request sibling ~port "/large") in
    check int "second connection shares the exhausted listener capacity" 503
      (H2.Status.to_code refused.response.status);
    check (option string) "capacity refusal cannot be cached" (Some "no-store")
      (H2.Headers.get refused.response.headers "cache-control");
    check string "capacity refusal has no retained payload" "" (read_complete refused);
    reset blocked held held_response;
    Eio.Promise.await released;
    let accepted=response (request sibling ~port "/large") in
    check int "reset returns capacity to the other connection" 200
      (H2.Status.to_code accepted.response.status);
    check string "slow consumption preserves the complete accepted body" payload (read_complete accepted))

let test_listener_stream_admission mode () =
  (* An explicit test configuration, not a new product default. Two held
     streams expose both over-admission and refusal stealing an owned slot. *)
  Masc_test_deps.with_process_env "MASC_H2_MAX_CONCURRENT_STREAMS" (Some "2") @@ fun () ->
  let admitted=ref [] and released=ref [] in
  let rec await_release target =
    if not (List.mem target !released) then (Eio.Fiber.yield ();await_release target) in
  let make_handler ~gateway:_ ~request_sw _ reqd =
    let target=(H2.Reqd.request reqd).target in
    admitted:=target::!admitted;
    Eio.Switch.on_release request_sw (fun () -> released:=target::!released);
    ignore (H2.Reqd.respond_with_streaming ~flush_headers_immediately:true reqd
      (H2.Response.create `OK)) in
  with_listener mode ~capacity:65536 make_handler (fun ~connect ~port ->
    let client=connect () in
    let first=request client ~port "/first" in
    let first_response=response first in
    let second=request client ~port "/second" in
    let second_response=response second in
    ping client;
    let refuse path =
      let error_seen=ref None in
      let exchange=request ~on_error:(fun error -> error_seen:=Some error)
        client ~port path in
      (match Eio.Promise.await exchange.received with
       | Error () -> ()
       | Ok _ -> fail "excess stream reached the application handler");
      (match !error_seen with
       | Some (`Protocol_error ((H2.Error_code.ProtocolError | H2.Error_code.RefusedStream),_)) -> ()
       | Some (`Protocol_error _ | `Malformed_response _ | `Invalid_response_body_length _ | `Exn _)
       | None -> fail "excess stream did not receive an explicit H2 admission refusal");
      ping client in
    refuse "/excess-one";
    refuse "/excess-two";
    check (list string) "repeated refusals do not create spare slots"
      ["/second";"/first"] !admitted;
    check (list string) "refusal does not release an admitted request" [] !released;
    reset client first first_response;
    await_release "/first";
    check (list string) "reset releases exactly the first request scope" ["/first"] !released;
    let replacement=request client ~port "/replacement" in
    let replacement_response=response replacement in
    check int "returned slot admits a replacement" 200
      (H2.Status.to_code replacement_response.response.status);
    refuse "/excess-after-reuse";
    check (list string) "only the one returned slot can be reused"
      ["/replacement";"/second";"/first"] !admitted;
    reset client second second_response;
    reset client replacement replacement_response;
    await_release "/second";
    await_release "/replacement";
    check (list string) "all admitted request scopes are released"
      ["/first";"/replacement";"/second"] (List.sort String.compare !released);
    let fresh=request client ~port "/after-all-resets" in
    let fresh_response=response fresh in
    check int "connection admits work after all slots were released" 200
      (H2.Status.to_code fresh_response.response.status);
    reset client fresh fresh_response;
    await_release "/after-all-resets")

let sse json=Printf.sprintf "data: %s\n\n" (Yojson.Safe.to_string json)
let tools_notifications=`Assoc ["toolsListChanged",`Bool true]
let resource_uri="masc://status"
let resource_notifications=`Assoc ["resourceSubscriptions",`List [`String resource_uri]]
let filter notifications=Protocol.subscription_filter_of_params
  (Some (`Assoc ["notifications",notifications])) |> Subs.honoured_filter

(* The stateful protocol revision scopes a subscription to a session: the
   client initializes first and presents the session id it was given. *)
let initialize_session client ~port =
  let body=Yojson.Safe.to_string (`Assoc ["jsonrpc",`String "2.0";"id",`String "initialize";
    "method",`String "initialize";
    "params",`Assoc ["protocolVersion",`String Protocol.default_protocol_version;
      "capabilities",`Assoc [];
      "clientInfo",`Assoc ["name",`String "resource-fixture";"version",`String "0"]]]) in
  let exchange=request client ~port "/mcp" ~body ~headers:[
    "accept","application/json, text/event-stream";"content-type","application/json";
    "mcp-protocol-version",Protocol.default_protocol_version] in
  let init_response=response exchange in
  check int "initialize opens a session" 200 (H2.Status.to_code init_response.response.status);
  let session_id=match H2.Headers.get init_response.response.headers "mcp-session-id" with
    | Some value -> value
    | None -> fail "initialize returned no mcp-session-id header" in
  ignore (read_complete init_response);
  session_id

let subscribe ?(notifications=tools_notifications) ~session_id client ~port id =
  let params=`Assoc [
    "notifications",notifications;
    "_meta",`Assoc [Protocol.protocol_version_meta_key,`String Protocol.default_protocol_version;
      Protocol.client_capabilities_meta_key,`Assoc []]] in
  let body=Yojson.Safe.to_string (`Assoc ["jsonrpc",`String "2.0";"id",id;
    "method",`String "subscriptions/listen";"params",params]) in
  request client ~port "/mcp" ~body ~headers:[
    "accept","application/json, text/event-stream";"content-type","application/json";
    "mcp-protocol-version",Protocol.default_protocol_version;"mcp-method","subscriptions/listen";
    "mcp-session-id",session_id]

let rec until predicate = if not (predicate ()) then (Eio.Fiber.yield ();until predicate)

let test_actual_subscription_route () =
  let capacity=65536 in
  let make_handler ~gateway = gateway in
  with_listener H2_only ~capacity make_handler (fun ~connect ~port ->
    Subs.reset_for_test ();
    Fun.protect ~finally:Subs.reset_for_test (fun () ->
      let blocked=connect ~window:1024l () and healthy=connect ~window:1024l () in
      let blocked_id=`String "blocked" in
      let blocked_session=initialize_session blocked ~port in
      let held=subscribe ~session_id:blocked_session blocked ~port blocked_id in
      let held_response=response held in
      check int "actual MCP route opens a subscription" 200
        (H2.Status.to_code held_response.response.status);
      check (option string) "actual route is SSE" (Some "text/event-stream")
        (H2.Headers.get held_response.response.headers "content-type");
      until (fun () -> Subs.count ()=1);
      (* A healthy subscription already shares this registry and publisher
         mutex. Its distinct filter lets the unread tools subscriber fill
         capacity without offering that same burst to the healthy stream. *)
      let healthy_id=`String "healthy" in
      let healthy_session=initialize_session healthy ~port in
      let live=subscribe ~session_id:healthy_session ~notifications:resource_notifications healthy ~port healthy_id in
      let live_response=response live in
      check int "healthy sibling was admitted before overflow" 200
        (H2.Status.to_code live_response.response.status);
      until (fun () -> Subs.count ()=2);
      let ack=sse (Subs.acknowledgement ~subscription_id:healthy_id (filter resource_notifications)) in
      read_through live_response (String.length ack);
      let note=Protocol.jsonrpc_notification "notifications/tools/list_changed"
        ~params:(`Assoc ["payload",`String (String.make 16384 'e')]) in
      let frame=sse (Protocol.tag_notification_with_subscription ~subscription_id:blocked_id note) in
      Subs.notify_tools_list_changed note;
      (* Let the actual route's drain enter its flow-controlled flush. No
         Reader callback returns the peer's 1024-byte stream credit yet. *)
      ping blocked;
      (* This count follows the declared byte capacity, not a runtime cap.
         Every publish uses the real registry and its shared publisher lock. *)
      for _=1 to capacity / String.length frame + 1 do
        Subs.notify_tools_list_changed note
      done;
      check int "overflow retires only the blocked subscriber without waiting on the socket" 1 (Subs.count ());
      Eio.Promise.await held.failed;
      check bool "overflow is not clean SSE EOF" true
        (H2.Body.Reader.completion held_response.reader<>Complete);
      ping blocked;
      let expected=ref ack in
      List.iter (fun sequence ->
        let note=Protocol.jsonrpc_notification "notifications/resources/updated"
          ~params:(`Assoc ["uri",`String resource_uri;"sequence",`Int sequence;
            "payload",`String (String.make 16384 'h')]) in
        Subs.notify_resource_updated ~uri:resource_uri note;
        expected:= !expected ^ sse (Protocol.tag_notification_with_subscription ~subscription_id:healthy_id note);
        read_through live_response (String.length !expected)) [1;2];
      check string "slow reader gets complete frames in publication order" !expected
        (Buffer.contents live_response.bytes);
      reset healthy live live_response;
      until (fun () -> Subs.count ()=0);
      ping blocked))

let ()=run "H2 listener response resources" ["actual listeners and MCP",[
  test_case "H2 listener shares capacity across TCP connections" `Quick (test_listener_shares_capacity H2_only);
  test_case "auto listener shares capacity across detected H2 connections" `Quick (test_listener_shares_capacity Auto);
  test_case "H2 listener refuses excess streams and reuses only released slots" `Quick (test_listener_stream_admission H2_only);
  test_case "auto listener refuses excess streams and reuses only released slots" `Quick (test_listener_stream_admission Auto);
  test_case "actual subscription overflow and slow sibling delivery" `Quick test_actual_subscription_route]]
