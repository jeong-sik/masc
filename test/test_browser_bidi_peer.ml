open Alcotest
module Peer = Masc.Browser_bidi_peer
(* The session request's failure as the sentence the host logs. Which kind of
   failure it was is asked where a case is about that. *)
let metadata peer = Result.map_error Peer.session_failure_message (Peer.metadata peer)
let obj xs = `Assoc xs
(* [check bool] on a substring of the injected script reported only the label,
   so a wrong script arrived without the script in the log. This form reports
   the sizes instead of the bytes: the runtime script is long enough that two
   copies in one log line say less than its length does. *)
let check_contains ~name ~needle text =
  if not (String_util.contains_substring text needle) then
    Alcotest.failf "%s: %S is missing from %S" name needle text

let check_declares ~name ~needle declaration =
  if not (String_util.contains_substring declaration needle) then
    Alcotest.failf "%s: a %d-byte needle is missing from a %d-byte declaration"
      name (String.length needle) (String.length declaration)
(* The session's end, with a failure as its sentence. *)
let ended_session peer =
  Result.map_error Peer.session_end_failure_message (Peer.end_session peer)
(* A peer for a case that asks for no session. *)
let peer_of command =
  Peer.create ~command ~session_end:(fun () -> fail "this case has no session to end")
(* A host started for the Keeper's Firefox keeps a session only with a
   Firefox that reports running that profile. Firefox 157.0.1 reports the
   path as it was given, so a link and its directory are the same profile. *)
let test_a_session_runs_the_expected_profile () =
  let profile = Filename.temp_dir "masc-peer-profile-" "" in
  let link = profile ^ "-link" in
  Unix.symlink profile link;
  Fun.protect ~finally:(fun () -> Sys.remove link; Unix.rmdir profile) (fun () ->
    let session reported =
      let caps =
        obj ([ "browserName", `String "firefox"; "browserVersion", `String "157.0.1" ]
             @ match reported with Some path -> [ "moz:profile", `String path ] | None -> [])
      in
      let peer =
        Peer.create ~session_end:(fun () -> Ok ()) ~command:(fun method_ _ ->
          match method_ with
          | "session.new" -> Ok (obj [ "sessionId", `String "s"; "capabilities", caps ])
          | other -> failf "unexpected command %s" other)
      in
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      peer
    in
    check (option string) "none before a session" None
      (Peer.profile (peer_of (fun _ _ -> fail "nothing is asked")));
    check (option string) "as Firefox reported it" (Some link) (Peer.profile (session (Some link)));
    List.iter
      (fun (name, reported, expected) ->
        check bool name true (Peer.runs_profile (session (Some reported)) ~expected = Ok ()))
      [ "the same directory", profile, profile; "reported through a link", link, profile
      ; "expected through a link", profile, link ];
    let other = "/Users/someone/Firefox/Profiles/x.default" in
    check bool "another profile, as Firefox named it" true
      (Peer.runs_profile (session (Some other)) ~expected:profile = Error (Peer.Runs_profile other));
    check bool "a Firefox that did not say" true
      (Peer.runs_profile (session None) ~expected:profile = Error Peer.Profile_unsaid))

let script_value json = obj ["type",`String "success";"result",obj ["type",`String "string";"value",`String (Yojson.Safe.to_string json)]]
let test_owned_endpoint_identity_and_shutdown () =
  List.iter (fun (reported,expected) ->
    let closing=ref 0 in
    let peer=Peer.create ~session_end:(fun () -> Ok ()) ~command:(fun method_ _ ->
      match method_ with
      | "session.new" -> Ok (obj ["capabilities",obj
          (["browserName",`String "firefox";"browserVersion",`String "fixture"]
          @ (match reported with None -> [] | Some value -> ["moz:processID",value]))])
      | "browser.close" -> incr closing;Error (Peer.Unanswered "original socket closed")
      | other -> failf "unexpected command %s" other) in
    check (option int) "no process claimed before metadata" None (Peer.process_id peer);
    (match metadata peer with Ok _ -> () | Error detail -> fail detail);
    check (option int) "only a positive browser process identity can be verified" expected (Peer.process_id peer);
    check bool "shutdown uncertainty is retained" true
      (Peer.close_browser peer=Error (Peer.Unanswered "original socket closed"));
    check int "an unanswered close is sent only once" 1 !closing)
    [Some (`Int 42),Some 42;None,None;Some (`String "42"),None;Some (`Int 1),None]

let test_context_identity () =
  let contexts=ref ["a";"b"] in
  let command method_ _ = match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List (List.map (fun c->obj ["context",`String c;"url",`String "https://same.example/"]) !contexts)])
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://same.example/";"title",`String "same";"active",`Bool true]))
    | _ -> Error (Peer.Rejected (Peer.error_code_of_wire "unexpected test command")) in
  let peer=peer_of command in
  let ids () = match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
    | Ok (`List rows) -> List.map (fun row->Yojson.Safe.Util.(row |> member "id" |> to_int)) rows
    | Ok _ | Error (Peer.Before_effect _ | Peer.Partial_failure _ | Peer.Outcome_unknown _) -> fail "tabs failed" in
  check (list int) "same URL does not merge opaque contexts" [1;2] (ids ());
  contexts:=["b"];check (list int) "remaining context keeps identity" [2] (ids ());
  contexts:=["b";"c"];check (list int) "closed context ID never reused" [2;3] (ids ())

let test_unreadable_tab_does_not_hide_other_tabs () =
  let peer = peer_of (fun method_ args -> match method_ with
    | "browsingContext.getTree" ->
      Ok (obj ["contexts", `List [obj ["context", `String "protected"; "url", `String "about:home"];
                                   obj ["context", `String "work"]]])
    | "script.callFunction" ->
      (match Yojson.Safe.Util.(args |> member "target" |> member "context" |> to_string) with
       | "protected" -> Error (Peer.Rejected (Peer.error_code_of_wire "unsupported operation"))
       | "work" -> Ok (script_value (obj ["url", `String "https://example.test/work";
           "title", `String "Work"; "active", `Bool true]))
       | _ -> fail "unknown context")
    | _ -> fail "unexpected command") in
  match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
  | Error _ -> fail "one unreadable tab hid the work tab"
  | Ok data ->
    let open Yojson.Safe.Util in
    check bool "inventory says it is partial" false (data |> member "complete" |> to_bool);
    let available = data |> member "tabs" |> to_list in
    check (list int) "work tab keeps its context identity" [2]
      (List.map (fun row -> row |> member "id" |> to_int) available);
    let unavailable = data |> member "unavailableTabs" |> to_list in
    check (list int) "unreadable tab is not silently dropped" [1]
      (List.map (fun row -> row |> member "id" |> to_int) unavailable);
    check string "browser's refusal survives" "script.callFunction: BiDi command rejected: unsupported operation"
      (List.hd unavailable |> member "error" |> to_string);
    check string "context URL survives even without a script realm" "about:home"
      (List.hd unavailable |> member "url" |> to_string)

let test_active_tab_after_unreadable_tab () =
  let peer = peer_of (fun method_ args -> match method_ with
    | "browsingContext.getTree" ->
      Ok (obj ["contexts", `List [obj ["context", `String "protected"];
                                   obj ["context", `String "work"]]])
    | "script.callFunction" ->
      (match Yojson.Safe.Util.(args |> member "target" |> member "context" |> to_string) with
       | "protected" -> Error (Peer.Rejected (Peer.error_code_of_wire "unsupported operation"))
       | "work" -> Ok (script_value (obj ["url", `String "https://example.test/work";
           "title", `String "Work"; "active", `Bool true; "text", `String "readable"]))
       | _ -> fail "unknown context")
    | _ -> fail "unexpected command") in
  match Peer.dispatch peer ~verb:Peer.Page_read (obj []) with
  | Ok data ->
    let open Yojson.Safe.Util in
    check int "implicit read reaches the readable active tab" 2 (data |> member "tabId" |> to_int);
    check string "the selected tab is read" "readable" (data |> member "text" |> to_string)
  | Error (Peer.Before_effect detail | Peer.Outcome_unknown detail
          | Peer.Partial_failure {message=detail;_}) -> fail detail

let test_capture_guards () =
  let viewport document = obj ["documentId", `String document; "width", `Int 800;
    "height", `Int 600; "scrollX", `Int 0; "scrollY", `Int 0] in
  let state url document = obj ["url", `String url; "title", `String "Work";
    "viewport", viewport document] in
  let url = "https://example.test/work" in
  List.iter (fun (name, after, accepted) ->
    let captured = ref false in
    let peer = peer_of (fun method_ _ -> match method_ with
      | "browsingContext.getTree" -> Ok (obj ["contexts", `List [obj ["context", `String "work"]]])
      | "script.callFunction" -> Ok (script_value (if !captured then after else state url "before"))
      | "browsingContext.captureScreenshot" -> captured := true; Ok (obj ["data", `String "png"])
      | _ -> fail "unexpected capture command") in
    match Peer.dispatch peer ~verb:Peer.Page_capture (obj ["tabId", `Int 1]), accepted with
    | Ok data, true ->
      let open Yojson.Safe.Util in
      check string name "png" (data |> member "data" |> to_string);
      check bool "capture retains the document guard" true (member "viewport" data = viewport "before")
    | Error (Peer.Before_effect detail), false ->
      check string name "viewport_changed_during_capture" detail
    | Ok _, false -> failf "%s accepted a stale screenshot" name
    | Error (Peer.Before_effect detail), true
    | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}), _ -> fail detail)
    ["stable capture", state url "before", true;
     "navigation", state "https://example.test/elsewhere" "before", false;
     "same-URL document replacement", state url "after", false;
     "scroll during capture", obj ["url", `String url; "title", `String "Work";
        "viewport", obj ["documentId", `String "before"; "width", `Int 800;
          "height", `Int 600; "scrollX", `Int 0; "scrollY", `Int 100]], false]
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
  let peer=peer_of command in
  match Peer.dispatch peer ~verb:Peer.Page_read (obj ["tabId",`Int 1;"includeHtml",`Bool true]) with
  | Ok data ->
    let open Yojson.Safe.Util in
    check int "the document names the tab it read" 1 (data |> member "tabId" |> to_int);
    check string "and carries the source" "<html></html>" (data |> member "html" |> to_string);
    (match !ran with
     | [declaration] ->
       check_declares ~name:"one script, the shared document helper"
         ~needle:Browser_lane.Document.runtime declaration;
       check_contains
         ~name:"one script, ending in the shared document helper call"
         ~needle:"return browserDocument();" declaration
     | _ -> fail "the document read ran other than one script")
  | Error (Peer.Before_effect detail) | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) ->
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
    let peer=peer_of command in
    (match Peer.dispatch peer ~verb args with
     | Error (Peer.Before_effect detail) ->
       check string (name ^ ": the refusal says to read again")
         "the document is still loading; read it again" detail
     | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) -> failf "%s was reported as an unknown outcome: %s" name detail
     | Ok _ -> failf "%s was answered for a document still loading" name);
    match !ran with
    | [declaration] ->
      check_contains
        ~name:(name ^ ": the page is asked whether its parser is done")
        ~needle:"document.readyState === 'loading'" declaration
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
    let peer=peer_of command in
    (match Peer.dispatch peer ~verb args with
     | Error (Peer.Before_effect detail) ->
       check string (name ^ ": the refusal names the size and the bound")
         (Printf.sprintf "page_answer_exceeds_bidi_reply_limit: %d UTF-16 units, at most %d cross this connection"
            measured Peer.script_answer_limit_units) detail
     | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) -> failf "%s was reported as an unknown outcome: %s" name detail
     | Ok _ -> failf "%s accepted a length as its answer" name);
    match !ran with
    | [declaration] ->
      check_contains
        ~name:(name ^ ": the page measures its answer against the bound")
        ~needle:
          (Printf.sprintf "answer.length > %d ? answer.length : answer"
             Peer.script_answer_limit_units)
        declaration
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
  let peer=peer_of command in
  match Peer.dispatch peer ~verb:Peer.Page_elements (obj ["tabId",`Int 2]) with
  | Ok data ->
    let open Yojson.Safe.Util in
    check int "the inventory names the tab it read" 2 (data |> member "tabId" |> to_int);
    check int "and carries the page's elements" 1 (data |> member "elements" |> to_list |> List.length);
    (match !ran with
     | [context, declaration] ->
       check string "one script, in the requested tab" "owned" context;
       check_contains ~name:"and it is the shared element script"
         ~needle:Masc.Browser_page_script.elements declaration
     | _ -> fail "the inventory ran other than one script")
  | Error (Peer.Before_effect detail) | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) ->
    failf "the peer refused an element inventory: %s" detail
let test_pointer_validation () =
  let calls=ref [] in
  let command method_ _ =
    calls:=method_::!calls;
    match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | _ -> Error (Peer.Rejected (Peer.error_code_of_wire "unexpected effect dispatch")) in
  let peer=peer_of command in
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
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port)->port| `Unix _->fail "Unix socket expected" in
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
(* The window a scripted case gives the connection to attach and answer, and
   the bound on the whole case. *)
let scripted_timeout_sec = 1.
let scripted_case_deadline_sec = 2.
(* A session case may wait out one unanswered command and one unanswered
   session.end. *)
let scripted_session_deadline_sec =
  scripted_timeout_sec +. Peer.session_end_window_sec +. scripted_case_deadline_sec
(* Firefox going away is told to whoever holds the connection, also when no
   command is in flight: a host waiting for work has to learn that the
   browser it serves is gone. *)
let test_a_closed_socket_ends_the_connection () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock=Eio.Stdenv.clock env in
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with
        | `Tcp (_,port)->port
        | `Unix _->fail "TCP expected" in
      let close,close_u=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun ()->Eio.Switch.run (fun peer_sw ->
        let flow,_=Eio.Net.accept ~sw:peer_sw listener in
        let head=Ws_direct_eio.Driver.read_head ~clock flow in
        let key=match Ws_direct_eio.Handshake.request_key head with Ok key->key|Error e->fail e in
        Eio.Flow.copy_string (Ws_direct_eio.Handshake.server_response ~key) flow;
        Eio.Promise.await close));
      Eio.Time.with_timeout_exn clock scripted_case_deadline_sec (fun ()->
        let actual=Peer.with_connection ~env ~timeout:scripted_timeout_sec
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
let send_server_frame flow opcode payload =
  let length=String.length payload in
  if length >= 126 then fail "scripted frame too long";
  Eio.Flow.copy_string (String.init 2 (function
    | 0 -> Char.chr (0x80 lor opcode)
    | _ -> Char.chr length) ^ payload) flow
let reply_to request result =
  obj ["type",`String "success";"id",Yojson.Safe.Util.member "id" request;"result",result]
let with_scripted_firefox script use =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock=Eio.Stdenv.clock env in
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:1
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with
        | `Tcp (_,port)->port
        | `Unix _->fail "TCP expected" in
      Eio.Fiber.fork ~sw (fun ()->Eio.Switch.run (fun peer_sw ->
        let flow,_=Eio.Net.accept ~sw:peer_sw listener in
        let head=Ws_direct_eio.Driver.read_head ~clock flow in
        let key=match Ws_direct_eio.Handshake.request_key head with Ok key->key|Error e->fail e in
        Eio.Flow.copy_string (Ws_direct_eio.Handshake.server_response ~key) flow;
        script flow));
      Eio.Time.with_timeout_exn clock scripted_session_deadline_sec (fun ()->
        Peer.with_connection ~env ~timeout:scripted_timeout_sec
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
    check (result unit string) "nothing to end before a session exists" (Ok ()) (ended_session peer);
    check bool "and nothing was sent for it" true (!seen=[]);
    (match metadata peer with
     | Ok version -> check string "the session was created" "157.0-scripted" version
     | Error detail -> fail detail);
    (match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
     | Error (Peer.Before_effect detail) ->
       check string "a command that got no reply ends the connection for page commands"
         "browsingContext.getTree: BiDi transport deadline exceeded" detail
     | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) -> fail detail
     | Ok _ -> fail "an unanswered command produced an answer");
    check (option string) "its holder is told" (Some "BiDi transport deadline exceeded")
      (Eio.Promise.peek ended);
    check (result unit string) "the session is still ended, over the open socket" (Ok ())
      (ended_session peer);
    check (result unit string) "once" (Ok ()) (ended_session peer);
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
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      (* The script returned after its one answer, which closed the socket.
         The session is ended only once this side has seen that. *)
      let closed=Eio.Promise.await ended in
      Error (closed ^ " / " ^ (match ended_session peer with
        | Ok () -> "ended" | Error detail -> detail))) in
  check (result unit string) "a closed socket" (Error "BiDi EOF / BiDi EOF") closed_under_it;
  let unanswered=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow));
      ignore (read_client_message flow : Yojson.Safe.t);
      (* Held open without an answer until the client is done. *)
      try ignore (Eio.Flow.single_read flow (Cstruct.create 1) : int) with End_of_file -> ())
    (fun ~ended:_ peer ->
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      match ended_session peer with
      | Ok () -> Ok ()
      | Error detail -> Error detail) in
  check (result unit string) "no answer in the window" (Error "no answer to session.end in time") unanswered
(* A session.end waiting for its answer on a connection this side already
   stopped trusting is told when the socket closes, instead of waiting out its
   window. *)
let test_a_socket_closing_under_session_end_is_told_at_once () =
  let outcome=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow));
      ignore (read_client_message flow : Yojson.Safe.t);
      (* Returning after session.end arrived closes the socket under it. *)
      ignore (read_client_message flow : Yojson.Safe.t))
    (fun ~ended:_ peer ->
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      (match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
       | Error (Peer.Before_effect _) -> ()
       | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) -> fail detail
       | Ok _ -> fail "an unanswered command produced an answer");
      ended_session peer) in
  check (result unit string) "the socket's end, not the window's" (Error "BiDi EOF") outcome
(* Whether Firefox still holds the session depends on why it was not ended:
   with the socket gone this side cannot tell, and a Firefox that was asked
   and did not confirm keeps it. *)
let test_why_a_session_was_not_ended_says_whether_firefox_could_be_asked () =
  let kind = function
    | Ok () -> "ended"
    | Error (Peer.Connection_gone _) -> "connection gone"
    | Error (Peer.Not_confirmed _) -> "not confirmed" in
  let ending script =
    let seen=ref "not reached" in
    let finished=with_scripted_firefox script (fun ~ended:_ peer ->
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      seen:=kind (Peer.end_session peer);
      Ok ()) in
    check (result unit string) "the connection finished" (Ok ()) finished;
    !seen in
  (* What Firefox says of a session it was asked for and does not have
     (measured on 157.0.1): there is none to end. *)
  check string "Firefox has no such session" "ended" (ending (fun flow ->
    send_server_message flow (session_created (read_client_message flow));
    let ending=read_client_message flow in
    send_server_message flow (obj ["type",`String "error";"id",Yojson.Safe.Util.member "id" ending;
      "error",`String "invalid session id"])));
  List.iter (fun code ->
      check string ("Firefox refuses to end it: " ^ code) "not confirmed" (ending (fun flow ->
        send_server_message flow (session_created (read_client_message flow));
        let ending=read_client_message flow in
        send_server_message flow (obj ["type",`String "error";"id",Yojson.Safe.Util.member "id" ending;
          "error",`String code]))))
    (* The code that refuses a [session.new] says nothing of ending one. *)
    ["unknown error"; "session not created"];
  check string "Firefox does not answer" "not confirmed" (ending (fun flow ->
    send_server_message flow (session_created (read_client_message flow));
    ignore (read_client_message flow : Yojson.Safe.t);
    try ignore (Eio.Flow.single_read flow (Cstruct.create 1) : int) with End_of_file -> ()));
  check string "the socket closes under the request" "connection gone" (ending (fun flow ->
    send_server_message flow (session_created (read_client_message flow));
    ignore (read_client_message flow : Yojson.Safe.t)))
(* Firefox may hold a session from the moment it is asked for one. An answer
   that never came leaves one to end; Firefox's own refusal leaves none. *)
let test_a_session_nobody_confirmed_is_ended () =
  let seen=ref [] in
  let unanswered=with_scripted_firefox (fun flow ->
      let asked=read_client_message flow in
      seen:=method_of asked :: !seen;
      let ending=read_client_message flow in
      seen:=method_of ending :: !seen;
      send_server_message flow (reply_to ending (obj [])))
    (fun ~ended:_ peer ->
      check (result string string) "no answer to session.new"
        (Error "BiDi transport deadline exceeded") (metadata peer);
      ended_session peer) in
  check (result unit string) "the session is ended all the same" (Ok ()) unanswered;
  check (list string) "what Firefox was sent, in order" ["session.new";"session.end"] (List.rev !seen)
let test_a_refused_session_leaves_none_to_end () =
  let seen=ref [] in
  let refused=with_scripted_firefox (fun flow ->
      let asked=read_client_message flow in
      seen:=method_of asked :: !seen;
      send_server_message flow (obj ["type",`String "error";"id",Yojson.Safe.Util.member "id" asked;
        "error",`String "session not created";"message",`String "Maximum number of active sessions"]);
      (* Anything further would be read here; the client leaving ends it. *)
      match read_client_message flow with
      | further -> seen:=method_of further :: !seen
      | exception End_of_file -> ())
    (fun ~ended peer ->
      (* Firefox says this while it holds a session, so the host is told it
         was refused one, apart from every other way of getting none. *)
      (match Peer.metadata peer with
       | Error (Peer.Session_refused said) ->
         check string "Firefox's refusal is the error" "BiDi command rejected: session not created" said
       | Error (Peer.Session_failed said) -> failf "a refused session was read as a failed one: %s" said
       | Ok version -> failf "a refused session answered a version: %s" version);
      check bool "and the connection is not ended by it" true (Eio.Promise.peek ended=None);
      ended_session peer) in
  check (result unit string) "nothing to end" (Ok ()) refused;
  check (list string) "Firefox was sent nothing after its refusal" ["session.new"] (List.rev !seen)
