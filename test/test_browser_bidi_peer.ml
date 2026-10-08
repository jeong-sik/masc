open Alcotest
module Peer = Masc.Browser_bidi_peer
let obj xs = `Assoc xs
let script_value json = obj ["type",`String "success";"result",obj ["type",`String "string";"value",`String (Yojson.Safe.to_string json)]]
let test_context_identity () =
  let contexts=ref ["a";"b"] in
  let command method_ _ = match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List (List.map (fun c->obj ["context",`String c;"url",`String "https://same.example/"]) !contexts)])
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://same.example/";"title",`String "same";"active",`Bool true]))
    | _ -> Error "unexpected test command" in
  let peer=Peer.create ~command () in
  let ids () = match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
    | Ok (`List rows) -> List.map (fun row->Yojson.Safe.Util.(row |> member "id" |> to_int)) rows
    | _ -> fail "tabs failed" in
  check (list int) "same URL does not merge opaque contexts" [1;2] (ids ());
  contexts:=["b"];check (list int) "remaining context keeps identity" [2] (ids ());
  contexts:=["b";"c"];check (list int) "closed context ID never reused" [2;3] (ids ())
(* A document-source read is the automation lane's document helper, which
   reports HTML it had to leave out instead of cutting it. *)
let test_document_source () =
  let ran=ref [] in
  let page=obj ["documentId",`String "observed";"url",`String "https://example.test/";
    "title",`String "fixture";"observedAt",`Float 1.;"html",`String "<html></html>";
    "htmlComplete",`Bool true;"htmlUnavailableReason",`Null] in
  let command method_ args = match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | "script.callFunction" ->
      ran:=Yojson.Safe.Util.(args |> member "functionDeclaration" |> to_string) :: !ran;
      Ok (script_value page)
    | other -> failf "unexpected document command: %s" other in
  let peer=Peer.create ~command () in
  match Peer.dispatch peer ~verb:Peer.Page_read (obj ["tabId",`Int 1;"includeHtml",`Bool true]) with
  | Ok data ->
    let open Yojson.Safe.Util in
    check int "the document names the tab it read" 1 (data |> member "tabId" |> to_int);
    check string "and carries the source" "<html></html>" (data |> member "html" |> to_string);
    (match !ran with
     | [declaration] ->
       check bool "one script, the shared document helper" true
         (String_util.contains_substring declaration Browser_lane.Document.runtime
          && String_util.contains_substring declaration "return browserDocument();")
     | _ -> fail "the document read ran other than one script")
  | Error (Peer.Before_effect detail) | Error (Peer.Outcome_unknown detail) ->
    failf "the peer refused a document-source read: %s" detail
(* The two reads that answer for the whole document, its source and its
   element inventory. *)
let whole_document_reads =
  ["the document source", Peer.Page_read, obj ["tabId",`Int 1;"includeHtml",`Bool true];
   "the element inventory", Peer.Page_elements, obj ["tabId",`Int 1]]
(* A document the parser has not finished is not answered for: neither its
   source nor an inventory that would call the part parsed so far complete. *)
let test_document_still_loading () =
  List.iter (fun (name, verb, args) ->
    let ran=ref [] in
    let command method_ params = match method_ with
      | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
      | "script.callFunction" ->
        ran:=Yojson.Safe.Util.(params |> member "functionDeclaration" |> to_string) :: !ran;
        Ok (script_value (obj ["documentLoading",`Bool true]))
      | other -> failf "unexpected document command: %s" other in
    let peer=Peer.create ~command () in
    (match Peer.dispatch peer ~verb args with
     | Error (Peer.Before_effect detail) ->
       check string (name ^ ": the refusal says to read again")
         "the document is still loading; read it again" detail
     | Error (Peer.Outcome_unknown detail) -> failf "%s was reported as an unknown outcome: %s" name detail
     | Ok _ -> failf "%s was answered for a document still loading" name);
    match !ran with
    | [declaration] ->
      check bool (name ^ ": the page is asked whether its parser is done") true
        (String_util.contains_substring declaration "document.readyState === 'loading'")
    | _ -> failf "%s ran other than one script" name) whole_document_reads
(* An answer too long for one socket message is refused in the page, which
   sends its length as a number. The peer reports that before any effect
   rather than receiving a message that would end the connection. *)
