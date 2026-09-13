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
let () = run "BiDi live peer" ["identity",[test_case "opaque contexts" `Quick test_context_identity];
  "effect",[test_case "closed verbs" `Quick test_unsupported; test_case "parsed pointer boundary" `Quick test_pointer_validation]]
