open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
module Tool = Masc.Browser_addon_tool
module Hooks = Masc.Lane_addon_tool_hooks
module Context = Lane_addon_call_context
let ok = function Ok value -> value | Error message -> fail message
let incarnation = "0b000000-0000-4000-8000-000000000001"
let client_id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000001")
let arguments verb = `Assoc ["lane",`String "live";
  "clientId",`String (B.client_id_to_string client_id);"command",B.verb_json verb]
let hover = B.Page_interact {tab_id=7;expected_url=Some "https://example.org/";
  action=B.Hover (B.Selector "#row")}
let hook_contract () =
  let hooks=ok (Hooks.prepare ~hooks:[Validate_input;Validate_output] Tool.definition) in
  List.iter (fun verb ->
    let input=arguments verb in
    ignore (ok (Hooks.before_call hooks input));
    ignore (ok (W.verb_of_json ~route:(B.Live_route (Some client_id))
      (Yojson.Safe.Util.member "command" input))))
    [B.Page_read {tab_id=Some 7;max_chars=Some 12000};Page_document {tab_id=7};hover];
  let closed_extra=match arguments hover with
    | `Assoc fields -> `Assoc (("actor",`String "forged")::fields) | _ -> assert false in
  check bool "selected input hook rejects undeclared identity" true
    (Result.is_error (Hooks.before_call hooks closed_extra));
  check bool "command fields stay closed" true
    (Result.is_error (Hooks.before_call hooks (`Assoc ["command",`Assoc [
      "verb",`String "tabs.list";"args",`Assoc [];"other",`Bool true]])));
  check bool "open args still require an object" true
    (Result.is_error (Hooks.before_call hooks (`Assoc ["command",`Assoc [
      "verb",`String "page.read";"args",`List []]])));
  check bool "nested duplicate JSON fields stay invalid" true
    (Result.is_error (Hooks.before_call hooks (`Assoc ["command",`Assoc [
      "verb",`String "page.read";"args",`Assoc ["tabId",`Int 7;"tabId",`Int 8]]])));
  let no_hooks=ok (Hooks.prepare ~hooks:[] Tool.definition) in
  ignore (ok (Hooks.before_call no_hooks closed_extra));
  let reply payload : Mcp_protocol.Mcp_types.tool_result =
    {content=[];is_error=Some false;_meta=None;structured_content=Some (`Assoc [
      "reply",`String "issue";"answer",`Assoc ["status",`String "answered";"payload",payload];
      "browserSelection",`Assoc ["lane",`String "live";"reason",`String "explicit_browser";
        "clientId",`String (B.client_id_to_string client_id)];
      "browserConnection",`Assoc ["clientId",`String (B.client_id_to_string client_id);
        "transport",`String "webdriver_bidi"]])} in
  ignore (ok (Hooks.after_call hooks (reply (`Assoc ["ok",`Bool true;
    "data",`Assoc ["arbitrary_browser_result",`List [`String "kept"]]]))));
  check bool "successful output must affirm ok" true
    (Result.is_error (Hooks.after_call hooks (reply (`Assoc ["ok",`Bool false]))));
  let closed=`Assoc ["type",`String "object";"properties",`Assoc [];
    "additionalProperties",`Bool false] in
  check bool "closed fieldless contract is unchanged" true
    (Result.is_error (Masc.Lane_addon_action.validate_value ~schema:closed ~name:"closed" (`Assoc ["x",`Int 1])))
let scenario () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let owner=ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    let send command=Owner.dispatch owner {W.incarnation;command} in
    let client={B.client_id;browser=B.Firefox;version="158";engine_version="158";transport=B.Webdriver_bidi} in
    let poll=Eio.Fiber.fork_promise ~sw (fun () -> send (W.Poll {client;window_sec=2.})) in
    let rec registered ()=if B.connected_clients ()=[] then (Eio.Fiber.yield ();registered ()) in
    registered ();
    let anonymous=Tool.invoke ~owner ~principal:Context.Anonymous (arguments hover) in
    check (option bool) "direct model call cannot impersonate host" (Some true) anonymous.is_error;
    let pending=Eio.Fiber.fork_promise ~sw (fun () ->
      Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester") (arguments hover)) in
    let issued=match Eio.Promise.await_exn poll with
      | W.Poll_result {command=Some command;_} -> command
      | _ -> fail "expected one dispatched browser command" in
    check (option string) "verified caller supplies actor" (Some "keeper/browser-tester")
      (match issued.verb_json with `Assoc fields -> List.assoc_opt "actor" fields
        |> Option.map Yojson.Safe.Util.to_string | _ -> None);
    let snapshot=match send W.Snapshot with W.Snapshot_result value -> value
      | _ -> fail "snapshot must arrive before command result" in
    let observation=ok (Masc.Browser_addon_observation.of_snapshot ~observed_at:(Time_compat.now ()) snapshot) in
    check bool "running snapshot arrives before result" true
      (match observation.rows with
       | [row] -> Yojson.Safe.Util.(List.assoc "clients" row.fields |> to_list |> List.hd
           |> member "interactions" |> to_list |> List.hd |> member "phase")=`String "running"
       | _ -> false);
    let payload=`Assoc ["ok",`Bool false;"effectPhase",`String "partial";
      "data",`Assoc ["created_tab_ids",`List [`Int 9]];"error",`String "partial failure"] in
    check bool "result accepted while tool waits" true
      (send (W.Deliver {client_id;id=issued.id;payload})=W.Receipt);
    let result=Eio.Promise.await_exn pending in
    let binding=match result.structured_content with
      | Some (`Assoc fields) -> ok (Masc.Browser_binding.of_json (`Assoc
          (List.filter (fun (key,_) -> List.mem key ["browserSelection";"browserConnection"]) fields)))
      | None|Some _ -> fail "receipt must retain its connection" in
    let projected=Masc.Browser_binding.annotate binding (`Assoc [
      "clientId",`String "forged";"clientId",`String "forged-again";
      "transport",`String "web_extension";"lane",`String "automation"]) in
    check string "page fields cannot forge the admitted client" (B.client_id_to_string client_id)
      Yojson.Safe.Util.(projected |> member "clientId" |> to_string);
    check string "page fields cannot forge its transport" "webdriver_bidi"
      Yojson.Safe.Util.(projected |> member "transport" |> to_string);
    check bool "receipt rejects a mismatched connection" true
      (Result.is_error (Masc.Browser_binding.of_json (`Assoc [
        "browserSelection",Masc.Browser_selection.to_json (Masc.Browser_binding.selected binding);
        "browserConnection",`Assoc ["clientId",`String "0c000000-0000-4000-8000-000000000002";
          "transport",`String "webdriver_bidi"]])));
    check (option bool) "partial is a failed call" (Some true) result.is_error;
    check bool "partial payload is retained" true
      (Option.exists (fun data -> Yojson.Safe.Util.(data |> member "answer" |> member "payload")=payload)
        result.structured_content);
    check bool "partial metadata forbids pre-effect replay" true
      (Lane_addon_tool_result.failure result=(Tool_result.Workflow_rejection,Tool_result.Proven_post_effect));
    let no_more=send (W.Poll {client;window_sec=0.001}) in
    check bool "anonymous and partial calls have no hidden replay" true
      (match no_more with W.Poll_result {command=None;_} -> true | _ -> false))))
let ()=run "browser addon exported tool" ["contract",[
  test_case "selected hooks accept rich arguments and preserve closed boundaries" `Quick hook_contract];
  "execution",[test_case "caller running observation and partial receipt" `Quick scenario]]