let test_answer_too_large_for_the_socket () =
  let measured = Peer.script_answer_limit_units + 1 in
  List.iter (fun (name, verb, args) ->
    let ran=ref [] in
    let command method_ params = match method_ with
      | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
      | "script.callFunction" ->
        ran:=Yojson.Safe.Util.(params |> member "functionDeclaration" |> to_string) :: !ran;
        Ok (obj ["type",`String "success";"result",obj ["type",`String "number";"value",`Int measured]])
      | other -> failf "unexpected command: %s" other in
    let peer=Peer.create ~command () in
    (match Peer.dispatch peer ~verb args with
     | Error (Peer.Before_effect detail) ->
       check string (name ^ ": the refusal names the size and the bound")
         (Printf.sprintf "page_answer_exceeds_bidi_reply_limit: %d UTF-16 units, at most %d cross this connection"
            measured Peer.script_answer_limit_units) detail
     | Error (Peer.Outcome_unknown detail) -> failf "%s was reported as an unknown outcome: %s" name detail
     | Ok _ -> failf "%s accepted a length as its answer" name);
    match !ran with
    | [declaration] ->
      check bool (name ^ ": the page measures its answer against the bound") true
        (String_util.contains_substring declaration
           (Printf.sprintf "answer.length > %d ? answer.length : answer" Peer.script_answer_limit_units))
    | _ -> failf "%s ran other than one script" name) whole_document_reads;
  check bool "three bytes a unit, plus the envelope, fit one message" true
    (Peer.script_answer_limit_units * 3 < Peer.reply_limit_bytes)
(* The inventory is the automation lane's own page script, run in the tab the
   request names and returned with that tab's ID. *)
let test_element_inventory () =
  let ran=ref [] in
  let inventory=obj ["url",`String "https://example.test/";"title",`String "fixture";
    "total",`Int 1;"truncated",`Bool false;
    "elements",`List [obj ["selector",`String "html:nth-of-type(1) > body:nth-of-type(1) > button:nth-of-type(1)";
      "tag",`String "button";"text",`String "Add reaction"]]] in
  let command method_ args = match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List
        [obj ["context",`String "other"]; obj ["context",`String "owned"]]])
    | "script.callFunction" ->
      let open Yojson.Safe.Util in
      ran:=(args |> member "target" |> member "context" |> to_string,
            args |> member "functionDeclaration" |> to_string) :: !ran;
      Ok (script_value inventory)
    | other -> failf "unexpected inventory command: %s" other in
  let peer=Peer.create ~command () in
  match Peer.dispatch peer ~verb:Peer.Page_elements (obj ["tabId",`Int 2]) with
  | Ok data ->
    let open Yojson.Safe.Util in
    check int "the inventory names the tab it read" 2 (data |> member "tabId" |> to_int);
    check int "and carries the page's elements" 1 (data |> member "elements" |> to_list |> List.length);
    (match !ran with
     | [context, declaration] ->
       check string "one script, in the requested tab" "owned" context;
       check bool "and it is the shared element script" true
         (String_util.contains_substring declaration Masc.Browser_page_script.elements)
     | _ -> fail "the inventory ran other than one script")
  | Error (Peer.Before_effect detail) | Error (Peer.Outcome_unknown detail) ->
    failf "the peer refused an element inventory: %s" detail
let test_pointer_validation () =
  let calls=ref [] in
  let command method_ _ =
    calls:=method_::!calls;
    match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | _ -> Error "unexpected effect dispatch" in
  let peer=Peer.create ~command () in
  let viewport=obj ["documentId",`String "observed";"width",`Int 800;"height",`Int 600;
    "scrollX",`Int 0;"scrollY",`Int 0] in
  let point=obj ["x",`Float 0.5;"y",`Float 0.5] in
  let base=["tabId",`Int 1;"expectedUrl",`String "https://example.test/";"viewport",viewport] in
  let rejected fields =
    calls:=[];
    (match Peer.dispatch peer ~verb:Peer.Page_interact (obj (base @ fields)) with
     | Error (Peer.Before_effect _) -> () | _ -> fail "malformed pointer admitted");
    check (list string) "parser rejects before any page or input command"
      ["browsingContext.getTree"] !calls in
  rejected ["action",`String "click_at";"point",obj ["x",`Int 1;"y",`Float 0.5]];
  rejected ["action",`String "scroll_at";"point",point;"x",`Int 0;"y",`String "120"];
  rejected ["action",`String "drag";"from",point;"to",point;"point",point]
let test_held_open_completion outcome () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock=Eio.Stdenv.clock env in
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port)->port|_->fail "TCP expected" in
      let eof,eof_u=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun ()->Eio.Switch.run (fun peer_sw ->
        let flow,_=Eio.Net.accept ~sw:peer_sw listener in
        let head=Ws_direct_eio.Driver.read_head ~clock flow in
        let key=match Ws_direct_eio.Handshake.request_key head with Ok key->key|Error e->fail e in
        Eio.Flow.copy_string (Ws_direct_eio.Handshake.server_response ~key) flow;
        (* Keep the peer open. No server-side close or close-frame response can
           rescue a client that waits for its own driver before cancelling it. *)
        let read=try ignore (Eio.Flow.single_read flow (Cstruct.create 1)); false
          with End_of_file->true in
        Eio.Promise.resolve eof_u read));
      Eio.Time.with_timeout_exn clock 2. (fun ()->
        let actual=Peer.with_connection ~env ~timeout:1.
          ~url:(Printf.sprintf "ws://127.0.0.1:%d/session" port) (fun ~ended:_ _->outcome) in
        check (result unit string) "callback result preserved" outcome actual;
        check bool "socket EOF without any extra protocol write" true (Eio.Promise.await eof))))
