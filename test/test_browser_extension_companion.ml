(** The real companion adapter on a fake CDP transport. No browser or provider
    runs here; provider program behavior is covered by the Node fixtures. *)
open Alcotest
open Masc
module C=Browser_cdp
module B=Browser_stagehand_backend
module P=Browser_extension_protocol
module W=Browser_stagehand_wire
module L=Browser_lane
let answered = function
  | L.Answered (`Assoc fields)
      when List.sort String.compare (List.map fst fields)=["data";"ok"] ->
      (match List.assoc "ok" fields with
       | `Bool true -> List.assoc "data" fields
       | _ -> fail "fixture browser lifecycle did not succeed")
  | L.Answered _ -> fail "fixture browser lifecycle returned an invalid envelope"
  | Rejected_before_effect _ | Lane_absent | Timed_out | Refused _ -> fail "fixture browser lifecycle refused"
let operation_id="0b000000-0000-4000-8000-000000000019"
let extension_id=String.make 32 'a'
let url="https://example.org/login"
let page=`Assoc ["page_id",`String "cdp-page-9";"url",`String url]
let scenario () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let transport=ref None and sent=ref [] and private_calls=ref 0 and summaries=ref 0 in
  let get ()=match !transport with Some cdp -> cdp | None -> fail "CDP not created" in
  let send frame =
    let value=Yojson.Safe.from_string frame in
    sent:=value::!sent;
    let field key=Yojson.Safe.Util.member key value in
    let method_=field "method" and session=field "sessionId" in
    let result=match method_ with
      | `String "Target.getTargetInfo" -> `Assoc ["targetInfo",`Assoc [
          "targetId",`String "cdp-page-9";"type",`String "page";"url",`String url]]
      | `String "Target.setDiscoverTargets" -> `Assoc []
      | `String "Target.getTargets" -> `Assoc ["targetInfos",`List [
          `Assoc ["targetId",`String "wrong-worker";"type",`String "service_worker";
            "url",`String ("chrome-extension://" ^ String.make 32 'b' ^ "/worker.js")];
          `Assoc ["targetId",`String "exact-worker";"type",`String "service_worker";
            "url",`String ("chrome-extension://" ^ extension_id ^ "/background.js")]]]
      | `String "Extensions.loadUnpacked" -> `Assoc ["id",`String extension_id]
      | `String "Target.attachToTarget" ->
          check string "only the exact extension worker is attached" "exact-worker"
            Yojson.Safe.Util.(value |> member "params" |> member "targetId" |> to_string);
          `Assoc ["sessionId",`String "companion-session"]
      | `String "Runtime.evaluate" ->
          let result=match session with
            | `String "stagehand-session" -> `Assoc ["tab_id",`Int 57;"url",`String url]
            | `String "companion-session" ->
                incr private_calls;
                if !private_calls=1 then `Assoc ["ready",`Bool true]
                else `Assoc ["reference",`String "PRIVATE_REFERENCE_MARKER"]
            | _ -> fail "evaluation escaped the original attached workers" in
          `Assoc ["result",`Assoc ["value",result]]
      | _ -> fail "unexpected private Chrome command" in
    C.receive (get ()) (Yojson.Safe.to_string (`Assoc ["id",field "id";"result",result])) in
  let cdp=C.create ~send ~close:ignore ~clock:(Eio.Stdenv.clock env) ~command_deadline_s:5. ~on_event:ignore in
  transport:=Some cdp;
  let backend=B.create ~sw ~clock:(Eio.Stdenv.clock env) ~open_session:(fun ~sw:_ ~headless:_ ~log:_ ->
      Ok (cdp,`Assoc ["pages",`List [page]]))
    ~call:(fun _ -> function
      | W.Context_pages -> Ok (`List [page])
      | W.Context_active_page -> Ok page
      | W.Page_evaluate {page_id;expression=_} ->
          check string "public summary belongs to the original page" "cdp-page-9" page_id;
          incr summaries;
          Ok (`Assoc ["value",`String (Yojson.Safe.to_string (`Assoc ["url",`String url;
            "title",`String "Login";"viewport",`Null]))])
      | W.Close -> Ok (`Assoc ["closed",`Bool true])
      | _ -> fail "unexpected public Stagehand command")
    ~private_ready:(fun _ -> true) ~shutdown:(fun _ -> Ok ()) ~pid:(fun _ -> 42) ~log:ignore in
  let opened=B.execute backend (L.Session_open {headless=Some true}) |> answered in
  check bool "original Browser actually opened" true (Yojson.Safe.Util.member "opened" opened=`Bool true);
  let listed=B.execute backend L.Tabs_list |> answered in
  let tab_id=match listed with
    | `List [tab] -> (match Yojson.Safe.Util.member "id" tab with
        | `Int id when id>=0 -> id | _ -> fail "listed original tab has no identity")
    | _ -> fail "fixture did not list its original page" in
  check int "original tab summary completed before private admission" 1 !summaries;
  let companion=Browser_extension_companion.create ~sw ~backend
    ~transport:(fun original run ->
      check bool "original CDP object is retained" true (original==cdp);
      run original ~worker:"stagehand-session") in
  let directory=Unix.realpath (Filename.get_temp_dir_name ()) in
  let prepare=P.Prepare {operation_id;tab_id;extension_id;directory;
    program="async()=>({ready:true})";arguments=`Assoc []} in
  check bool "prepared only after exact worker initialization" true
    (companion prepare=Ok (`Assoc ["prepared",`Bool true]));
  check bool "same operation identity is never rebound" true (companion prepare=Error P.Not_started);
  let invoke=P.Invoke {operation_id;program="async()=>({reference:'private'})";arguments=`Assoc []} in
  check bool "private value returns only through companion result" true
    (companion invoke=Ok (`Assoc ["reference",`String "PRIVATE_REFERENCE_MARKER"]));
  check int "one setup and one explicit invocation" 2 !private_calls;
  check int "only one extension load on the original transport" 1
    (List.length (List.filter (fun value -> Yojson.Safe.Util.member "method" value=`String "Extensions.loadUnpacked") !sent));
  let destroyed target_id=C.receive cdp (Yojson.Safe.to_string (`Assoc [
    "method",`String "Target.targetDestroyed";"params",`Assoc ["targetId",`String target_id]])) in
  destroyed "wrong-worker";
  check bool "another extension's loss does not fence the pinned session" true
    (Result.is_ok (B.capture_private_session backend));
  destroyed "exact-worker";
  check bool "exact worker loss fences ordinary page observation" true
    (match B.execute backend L.Tabs_list with
     | L.Rejected_before_effect _ -> true
     | Answered _|Lane_absent|Timed_out|Refused _ -> false);
  check int "fenced tab read never reaches public evaluation" 1 !summaries;
  check bool "original private operation cannot follow another worker" true
    (companion invoke=Error P.Outcome_unknown);
  check int "worker loss never replays private code" 2 !private_calls;
  let closed=B.execute backend L.Session_close |> answered in
  check bool "original Browser shutdown confirmed" true (Yojson.Safe.Util.member "closed" closed=`Bool true);
  let reopened=B.execute backend (L.Session_open {headless=Some true}) |> answered in
  check bool "replacement Browser actually opened" true (Yojson.Safe.Util.member "opened" reopened=`Bool true);
  check bool "old operation cannot follow a reopened browser" true (companion invoke=Error P.Not_started);
  check bool "release settles only the original binding" true
    (companion (P.Release operation_id)=Ok (`Assoc ["released",`Bool true]));
  check bool "released identity remains a tombstone" true (companion prepare=Error P.Not_started)))
let ()=run "private extension companion" ["original owner",[
  test_case "exact worker binding privacy loss and no replay" `Quick scenario]]
