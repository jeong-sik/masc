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
  let peer=Peer.create ~command in
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
  let peer=Peer.create ~command in
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
  let peer=Peer.create ~command in
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
  let peer=Peer.create ~command in
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
          ~url:(Printf.sprintf "ws://127.0.0.1:%d/session" port) (fun _->outcome) in
        check (result unit string) "callback result preserved" outcome actual;
        check bool "socket EOF without any extra protocol write" true (Eio.Promise.await eof))))
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
          (fun _->used:=true;Ok ())
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
    let peer = Peer.create ~command in
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
    let peer = Peer.create ~command in
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
    test_case "a refused upgrade is the connection's error" `Quick test_refused_upgrade_is_the_connections_error];
  "effect",[test_case "hover moves without clicking" `Quick test_hover_without_click; test_case "element inventory is the shared page script" `Quick test_element_inventory;
    test_case "document source is the shared document helper" `Quick test_document_source; test_case "parsed pointer boundary" `Quick test_pointer_validation;
    test_case "the peer serves what the lane table says" `Quick test_peer_serves_what_the_lane_table_says]]