(* Firefox going away is told to whoever holds the connection, also when no
   command is in flight: a host waiting for work has to learn that the
   browser it serves is gone. *)
let test_a_closed_socket_ends_the_connection () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock=Eio.Stdenv.clock env in
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port)->port|_->fail "TCP expected" in
      let close,close_u=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun ()->Eio.Switch.run (fun peer_sw ->
        let flow,_=Eio.Net.accept ~sw:peer_sw listener in
        let head=Ws_direct_eio.Driver.read_head ~clock flow in
        let key=match Ws_direct_eio.Handshake.request_key head with Ok key->key|Error e->fail e in
        Eio.Flow.copy_string (Ws_direct_eio.Handshake.server_response ~key) flow;
        Eio.Promise.await close));
      Eio.Time.with_timeout_exn clock 2. (fun ()->
        let actual=Peer.with_connection ~env ~timeout:1.
          ~url:(Printf.sprintf "ws://127.0.0.1:%d/session" port)
          (fun ~ended _->
            check bool "attached and idle: not ended" true (Eio.Promise.peek ended=None);
            Eio.Promise.resolve close_u ();
            Error ("ended: " ^ Eio.Promise.await ended)) in
        check (result unit string) "the holder is told why" (Error "ended: BiDi EOF") actual)))
(* A scripted Firefox for the session's lifetime: one accepted WebSocket whose
   client messages the case reads and answers one at a time. *)
let read_client_message flow =
  let exactly length =
    let buffer=Cstruct.create length in
    Eio.Flow.read_exact flow buffer; Cstruct.to_string buffer in
  let head=exactly 2 in
  let length=match Char.code head.[1] land 0x7f with
    | 126 -> String.get_uint16_be (exactly 2) 0
    | 127 -> Int64.to_int (String.get_int64_be (exactly 8) 0)
    | short -> short in
  let mask=exactly 4 in
  let payload=exactly length in
  Yojson.Safe.from_string (String.mapi (fun index byte ->
    Char.chr (Char.code byte lxor Char.code mask.[index land 3])) payload)
let send_server_message flow json =
  let payload=Yojson.Safe.to_string json in
  let length=String.length payload in
  let head=
    if length < 126 then Printf.sprintf "\x81%c" (Char.chr length)
    else if length < 65536 then Printf.sprintf "\x81\x7e%c%c" (Char.chr (length lsr 8)) (Char.chr (length land 0xff))
    else fail "scripted reply too long for a 16-bit frame" in
  Eio.Flow.copy_string (head ^ payload) flow
