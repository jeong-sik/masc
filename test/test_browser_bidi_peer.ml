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
  let ids () = match Peer.dispatch peer ~verb:"tabs.list" (obj []) with
    | Ok (`List rows) -> List.map (fun row->Yojson.Safe.Util.(row |> member "id" |> to_int)) rows
    | _ -> fail "tabs failed" in
  check (list int) "same URL does not merge opaque contexts" [1;2] (ids ());
  contexts:=["b"];check (list int) "remaining context keeps identity" [2] (ids ());
  contexts:=["b";"c"];check (list int) "closed context ID never reused" [2;3] (ids ())
let test_unsupported () =
  let called=ref false in
  let peer=Peer.create ~command:(fun _ _->called:=true;Error "unexpected") in
  (match Peer.dispatch peer ~verb:"page.arbitrary" (obj []) with
   | Error (Peer.Before_effect _) -> () | _ -> fail "unsupported verb must be pre-effect");
  check bool "no protocol dispatch" false !called
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
    (match Peer.dispatch peer ~verb:"page.interact" (obj (base @ fields)) with
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
let () = run "BiDi live peer" ["identity",[test_case "opaque contexts" `Quick test_context_identity];
  "lifetime",[test_case "normal callback closes held socket" `Quick (test_held_open_completion (Ok ()) );
    test_case "error callback closes held socket" `Quick (test_held_open_completion (Error "owned failure"))];
  "effect",[test_case "closed verbs" `Quick test_unsupported; test_case "parsed pointer boundary" `Quick test_pointer_validation]]