(* "session not created" is the one refusal that says Firefox holds a
   session. Any other is a session it did not start, with nothing said of
   one that is there. *)
let test_a_session_refused_for_another_reason_is_a_failed_one () =
  List.iter (fun code ->
      let refused=with_scripted_firefox (fun flow ->
          let asked=read_client_message flow in
          send_server_message flow (obj ["type",`String "error";"id",Yojson.Safe.Util.member "id" asked;
            "error",`String code;"message",`String "the profile is locked"]);
          match read_client_message flow with
          | (_ : Yojson.Safe.t) -> ()
          | exception End_of_file -> ())
        (fun ~ended:_ peer ->
          (match Peer.metadata peer with
           | Error (Peer.Session_failed said) ->
             check string "Firefox's own error is the reason" ("BiDi command rejected: " ^ code) said
           | Error (Peer.Session_refused said) -> failf "another error was read as a session Firefox holds: %s" said
           | Ok version -> failf "a refused session answered a version: %s" version);
          ended_session peer) in
      check (result unit string) ("nothing to end: " ^ code) (Ok ()) refused)
    (* The code a session command gets without a session says nothing of
       one Firefox holds. *)
    ["unknown error"; "invalid session id"]
(* An error answer without its code is not a refusal this side can read, so
   the session is still ended. *)
let test_an_unreadable_refusal_leaves_a_session_to_end () =
  let seen=ref [] in
  let outcome=with_scripted_firefox (fun flow ->
      let asked=read_client_message flow in
      seen:=method_of asked :: !seen;
      send_server_message flow (obj ["type",`String "error";"id",Yojson.Safe.Util.member "id" asked]);
      let ending=read_client_message flow in
      seen:=method_of ending :: !seen;
      send_server_message flow (reply_to ending (obj [])))
    (fun ~ended:_ peer ->
      check (result string string) "the answer has no code" (Error "BiDi missing error") (metadata peer);
      ended_session peer) in
  check (result unit string) "the session is ended" (Ok ()) outcome;
  check (list string) "what Firefox was sent, in order" ["session.new";"session.end"] (List.rev !seen)
(* The ways a session request ends without an answer that no socket scripts:
   the caller gave up on it, a browser that is not Firefox, and a request the
   connection never carried. *)
let test_a_session_is_there_to_end_once_asked_for () =
  Eio_main.run (fun _ ->
    let ended=ref 0 in
    let asking answer=Peer.create ~session_end:(fun () -> incr ended; Ok ())
      ~command:(fun method_ _ -> match method_ with
        | "session.new" -> answer ()
        | other -> failf "unexpected command: %s" other) in
    let abandoned=asking (fun () -> Eio.Fiber.await_cancel ()) in
    Eio.Fiber.first (fun () -> ignore (metadata abandoned : (string,string) result)) (fun () -> ());
    check (result unit string) "a request the caller gave up on" (Ok ()) (ended_session abandoned);
    check int "is ended" 1 !ended;
    check (result unit string) "once" (Ok ()) (ended_session abandoned);
    check int "and not again" 1 !ended;
    let other_browser=asking (fun () -> Ok (obj ["sessionId",`String "scripted";"capabilities",
      obj ["browserName",`String "chromium";"browserVersion",`String "1"]])) in
    check (result string string) "a browser that is not Firefox is turned down"
      (Error "BiDi peer must be Firefox") (metadata other_browser);
    check (result unit string) "with the session it created" (Ok ()) (ended_session other_browser);
    check int "ended" 2 !ended;
    let never_written=asking (fun () -> Error (Peer.Unsent "BiDi EOF")) in
    check (result string string) "a request the connection never carried"
      (Error "BiDi EOF") (metadata never_written);
    check (result unit string) "asked Firefox for nothing" (Ok ()) (ended_session never_written);
    check int "so nothing is ended" 2 !ended)
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
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port)->port| `Unix _->fail "Unix socket expected" in
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
let test_peer_close_frame_ends_a_pending_command () =
  let outcome=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow));
      ignore (read_client_message flow : Yojson.Safe.t);
      send_server_frame flow 0x8 "";
      try ignore (Eio.Flow.single_read flow (Cstruct.create 1) : int) with End_of_file -> ())
    (fun ~ended peer ->
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      let result=Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) in
      check bool "the close callback ends the holder" true (Eio.Promise.peek ended <> None);
      match result with
      | Error (Peer.Before_effect "browsingContext.getTree: BiDi peer closed") -> Ok ()
      | Error (Peer.Before_effect detail) -> Error detail
      | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) -> Error detail
      | Ok _ -> Error "a pending command survived the close frame") in
  check (result unit string) "close frame is delivered" (Ok ()) outcome