let reply_to request result =
  obj ["type",`String "success";"id",Yojson.Safe.Util.member "id" request;"result",result]
let with_scripted_firefox script use =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock=Eio.Stdenv.clock env in
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port)->port|_->fail "TCP expected" in
      Eio.Fiber.fork ~sw (fun ()->Eio.Switch.run (fun peer_sw ->
        let flow,_=Eio.Net.accept ~sw:peer_sw listener in
        let head=Ws_direct_eio.Driver.read_head ~clock flow in
        let key=match Ws_direct_eio.Handshake.request_key head with Ok key->key|Error e->fail e in
        Eio.Flow.copy_string (Ws_direct_eio.Handshake.server_response ~key) flow;
        script flow));
      Eio.Time.with_timeout_exn clock 5. (fun ()->
        Peer.with_connection ~env ~timeout:0.2
          ~url:(Printf.sprintf "ws://127.0.0.1:%d/session" port) use)))
let session_created request =
  reply_to request (obj ["sessionId",`String "scripted";"capabilities",
    obj ["browserName",`String "firefox";"browserVersion",`String "157.0-scripted"]])
let method_of request = Yojson.Safe.Util.(request |> member "method" |> to_string)
(* The session a connection created is ended over that connection, also after
   this side stopped trusting it for page commands: a page whose command got
   no reply is not a browser that is gone, and a session left in Firefox
   refuses every later connection. *)
let test_the_session_is_ended_after_a_command_got_no_reply () =
  let seen=ref [] in
  let script flow =
    let created=read_client_message flow in
    seen:=method_of created :: !seen;
    send_server_message flow (session_created created);
    let unanswered=read_client_message flow in
    seen:=method_of unanswered :: !seen;
    let ending=read_client_message flow in
    seen:=method_of ending :: !seen;
    send_server_message flow (reply_to ending (obj [])) in
  let outcome=with_scripted_firefox script (fun ~ended peer ->
    check (result unit string) "nothing to end before a session exists" (Ok ()) (Peer.end_session peer);
    check bool "and nothing was sent for it" true (!seen=[]);
    (match Peer.metadata peer with
     | Ok version -> check string "the session was created" "157.0-scripted" version
     | Error detail -> fail detail);
    (match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
     | Error (Peer.Before_effect detail) ->
       check string "a command that got no reply ends the connection for page commands"
         "BiDi transport deadline exceeded" detail
     | Error (Peer.Outcome_unknown detail) -> fail detail
     | Ok _ -> fail "an unanswered command produced an answer");
    check (option string) "its holder is told" (Some "BiDi transport deadline exceeded")
      (Eio.Promise.peek ended);
    check (result unit string) "the session is still ended, over the open socket" (Ok ())
      (Peer.end_session peer);
    check (result unit string) "once" (Ok ()) (Peer.end_session peer);
    Ok ()) in
  check (result unit string) "the connection finished" (Ok ()) outcome;
  check (list string) "what Firefox was sent, in order"
    ["session.new";"browsingContext.getTree";"session.end"] (List.rev !seen)
(* A socket that is gone carries no session.end, and one Firefox does not
   answer is not waited on past its window. Each is an error the holder can
   tell the operator. *)
let test_a_session_that_cannot_be_ended_is_an_error () =
  let closed_under_it=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow)))
    (fun ~ended peer ->
      (match Peer.metadata peer with Ok _ -> () | Error detail -> fail detail);
      (* The script returned after its one answer, which closed the socket. *)
      Error (Eio.Promise.await ended ^ " / " ^ (match Peer.end_session peer with
        | Ok () -> "ended" | Error detail -> detail))) in
  check (result unit string) "a closed socket" (Error "BiDi EOF / BiDi EOF") closed_under_it;
  let unanswered=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow));
      ignore (read_client_message flow : Yojson.Safe.t);
      (* Held open without an answer until the client is done. *)
      try ignore (Eio.Flow.single_read flow (Cstruct.create 1) : int) with End_of_file -> ())
    (fun ~ended:_ peer ->
      (match Peer.metadata peer with Ok _ -> () | Error detail -> fail detail);
      match Peer.end_session peer with
      | Ok () -> Ok ()
      | Error detail -> Error detail) in
  check (result unit string) "no answer in the window" (Error "no answer to session.end in time") unanswered
(* A peer that refuses the WebSocket upgrade. ws-direct raises [Failure] for
   the refused handshake; the connection returns it as its error rather than
   letting it out of [with_connection], where the native host would end on an
   uncaught exception. *)
let test_refused_upgrade_is_the_connections_error () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock=Eio.Stdenv.clock env in
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port)->port|_->fail "TCP expected" in
      Eio.Fiber.fork ~sw (fun ()->Eio.Switch.run (fun peer_sw ->
        let flow,_=Eio.Net.accept ~sw:peer_sw listener in
        ignore (Ws_direct_eio.Driver.read_head ~clock flow : string);
        Eio.Flow.copy_string "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n" flow));
      let used=ref false in
      match
        Peer.with_connection ~env ~timeout:1.
          ~url:(Printf.sprintf "ws://127.0.0.1:%d/session" port)
          (fun ~ended:_ _->used:=true;Ok ())
      with
      | Error _->check bool "no peer was handed to the callback" false !used
      | Ok ()->fail "a refused upgrade produced a connection"
      | exception Failure detail->failf "the refused upgrade escaped as an exception: %s" detail))
let test_hover_without_click () =
  Eio_main.run (fun _ ->
    let hovered = ref false in
    let viewport = obj ["documentId",`String "fixture";"width",`Int 800;
      "height",`Int 600;"scrollX",`Int 0;"scrollY",`Int 0] in
    let point = obj ["x",`Float 0.5;"y",`Float 0.5] in
    let command method_ args = match method_ with
      | "browsingContext.getTree" -> Ok (obj ["contexts",`List
          [obj ["context",`String "other"]; obj ["context",`String "owned"]]])
      | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";
          "title",`String "hover fixture";"hovered",`Bool !hovered]))
      | "input.performActions" ->
        let open Yojson.Safe.Util in
        check string "selected context receives the input" "owned"
          (args |> member "context" |> to_string);
        let sources = args |> member "actions" |> to_list in
        let actions = List.hd sources |> member "actions" |> to_list in
        check int "one input, no pressed buttons" 1 (List.length actions);
        let move = List.hd actions in
        check string "trusted pointer movement" "pointerMove" (move |> member "type" |> to_string);
        check int "observed horizontal position" 400 (move |> member "x" |> to_int);
        check int "observed vertical position" 300 (move |> member "y" |> to_int);
        hovered := true; Ok `Null
      | _ -> fail ("unexpected hover command: " ^ method_) in
    let peer = Peer.create ~command () in
    check bool "fixture starts unhovered" false !hovered;
    match Peer.dispatch peer ~verb:Peer.Page_interact (obj ["tabId",`Int 2;
      "action",`String "hover_at";"expectedUrl",`String "https://example.test/";
      "point",point;"viewport",viewport]) with
    | Ok receipt ->
      check bool "input reached fixture" true !hovered;
      check int "receipt identifies the selected tab" 2 Yojson.Safe.Util.(receipt |> member "tabId" |> to_int);
      check string "hover receipt" "hover_at" Yojson.Safe.Util.(receipt |> member "action" |> to_string)
    | Error _ -> fail "hover rejected")
(* The lane's table (Browser_lane.live_transport_serves) and this peer are two
   statements of what a BiDi connection serves. One verb per capability goes
   through the peer, encoded as the lane puts it on the wire, against a
   browser that answers every protocol command. The peer completes exactly
   the work the table says BiDi serves and refuses the rest before it sends a
   script or an input. *)