let test_malformed_json_ends_a_pending_command () =
  let outcome=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow));
      ignore (read_client_message flow : Yojson.Safe.t);
      send_server_frame flow 0x1 "not-json";
      try ignore (Eio.Flow.single_read flow (Cstruct.create 1) : int) with End_of_file -> ())
    (fun ~ended peer ->
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      let result=Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) in
      check bool "invalid text disconnects the holder" true (Eio.Promise.peek ended <> None);
      match result with
      | Error (Peer.Before_effect "browsingContext.getTree: invalid BiDi JSON") -> Ok ()
      | Error (Peer.Before_effect detail) -> Error detail
      | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}) -> Error detail
      | Ok _ -> Error "invalid JSON produced an answer") in
  check (result unit string) "malformed JSON is reported" (Ok ()) outcome
let test_invalid_websocket_frame_ends_a_pending_command () =
  let outcome=with_scripted_firefox (fun flow ->
      send_server_message flow (session_created (read_client_message flow));
      ignore (read_client_message flow : Yojson.Safe.t);
      (* Reserved opcode 0x3 is not a valid data frame. *)
      send_server_frame flow 0x3 "";
      try ignore (Eio.Flow.single_read flow (Cstruct.create 1) : int) with End_of_file -> ())
    (fun ~ended peer ->
      (match metadata peer with Ok _ -> () | Error detail -> fail detail);
      let result=Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) in
      check bool "the protocol error reaches the closed callback" true (Eio.Promise.peek ended <> None);
      match result with
      | Error (Peer.Before_effect _ | Peer.Outcome_unknown _ | Peer.Partial_failure _) -> Ok ()
      | Ok _ -> Error "an invalid websocket frame produced an answer") in
  check (result unit string) "invalid frame ends the connection" (Ok ()) outcome