let test_peer_serves_what_the_lane_table_says () =
  Eio_main.run (fun _ ->
    let module Lane = Browser_lane in
    let viewport : Lane.Pointer.viewport =
      {document_id="observed"; width=800.; height=600.; scroll_x=0.; scroll_y=0.} in
    let point : Lane.Pointer.point = {x=0.5;y=0.5} in
    let interact action = Lane.Page_interact {tab_id=1; expected_url=Some "https://example.test/"; action} in
    let verb_asking_for : Lane.live_capability -> Lane.verb = Lane.(function
      | Tab_listing -> Tabs_list
      | Text_read -> Page_read {tab_id=Some 1; max_chars=None}
      | Document_source -> Page_document {tab_id=1}
      | Element_inventory -> Page_elements {tab_id=Some 1}
      | Viewport_capture -> Page_capture {tab_id=1}
      | Scene_read -> Page_scene {tab_id=1; max_chars=1000; view=Content; scope=None}
      | Dom_interaction -> interact (Click "#button")
      | Point_click -> interact (Click_at {point;viewport})
      | Point_scroll -> interact (Scroll_at {point;viewport;x=0;y=120})
      | Trusted_hover -> interact (Hover_at {point;viewport})
      | Trusted_drag -> interact (Drag {from=point;to_={x=0.75;y=0.5};viewport})
      | Tab_activation -> interact Activate_tab) in
    (* The six names the native host forwards (Browser_host.decode_poll). *)
    let peer_verb = function
      | "tabs.list" -> Peer.Tabs_list | "page.read" -> Peer.Page_read | "page.scene" -> Peer.Page_scene
      | "page.elements" -> Peer.Page_elements | "page.capture" -> Peer.Page_capture
      | "page.interact" -> Peer.Page_interact
      | other -> failf "the lane put a verb on the wire that the host does not forward: %s" other in
    let calls = ref [] in
    let command method_ _ =
      calls := method_ :: !calls;
      match method_ with
      | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
      | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";
          "title",`String "fixture";"active",`Bool true]))
      | "browsingContext.captureScreenshot" -> Ok (obj ["data",`String "png"])
      | "input.performActions" | "input.releaseActions" -> Ok `Null
      | other -> failf "unexpected protocol command: %s" other in
    let peer = Peer.create ~command () in
    List.iter (fun capability ->
      let name = Lane.live_capability_to_wire capability in
      let asked = verb_asking_for capability in
      check bool (name ^ " is what its verb asks for") true (Lane.live_capability asked = Some capability);
      let wire = Lane.verb_json asked in
      let verb = peer_verb Yojson.Safe.Util.(wire |> member "verb" |> to_string) in
      (* A refusal below has to be the peer's own answer for this work, not
         its parser turning away a malformed request. *)
      (match verb, Yojson.Safe.Util.member "args" wire with
       | Peer.Page_interact, `Assoc fields ->
         check bool (name ^ " is a well-formed interaction") true
           (Result.is_ok (Masc.Browser_interaction.parse
              (obj (("lane",`String Lane.Lane_name.(to_wire Live)) :: fields))))
       | _ -> ());
      calls := [];
      let served = Lane.live_transport_serves Lane.Webdriver_bidi capability in
      match Peer.dispatch peer ~verb (Yojson.Safe.Util.member "args" wire), served with
      | Ok _, true -> ()
      | Error (Peer.Before_effect _), false ->
        check bool (name ^ " is refused before any script or input") true
          (List.for_all (String.equal "browsingContext.getTree") !calls)
      | Ok _, false -> failf "the peer served %s, which the lane table says BiDi does not" name
      | Error (Peer.Before_effect detail), true | Error (Peer.Outcome_unknown detail), _ ->
        failf "the peer did not serve %s (%s), which the lane table says BiDi does" name detail)
      Lane.all_of_live_capability)
let () = run "BiDi live peer" ["identity",[test_case "opaque contexts" `Quick test_context_identity];
  "lifetime",[test_case "normal callback closes held socket" `Quick (test_held_open_completion (Ok ()) );
    test_case "error callback closes held socket" `Quick (test_held_open_completion (Error "owned failure"));
    test_case "a refused upgrade is the connection's error" `Quick test_refused_upgrade_is_the_connections_error;
    test_case "a closed socket ends the connection for its holder" `Quick test_a_closed_socket_ends_the_connection;
    test_case "the session is ended after a command got no reply" `Quick
      test_the_session_is_ended_after_a_command_got_no_reply;
    test_case "a session that cannot be ended is an error" `Quick test_a_session_that_cannot_be_ended_is_an_error];
  "effect",[test_case "hover moves without clicking" `Quick test_hover_without_click; test_case "element inventory is the shared page script" `Quick test_element_inventory;
    test_case "document source is the shared document helper" `Quick test_document_source;
    test_case "a document still loading is not answered for" `Quick test_document_still_loading;
    test_case "an answer too large for the socket is refused in the page" `Quick test_answer_too_large_for_the_socket; test_case "parsed pointer boundary" `Quick test_pointer_validation;
    test_case "the peer serves what the lane table says" `Quick test_peer_serves_what_the_lane_table_says]]