let test_semantic_click_uses_native_input () =
  Eio_main.run (fun _ ->
    let viewport = obj ["documentId",`String "observed";"width",`Int 800;"height",`Int 600;
      "scrollX",`Int 0;"scrollY",`Int 0] in
    let point = obj ["x",`Float 0.25;"y",`Float 0.5] in
    List.iter (fun target ->
      let scripts = ref 0 and inputs = ref 0 and releases = ref 0 in
      let peer = peer_of (fun method_ args -> match method_ with
        | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
        | "script.callFunction" ->
          incr scripts;
          let passed = Yojson.Safe.Util.(args |> member "arguments" |> index 0 |> member "value" |> to_string)
            |> Yojson.Safe.from_string in
          (match !scripts with
           | 1 -> Ok (script_value (obj ["url",`String "https://example.test/";"point",point;"viewport",viewport]))
           | 2 ->
             check string "native guard uses captured URL when caller omitted it" "https://example.test/"
               Yojson.Safe.Util.(passed |> member "expectedUrl" |> to_string);
             Ok (script_value (obj ["url",`String "https://example.test/"]))
           | _ -> Ok (script_value (obj ["url",`String "https://example.test/";"title",`String "fixture"])))
        | "input.performActions" ->
          incr inputs;
          let steps = Yojson.Safe.Util.(args |> member "actions" |> index 0 |> member "actions" |> to_list) in
          check (list string) "native click emits trusted pointer sequence" ["pointerMove";"pointerDown";"pointerUp"]
            (List.map Yojson.Safe.Util.(fun row -> row |> member "type" |> to_string) steps);
          Ok `Null
        | "input.releaseActions" -> incr releases; Ok `Null
        | other -> failf "unexpected click command %s" other) in
      let result = Peer.dispatch peer ~verb:Peer.Page_interact
        (obj (["tabId",`Int 1;"action",`String "click"] @ target)) in
      (match result with
       | Ok receipt -> check string "receipt keeps semantic action" "click" Yojson.Safe.Util.(receipt |> member "action" |> to_string)
       | Error _ -> fail "semantic native click failed");
      check int "one native click only" 1 !inputs;
      check int "native input released" 1 !releases;
      check int "resolver, guard, receipt; no DOM click script" 3 !scripts)
      [["selector",`String "#menu"];
       ["documentId",`String "observed";"nodeId",`String "menu"]])

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
    let peer = peer_of command in
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
let test_native_keyboard_release_and_failure () = Eio_main.run (fun _ ->
  let sent=ref 0 and released=ref 0 and guard_failure=ref false and lost=ref false in
  let command method_ _ = match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | "script.callFunction" -> if !guard_failure then Error (Peer.Rejected (Peer.error_code_of_wire "stale document"))
      else Ok (script_value (obj ["url",`String "https://example.org";"title",`String "native"]))
    | "input.performActions" -> incr sent;if !lost then Error (Peer.Unanswered "input reply missing") else Ok `Null
    | "input.releaseActions" -> incr released;Ok `Null
    | _ -> fail ("unexpected native command " ^ method_) in
  let peer=peer_of command in
  List.iter (fun (action,extra) ->
    let args=obj (["tabId",`Int 1;"expectedUrl",`String "https://example.org";"action",`String action;
      "documentId",`String "d1"] @ extra) in
    sent:=0;released:=0;
    (match Peer.dispatch peer ~verb:Peer.Page_interact args with Ok _->()|Error _->fail "native keyboard failed");
    check int "native input once" 1 !sent;check int "keyboard cleanup" 1 !released;
    guard_failure:=true;sent:=0;released:=0;
    (match Peer.dispatch peer ~verb:Peer.Page_interact args with Error (Peer.Before_effect _)->()|_->fail "stale guard must reject");
    check int "stale guard cannot press keys" 0 !sent;
    guard_failure:=false;lost:=true;sent:=0;released:=0;
    (match Peer.dispatch peer ~verb:Peer.Page_interact args with Error (Peer.Outcome_unknown _)->()|_->fail "lost input stays unknown");
    check int "unknown input never retried" 1 !sent;check int "unknown input still released" 1 !released;
    lost:=false)
    ["type_text",["text",`String "한🙂"];
     "press_key",["key",`String "a";"modifiers",`List [`String "Meta"]]];
  List.iter (fun text -> sent:=0;released:=0;
    (match Peer.dispatch peer ~verb:Peer.Page_interact (obj ["tabId",`Int 1;
      "expectedUrl",`String "https://example.org";"action",`String "type_text";
      "documentId",`String "d1";"text",`String text]) with
     | Error (Peer.Before_effect _) -> () | _ -> fail "text controls/reserved scalars must reject before input");
    check int "rejected text sends no native input" 0 !sent;
    check int "rejected text sends no native release" 0 !released) ["a\tb";"a\nb";"a\rb";"\xee\x80\x89"])


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
      | Point_click -> interact (Click_at {point;viewport;button=Pointer.Primary})
      | Point_scroll -> interact (Scroll_at {point;viewport;x=0;y=120})
      | Trusted_hover -> interact (Hover_at {point;viewport})
      | Trusted_drag -> interact (Drag {from=point;to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0})
      | Trusted_double_click -> interact (Double_click_at {point;viewport})
      | Trusted_button_click -> interact (Click_at {point;viewport;button=Pointer.Secondary})
      | Viewport_resize -> interact (Set_viewport (Fit {width=800;height=600}))
      | Touch_input -> interact (Swipe {from=point;to_={x=0.75;y=0.5};viewport;via=[];duration_ms=0})
      | Trusted_keyboard -> interact (Type_text {document_id=viewport.document_id;text="hello"})
      | Browser_zoom -> interact (Set_zoom {factor=1.5})
      | Tab_history -> Page_act (Action.On_tab {tab_id=2;frame_path=[];interaction=Action.Back})
      | Tab_closing -> Page_act (Action.On_tab {tab_id=2;frame_path=[];interaction=Action.Close_tab})
      | Tab_activation -> interact Activate_tab
  | Tab_creation -> Page_act (Action.Open_tab "https://example.test/new")) in
    (* The names the native host forwards (Browser_host.decode_poll). *)
    let peer_verb = function
      | "tabs.list" -> Peer.Tabs_list | "page.read" -> Peer.Page_read | "page.scene" -> Peer.Page_scene
      | "page.elements" -> Peer.Page_elements | "page.capture" -> Peer.Page_capture
      | "page.interact" -> Peer.Page_interact | "page.act" -> Peer.Page_act
      | other -> failf "the lane put a verb on the wire that the host does not forward: %s" other in
    let calls = ref [] in
    let created = ref false in
    let command method_ _ =
      calls := method_ :: !calls;
      match method_ with
      | "browsingContext.getTree" -> Ok (obj ["contexts",`List
          (obj ["context",`String "owned"] :: if !created then [obj ["context",`String "created"]] else [])])
      | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";
          "title",`String "fixture";"active",`Bool true;
          "point",Lane.Pointer.point_to_json point;"viewport",Lane.Pointer.viewport_to_json viewport]))
      | "browsingContext.create" -> created := true; Ok (obj ["context",`String "created"])
      | "browsingContext.navigate" -> Ok `Null
      | "browsingContext.captureScreenshot" -> Ok (obj ["data",`String "png"])
      | "input.performActions" | "input.releaseActions" | "browsingContext.setViewport"
      | "browsingContext.traverseHistory" | "browsingContext.reload" | "browsingContext.close" -> Ok `Null
      | other -> failf "unexpected protocol command: %s" other in
    let peer = peer_of command in
    (* The listing gives the operator's tab ID 1, then a tab this connection opens gets ID 2, so closing
       one is something it can serve. *)
    ignore (Peer.dispatch peer ~verb:Peer.Tabs_list (obj []));
    (match Peer.dispatch peer ~verb:Peer.Page_act Yojson.Safe.Util.(
       Lane.verb_json (Lane.Page_act (Lane.Action.Open_tab "https://example.test/new")) |> member "args") with
     | Ok _ -> ()
     | Error _ -> fail "the fixture could not open its own tab");
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
      | Error (Peer.Before_effect detail), true | Error (Peer.Outcome_unknown detail | Peer.Partial_failure {message=detail;_}), _ ->
        failf "the peer did not serve %s (%s), which the lane table says BiDi does" name detail)
      Lane.all_of_live_capability)
let test_set_viewport_sends_the_size_or_clears_it () =
  let sent = ref [] in
  let peer = peer_of (fun method_ args ->
    match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";"title",`String "fixture";
        "innerWidth",`Int 800;"innerHeight",`Int 600;"devicePixelRatio",`Float 1.]))
    | "browsingContext.setViewport" -> sent := args :: !sent; Ok `Null
    | other -> failf "unexpected protocol command: %s" other) in
  let dispatch size = Peer.dispatch peer ~verb:Peer.Page_interact
    (Browser_lane.interaction_args ~tab_id:1 ~expected_url:(Some "https://example.test/") (Browser_lane.Set_viewport size)) in
  (match dispatch (Browser_lane.Fit {width=800;height=600}) with
   | Ok receipt ->
     check string "the receipt names the action" "set_viewport" Yojson.Safe.Util.(receipt |> member "action" |> to_string);
     check int "the receipt reads the size the page now has" 800 Yojson.Safe.Util.(receipt |> member "innerWidth" |> to_int)
   | Error _ -> fail "a size inside the bounds was refused");
  (match dispatch Browser_lane.Browser_default with Ok _ -> () | Error _ -> fail "restoring the browser's size was refused");
  match List.rev_map (fun args -> Yojson.Safe.Util.member "viewport" args) !sent with
  | [size; cleared] ->
    check string "the size reaches BiDi in CSS pixels" {|{"width":800,"height":600}|} (Yojson.Safe.to_string size);
    check bool "no size clears the override with null" true (cleared = `Null)
  | other -> failf "expected two setViewport commands, saw %d" (List.length other)
let test_ending_the_session_restores_a_sized_tab () =
  let sent = ref [] in
  let peer = Peer.create ~session_end:(fun () -> Ok ()) ~command:(fun method_ args ->
    match method_ with
    | "session.new" -> Ok (obj ["capabilities",obj ["browserName",`String "firefox";"browserVersion",`String "158.0"]])
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";"title",`String "fixture";
        "innerWidth",`Int 800;"innerHeight",`Int 600;"devicePixelRatio",`Float 1.]))
    | "browsingContext.setViewport" -> sent := args :: !sent; Ok `Null
    | other -> failf "unexpected protocol command: %s" other) in
  ignore (Peer.metadata peer);
  let dispatch size = Peer.dispatch peer ~verb:Peer.Page_interact
    (Browser_lane.interaction_args ~tab_id:1 ~expected_url:(Some "https://example.test/") (Browser_lane.Set_viewport size)) in
  ignore (dispatch (Browser_lane.Fit {width=390;height=844}));
  check int "one size was set" 1 (List.length !sent);
  check bool "ending the session succeeds" true (ended_session peer = Ok ());
  (match !sent with
   | cleared :: _ :: [] ->
     check bool "the sized tab gets its own size back" true (Yojson.Safe.Util.member "viewport" cleared = `Null);
     check bool "in the context that was sized" true
       (Yojson.Safe.Util.member "context" cleared = `String "owned")
   | other -> failf "expected the size and one restore, saw %d commands" (List.length other))
let test_a_tab_restored_by_the_caller_is_not_restored_again () =
  let sent = ref [] in
  let peer = Peer.create ~session_end:(fun () -> Ok ()) ~command:(fun method_ args ->
    match method_ with
    | "session.new" -> Ok (obj ["capabilities",obj ["browserName",`String "firefox";"browserVersion",`String "158.0"]])
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "owned"]]])
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";"title",`String "fixture";
        "innerWidth",`Int 800;"innerHeight",`Int 600;"devicePixelRatio",`Float 1.]))
    | "browsingContext.setViewport" -> sent := args :: !sent; Ok `Null
    | other -> failf "unexpected protocol command: %s" other) in
  ignore (Peer.metadata peer);
  let dispatch size = Peer.dispatch peer ~verb:Peer.Page_interact
    (Browser_lane.interaction_args ~tab_id:1 ~expected_url:(Some "https://example.test/") (Browser_lane.Set_viewport size)) in
  ignore (dispatch (Browser_lane.Fit {width=390;height=844}));
  ignore (dispatch Browser_lane.Browser_default);
  ignore (ended_session peer);
  check int "the caller's restore is the last size command" 2 (List.length !sent)
let test_history_and_close_act_only_on_tabs_this_connection_opened () =
  let sent = ref [] and created = ref false and history_error = ref None in
  let peer = peer_of (fun method_ args ->
    match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List
        (obj ["context",`String "owned"] :: if !created then [obj ["context",`String "created"]] else [])])
    | "browsingContext.create" -> created := true; Ok (obj ["context",`String "created"])
    | "browsingContext.navigate" -> Ok `Null
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";"title",`String "fixture";"active",`Bool true]))
    | "browsingContext.traverseHistory" | "browsingContext.reload" when !history_error <> None ->
      (match !history_error with Some code -> Error (Peer.Rejected (Peer.error_code_of_wire code)) | None -> fail "no error set")
    | "browsingContext.traverseHistory" | "browsingContext.reload" | "browsingContext.close" ->
      sent := (method_,args) :: !sent; Ok `Null
    | other -> failf "unexpected protocol command: %s" other) in
  ignore (Peer.dispatch peer ~verb:Peer.Tabs_list (obj []));
  let act tab_id interaction = Peer.dispatch peer ~verb:Peer.Page_act
    (Browser_lane.Action.to_json (Browser_lane.Action.On_tab {tab_id;frame_path=[];interaction})) in
  let member key json = Yojson.Safe.Util.member key json in
  let last () = match !sent with latest :: _ -> latest | [] -> fail "nothing was sent" in
  let delta () = member "delta" (snd (last ())) in
  (* The operator's tab, ID 1, is refused for every one of the four, before any command. *)
  List.iter (fun interaction ->
    (match act 1 interaction with
     | Error (Peer.Before_effect _) -> ()
     | Ok _ | Error (Peer.Partial_failure _ | Peer.Outcome_unknown _) -> fail "an operator tab was acted on");
    check int "nothing was sent for the operator's tab" 0 (List.length !sent))
    Browser_lane.Action.[Back; Forward; Reload; Close_tab];
  (match Peer.dispatch peer ~verb:Peer.Page_act
     (Browser_lane.Action.to_json (Browser_lane.Action.Open_tab "https://example.test/new")) with
   | Ok _ -> () | Error _ -> fail "opening a tab failed");
  (match act 2 Browser_lane.Action.Back with
   | Ok receipt -> check string "back is named in the receipt" "back" Yojson.Safe.Util.(receipt |> member "action" |> to_string)
   | Error _ -> fail "back was refused");
  check bool "back goes one entry back in the opened tab's context" true
    (fst (last ()) = "browsingContext.traverseHistory" && delta () = `Int (-1)
     && member "context" (snd (last ())) = `String "created");
  ignore (act 2 Browser_lane.Action.Forward);
  check bool "forward goes one entry forward" true (delta () = `Int 1);
  ignore (act 2 Browser_lane.Action.Reload);
  check bool "reload waits for the document" true
    (fst (last ()) = "browsingContext.reload" && member "wait" (snd (last ())) = `String "complete");
  history_error := Some "no such history entry";
  (match act 2 Browser_lane.Action.Back with
   | Error (Peer.Before_effect _) -> ()
   | Ok _ | Error (Peer.Partial_failure _ | Peer.Outcome_unknown _) -> fail "a refusal before the step is not before effect");
  (* A reload that lands on an error page is answered with an error after the tab moved. *)
  history_error := Some "unknown error";
  (match act 2 Browser_lane.Action.Reload with
   | Error (Peer.Outcome_unknown _) -> ()
   | Ok _ | Error (Peer.Before_effect _ | Peer.Partial_failure _) -> fail "an error after a reload started was called before effect");
  history_error := None;
  (match act 2 Browser_lane.Action.Close_tab with
   | Ok receipt -> check bool "the receipt says it closed" true (member "closed" receipt = `Bool true)
   | Error _ -> fail "a tab this connection opened was not closed");
  check bool "the close does not run the page's unload prompt" true
    (fst (last ()) = "browsingContext.close" && member "promptUnload" (snd (last ())) = `Bool false
     && member "context" (snd (last ())) = `String "created");
  match act 2 Browser_lane.Action.Close_tab with
  | Error (Peer.Before_effect _) -> ()
  | Ok _ | Error (Peer.Partial_failure _ | Peer.Outcome_unknown _) -> fail "a closed tab was closed again"
let test_tabs_name_their_window () =
  let peer = peer_of (fun method_ _ ->
    match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List [
        obj ["context",`String "a";"clientWindow",`String "w1"];
        obj ["context",`String "b";"clientWindow",`String "w2"];
        obj ["context",`String "c";"clientWindow",`String "w2"];
        obj ["context",`String "d"]]])
    | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/";"title",`String "t";"active",`Bool true]))
    | other -> failf "unexpected protocol command: %s" other) in
  match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
  | Ok (`List rows) ->
    let window row = Yojson.Safe.Util.member "windowId" row in
    (match List.map window rows with
     | [`Int a; `Int b; `Int c; `Null] ->
       check bool "tabs in different windows get different IDs" true (a <> b);
       check bool "tabs in one window share an ID" true (b = c)
     | _ -> fail "expected three window IDs and one tab with none")
  | Ok _ | Error _ -> fail "the tab listing failed"
(* Firefox's error codes are read once where the answer arrives. The two
   this host acts on are their own cases; any other is kept as Firefox wrote
   it, and every code is written back as it was read. *)
let test_an_error_code_is_read_once_and_written_back () =
  let read code =
    match Peer.error_code_of_wire code with
    | Peer.Session_not_created -> "session not created"
    | Peer.Invalid_session_id -> "invalid session id"
    | Peer.Other_error kept -> "other: " ^ kept in
  check string "session not created" "session not created" (read "session not created");
  check string "invalid session id" "invalid session id" (read "invalid session id");
  List.iter (fun code -> check string ("another code is kept: " ^ code) ("other: " ^ code) (read code))
    [ "no such frame"; "unknown command"; "Session not created"; "session not created " ];
  List.iter (fun code ->
      check string ("written back: " ^ code) code (Peer.error_code_to_wire (Peer.error_code_of_wire code)))
    [ "session not created"; "invalid session id"; "no such frame"; "" ]
let test_open_tab_preserves_existing_context () =
  let created = ref false and calls = ref [] in
  let peer = peer_of (fun method_ args ->
    calls := method_ :: !calls;
    match method_ with
    | "browsingContext.getTree" -> Ok (obj ["contexts",`List (List.map
        (fun context -> obj ["context",`String context])
        (if !created then ["existing";"new"] else ["existing"]))])
    | "browsingContext.create" ->
      check bool "new tab starts in background" true Yojson.Safe.Util.(args |> member "background" |> to_bool);
      created := true; Ok (obj ["context",`String "new"])
    | "browsingContext.navigate" ->
      check string "only new context is navigated" "new" Yojson.Safe.Util.(args |> member "context" |> to_string);
      Ok `Null
    | "script.callFunction" ->
      let context = Yojson.Safe.Util.(args |> member "target" |> member "context" |> to_string) in
      Ok (script_value (obj ["url",`String ("https://example.test/"^context);
        "title",`String context;"active",`Bool true;"text",`String context;"chars",`Int (String.length context);"truncated",`Bool false]))
    | other -> failf "unexpected new-tab command %s" other) in
  let succeeded = function Ok data -> data | Error _ -> fail "new tab failed" in
  ignore (succeeded (Peer.dispatch peer ~verb:Peer.Tabs_list (obj [])));
  let opened = succeeded (Peer.dispatch peer ~verb:Peer.Page_act
    (obj ["action",`String "open_tab";"url",`String "https://example.test/new"])) in
  check int "new context has its own stable tab ID" 2 Yojson.Safe.Util.(opened |> member "tabId" |> to_int);
  List.iter (fun (id,name) ->
    let page = succeeded (Peer.dispatch peer ~verb:Peer.Page_read (obj ["tabId",`Int id])) in
    check string "reads stay with the requested context" name Yojson.Safe.Util.(page |> member "text" |> to_string))
    [1,"existing";2,"new"];
  check int "one creation" 1 (List.length (List.filter (String.equal "browsingContext.create") !calls))

let test_open_tab_failure_does_not_replay () =
  let input = obj ["action",`String "open_tab";"url",`String "https://example.test/new"] in
  let refused = Peer.Rejected (Peer.error_code_of_wire "unsupported operation") in
  List.iter (fun failure ->
    let calls = ref [] in
    let peer = peer_of (fun method_ _ -> calls := method_ :: !calls; Error failure) in
    (match Peer.dispatch peer ~verb:Peer.Page_act input,failure with
     | Error (Peer.Before_effect _), (Peer.Rejected _ | Peer.Unsent _)
     | Error (Peer.Outcome_unknown _), Peer.Unanswered _ -> ()
     | (Ok _ | Error (Peer.Partial_failure _)), (Peer.Rejected _ | Peer.Unsent _ | Peer.Unanswered _)
     | Error (Peer.Before_effect _), Peer.Unanswered _
     | Error (Peer.Outcome_unknown _), (Peer.Rejected _ | Peer.Unsent _) ->
       fail "incorrect create failure effect boundary");
    check (list string) "creation is never replayed" ["browsingContext.create"] !calls)
    [refused;Peer.Unsent "closed";Peer.Unanswered "lost reply"];
  List.iter (fun (name,failed_command,reply) ->
    let calls = ref [] and failed = ref false in
    let peer = peer_of (fun method_ _ ->
      calls := method_ :: !calls;
      if String.equal method_ failed_command && not !failed then (failed := true; reply)
      else match method_ with
      | "browsingContext.create" -> Ok (obj ["context",`String "created"])
      | "browsingContext.navigate" -> Ok `Null
      | "browsingContext.getTree" -> Ok (obj ["contexts",`List [obj ["context",`String "created"]]])
      | "script.callFunction" -> Ok (script_value (obj ["url",`String "https://example.test/new";
          "title",`String "created";"active",`Bool true;"text",`String "created";
          "chars",`Int 7;"truncated",`Bool false]))
      | other -> failf "post-failure command %s" other) in
    let id = match Peer.dispatch peer ~verb:Peer.Page_act input with
      | Error (Peer.Partial_failure {tab_id;_}) -> tab_id
      | Ok _ | Error (Peer.Before_effect _ | Peer.Outcome_unknown _) -> failf "%s did not retain a known-created tab" name in
    (match Peer.dispatch peer ~verb:Peer.Tabs_list (obj []) with
     | Ok _ -> () | Error _ -> failf "%s prevented listing on the same connection" name);
    (match Peer.dispatch peer ~verb:Peer.Page_read (obj ["tabId",`Int id]) with
     | Ok data -> check string "created tab can still be read" "created" Yojson.Safe.Util.(data |> member "text" |> to_string)
     | Error _ -> failf "%s prevented recovery read on the same connection" name);
    check int "no second create after partial failure" 1
      (List.length (List.filter (String.equal "browsingContext.create") !calls));
    check bool "no close after partial failure" false (List.mem "browsingContext.close" !calls))
    ["navigation rejected","browsingContext.navigate",Error refused;
     "metadata rejected","script.callFunction",Error refused;
     "metadata script failed","script.callFunction",Ok (obj ["type",`String "exception"]);
     "metadata malformed","script.callFunction",Ok (script_value `Null)];
  List.iter (fun refusal -> List.iter (fun failed_command ->
    let calls = ref [] in
    let peer = peer_of (fun method_ _ -> calls := method_ :: !calls;
      if String.equal method_ failed_command then Error refusal
      else match method_ with
      | "browsingContext.create" -> Ok (obj ["context",`String "created"])
      | "browsingContext.navigate" -> Ok `Null
      | other -> failf "unexpected lost-connection command %s" other) in
    (match Peer.dispatch peer ~verb:Peer.Page_act input with
     | Error (Peer.Outcome_unknown _) -> ()
     | Ok _ | Error (Peer.Before_effect _ | Peer.Partial_failure _) -> fail "lost connection after creation must remain terminal/unknown");
    check int "lost connection does not replay creation" 1
      (List.length (List.filter (String.equal "browsingContext.create") !calls)))
    ["browsingContext.navigate";"script.callFunction"])
    [Peer.Unanswered "lost reply";Peer.Unsent "closed";
     Peer.Rejected (Peer.error_code_of_wire "invalid session id")]

let test_live_act_rejects_other_actions_before_effect () =
  let peer = peer_of (fun _ _ -> fail "invalid live action reached browser") in
  List.iter (fun args -> match Peer.dispatch peer ~verb:Peer.Page_act args with
    | Error (Peer.Before_effect _) -> () | Ok _ | Error (Peer.Partial_failure _ | Peer.Outcome_unknown _) -> fail "invalid action was not refused before input")
    [obj ["action",`String "close_tab";"tabId",`Int 1];
     obj ["action",`String "open_tab";"url",`String "about:newtab"];
     obj ["action",`String "open_tab";"url",`String "javascript:alert(1)"]]

let () = run "BiDi live peer" ["identity",[test_case "native keyboard release and uncertainty" `Quick test_native_keyboard_release_and_failure;
    test_case "owned endpoint identity and uncertain shutdown" `Quick test_owned_endpoint_identity_and_shutdown;
      test_case "opaque contexts" `Quick test_context_identity;
    test_case "one unreadable tab leaves other tabs visible" `Quick test_unreadable_tab_does_not_hide_other_tabs;
    test_case "implicit read skips an unreadable tab" `Quick test_active_tab_after_unreadable_tab;
    test_case "an error code is read once and written back" `Quick test_an_error_code_is_read_once_and_written_back;
    test_case "a session runs the expected profile" `Quick test_a_session_runs_the_expected_profile];
  "lifetime",[test_case "normal callback closes held socket" `Quick (test_held_open_completion (Ok ()) );
    test_case "error callback closes held socket" `Quick (test_held_open_completion (Error "owned failure"));
    test_case "a refused upgrade is the connection's error" `Quick test_refused_upgrade_is_the_connections_error;
    test_case "a closed socket ends the connection for its holder" `Quick test_a_closed_socket_ends_the_connection;
    test_case "the session is ended after a command got no reply" `Quick
      test_the_session_is_ended_after_a_command_got_no_reply;
    test_case "a session that cannot be ended is an error" `Quick test_a_session_that_cannot_be_ended_is_an_error;
    test_case "a socket closing under session.end is told at once" `Quick
      test_a_socket_closing_under_session_end_is_told_at_once;
    test_case "why a session was not ended says whether Firefox could be asked" `Quick
      test_why_a_session_was_not_ended_says_whether_firefox_could_be_asked;
    test_case "a session nobody confirmed is ended" `Quick test_a_session_nobody_confirmed_is_ended;
    test_case "a refused session leaves none to end" `Quick test_a_refused_session_leaves_none_to_end;
    test_case "a session refused for another reason is a failed one" `Quick
      test_a_session_refused_for_another_reason_is_a_failed_one;
    test_case "an unreadable refusal leaves a session to end" `Quick
      test_an_unreadable_refusal_leaves_a_session_to_end;
    test_case "a session is there to end once asked for" `Quick test_a_session_is_there_to_end_once_asked_for;
    test_case "close frame ends a pending command" `Quick test_peer_close_frame_ends_a_pending_command;
    test_case "malformed JSON ends a pending command" `Quick test_malformed_json_ends_a_pending_command;
    test_case "invalid websocket frame reaches the error path" `Quick test_invalid_websocket_frame_ends_a_pending_command];
  "effect",[test_case "set_viewport sends the size, or null to restore it" `Quick test_set_viewport_sends_the_size_or_clears_it;
    test_case "tabs name their window" `Quick test_tabs_name_their_window;
    test_case "ending the session restores a sized tab" `Quick test_ending_the_session_restores_a_sized_tab;
    test_case "a tab the caller restored is not restored again" `Quick test_a_tab_restored_by_the_caller_is_not_restored_again;
    test_case "history and close act only on tabs this connection opened" `Quick test_history_and_close_act_only_on_tabs_this_connection_opened;
    test_case "open tab preserves existing context" `Quick test_open_tab_preserves_existing_context;
    test_case "open tab failure does not replay" `Quick test_open_tab_failure_does_not_replay;
    test_case "live act rejects other actions" `Quick test_live_act_rejects_other_actions_before_effect;
    test_case "semantic clicks use trusted native input" `Quick test_semantic_click_uses_native_input;
    test_case "hover moves without clicking" `Quick test_hover_without_click; test_case "element inventory is the shared page script" `Quick test_element_inventory;
    test_case "capture retains URL and document/viewport guards" `Quick test_capture_guards;
    test_case "document source is the shared document helper" `Quick test_document_source;
    test_case "a document still loading is not answered for" `Quick test_document_still_loading;
    test_case "an answer too large for the socket is refused in the page" `Quick test_answer_too_large_for_the_socket; test_case "parsed pointer boundary" `Quick test_pointer_validation;
    test_case "the peer serves what the lane table says" `Quick test_peer_serves_what_the_lane_table_says]]
