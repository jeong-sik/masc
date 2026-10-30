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
let hover = B.Page_interact {frame_path=[];tab_id=7;expected_url=Some "https://example.org/";
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
  let automation fields=`Assoc (("lane",`String "automation")::fields) in
  ignore (ok (Hooks.before_call hooks (automation ["command",B.verb_json B.Tabs_list])));
  check bool "command fields stay closed" true
    (Result.is_error (Hooks.before_call hooks (automation ["command",`Assoc [
      "verb",`String "tabs.list";"args",`Assoc [];"other",`Bool true]])));
  (* The host chooses the browser, so the worker takes neither an automatic
     choice nor the actions a choice must cover. *)
  check bool "the worker needs the lane the host chose" true
    (Result.is_error (Hooks.before_call hooks (`Assoc ["command",B.verb_json B.Tabs_list])));
  check bool "the worker takes no requiredActions" true
    (Result.is_error (Hooks.before_call hooks (automation ["requiredActions",`List [`String "hover"];
      "command",B.verb_json B.Tabs_list])));
  check bool "open args still require an object" true
    (Result.is_error (Hooks.before_call hooks (automation ["command",`Assoc [
      "verb",`String "page.read";"args",`List []]])));
  check bool "nested duplicate JSON fields stay invalid" true
    (Result.is_error (Hooks.before_call hooks (automation ["command",`Assoc [
      "verb",`String "page.read";"args",`Assoc ["tabId",`Int 7;"tabId",`Int 8]]])));
  let no_hooks=ok (Hooks.prepare ~hooks:[] Tool.definition) in
  ignore (ok (Hooks.before_call no_hooks closed_extra));
  let reply payload : Mcp_protocol.Mcp_types.tool_result =
    {content=[];is_error=Some false;_meta=None;structured_content=Some (`Assoc [
      "reply",`String "issue";"answer",`Assoc ["status",`String "answered";"payload",payload]])} in
  ignore (ok (Hooks.after_call hooks (reply (`Assoc ["ok",`Bool true;
    "data",`Assoc ["arbitrary_browser_result",`List [`String "kept"]]]))));
  check bool "successful output must affirm ok" true
    (Result.is_error (Hooks.after_call hooks (reply (`Assoc ["ok",`Bool false]))));
  let closed=`Assoc ["type",`String "object";"properties",`Assoc [];
    "additionalProperties",`Bool false] in
  check bool "closed fieldless contract is unchanged" true
    (Result.is_error (Masc.Lane_addon_action.validate_value ~schema:closed ~name:"closed" (`Assoc ["x",`Int 1])))
let control_identity ~sw ~owner =
    let client_id=ok (B.client_id_of_string "0b000000-0000-4000-8000-000000000097") in
    let arguments verb = `Assoc ["lane",`String "live";
      "clientId",`String (B.client_id_to_string client_id);"command",B.verb_json verb] in
    let send command=Owner.dispatch owner {W.incarnation;command} in
    let client={B.client_id;browser=B.Ego_lite;version="test";engine_version="test";
      transport=B.Ego_task_space;space=Some ({id=51;name="fixture Space"} : Browser_lane.ego_space)} in
    let poll ()=Eio.Fiber.fork_promise ~sw (fun () -> send (W.Poll {client;window_sec=2.})) in
    let first_poll=poll () in
    let rec registered ()=
      if not (List.exists (fun (seen : B.client_info) -> seen.client_id=client_id) (B.connected_clients ()))
      then (Eio.Fiber.yield ();registered ()) in
    registered ();
    List.iteri (fun index control ->
      let verb=B.Page_act (B.Action.Control control) in
      List.iter (fun (label,selection) ->
        let input=`Assoc (selection @ ["command",B.verb_json verb]) in
        let expected=match Tool.command input with
          | Error message -> message
          | Ok _ -> fail (label ^ ": control reached selection without an observed client") in
        let result=Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester") input in
        check (option bool) (label ^ ": authenticated control is refused") (Some true) result.is_error;
        check bool (label ^ ": refusal is proven before effect") true
          (Lane_addon_tool_result.failure result=
            (Tool_result.Workflow_rejection,Tool_result.Proven_pre_effect));
        check (option string) (label ^ ": invocation preserves the parse-boundary refusal") (Some expected)
          (Option.bind result.structured_content (fun data ->
            match Yojson.Safe.Util.member "message" data with
            | `String message -> Some message | _ -> None)))
        ["automatic",[];"unnamed live",["lane",`String "live"];
         "automation",["lane",`String "automation"];"stagehand",["lane",`String "stagehand"]];
      check bool "the named host-selected client admits control" true
        (ok (Tool.command (arguments verb))=(B.Live_route (Some client_id),verb));
      check bool "a worker route still requires its lane" true
        (Result.is_error (Tool.command (`Assoc ["clientId",`String (B.client_id_to_string client_id);
          "command",B.verb_json verb])));
      let polled=if index=0 then first_poll else poll () in
      let pending=Eio.Fiber.fork_promise ~sw (fun () ->
        Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester") (arguments verb)) in
      let issued=match Eio.Promise.await_exn polled with
        | W.Poll_result {command=Some command;_} -> command
        | _ -> fail "expected explicitly selected ego control" in
      check string "only the explicitly selected control reaches the browser"
        (Yojson.Safe.to_string (B.verb_json verb))
        (Yojson.Safe.to_string (match issued.verb_json with
          | `Assoc fields -> `Assoc (List.remove_assoc "actor" fields)
          | value -> value));
      check bool "control receipt delivered" true
        (send (W.Deliver {client_id;id=issued.id;payload=`Assoc ["ok",`Bool true;
          "data",`Assoc ["ownership",`String (match control with
            | B.Action.Hand_off -> "operator" | Take_over | Space_status | Finish_space _ | Wait_for_control _ | Adopt_tab _ | Release_tab _ -> "agent")]]})=W.Receipt);
      check (option bool) "explicit ego control succeeds" (Some false)
        (Eio.Promise.await_exn pending).is_error)
      [B.Action.Hand_off;Take_over;Wait_for_control {interval_ms=None;timeout_ms=None};
       Adopt_tab {tab_id=7;label=Some "login"};Release_tab 7];
    check bool "refused controls never entered the browser queue" true
      (match send (W.Poll {client;window_sec=0.001}) with
       | W.Poll_result {command=None;_} -> true | _ -> false)

let scenario () = Eio_main.run (fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
    let owner=ok (Owner.create ~incarnation) in
    Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
    let send command=Owner.dispatch owner {W.incarnation;command} in
    let client={B.client_id;browser=B.Firefox;version="158";engine_version="158";transport=B.Webdriver_bidi;space=None} in
    let poll=Eio.Fiber.fork_promise ~sw (fun () -> send (W.Poll {client;window_sec=2.})) in
    let rec registered ()=if B.connected_clients ()=[] then (Eio.Fiber.yield ();registered ()) in
    registered ();
    let anonymous=Tool.invoke ~owner ~principal:Context.Anonymous (arguments hover) in
    check (option bool) "direct model call cannot impersonate host" (Some true) anonymous.is_error;
    let unnamed=Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester")
      (`Assoc ["lane",`String "live";"command",B.verb_json (B.Page_act (B.Action.Open_tab "https://example.org/"))]) in
    check (option bool) "a live route names the client the host chose" (Some true) unnamed.is_error;
    let automatic=Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester")
      (`Assoc ["command",B.verb_json B.Tabs_list]) in
    check (option bool) "the worker makes no automatic choice" (Some true) automatic.is_error;
    let other_client=ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000009") in
    let absent=Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester")
      (`Assoc ["lane",`String "live";"clientId",`String (B.client_id_to_string other_client);
        "command",B.verb_json B.Tabs_list]) in
    check bool "a client not connected here is refused before dispatch" true
      (absent.is_error=Some true
       && Lane_addon_tool_result.failure absent=(Tool_result.Workflow_rejection,Tool_result.Proven_pre_effect));
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
    check bool "the worker states no browser identity; the host adds it" true
      (match result.structured_content with
       | Some (`Assoc fields) -> not (List.mem_assoc "browserSelection" fields || List.mem_assoc "browserConnection" fields)
       | None|Some _ -> false);
    let binding=Masc.Browser_binding.of_browser
      {Masc.Browser_selection.route=B.Live_route (Some client_id);reason=Masc.Browser_selection.Explicit_browser}
      (Masc.Browser_selection.Connected client) in
    let projected=Masc.Browser_binding.annotate binding (`Assoc [
      "clientId",`String "forged";"clientId",`String "forged-again";
      "transport",`String "web_extension";"lane",`String "automation"]) in
    check string "page fields cannot forge the admitted client" (B.client_id_to_string client_id)
      Yojson.Safe.Util.(projected |> member "clientId" |> to_string);
    check string "page fields cannot forge its transport" "webdriver_bidi"
      Yojson.Safe.Util.(projected |> member "transport" |> to_string);
    check (option bool) "partial is a failed call" (Some true) result.is_error;
    check bool "partial payload is retained" true
      (Option.exists (fun data -> Yojson.Safe.Util.(data |> member "answer" |> member "payload")=payload)
        result.structured_content);
    check bool "partial metadata forbids pre-effect replay" true
      (Lane_addon_tool_result.failure result=(Tool_result.Workflow_rejection,Tool_result.Proven_post_effect));
    let no_more=send (W.Poll {client;window_sec=0.001}) in
    check bool "anonymous and partial calls have no hidden replay" true
      (match no_more with W.Poll_result {command=None;_} -> true | _ -> false);
    List.iter (fun (label,phase,expected) ->
      let read=B.Page_read {tab_id=Some 7;max_chars=Some 12000} in
      let pending=Eio.Fiber.fork_promise ~sw (fun () ->
        Tool.invoke ~owner ~principal:(Context.Keeper "browser-tester") (arguments read)) in
      let issued=match send (W.Poll {client;window_sec=2.}) with
        | W.Poll_result {command=Some command;_} -> command
        | _ -> fail "expected one dispatched browser read" in
      let payload=`Assoc (["ok",`Bool false;"error",`String label;
        "data",`Assoc ["retained_evidence",`Bool true]] @
        Option.to_list (Option.map (fun value -> "effectPhase",`String value) phase)) in
      check bool (label ^ ": original read receipt delivered") true
        (send (W.Deliver {client_id;id=issued.id;payload})=W.Receipt);
      let result=Eio.Promise.await_exn pending in
      check (option bool) (label ^ ": read remains failed") (Some true) result.is_error;
      check bool (label ^ ": original read payload retained") true
        (Option.exists (fun data -> Yojson.Safe.Util.(data |> member "answer" |> member "payload")=payload)
          result.structured_content);
      check bool (label ^ ": read retains receipt effect disposition") true
        (Lane_addon_tool_result.failure result=(Tool_result.Workflow_rejection,expected)))
      ["partial read",Some "partial",Tool_result.Proven_post_effect;
       "uncertain read",None,Tool_result.Effect_outcome_unknown;
       "unstarted read",Some "not_started",Tool_result.Proven_pre_effect];
    check bool "failed reads are not silently replayed" true
      (match send (W.Poll {client;window_sec=0.001}) with
       | W.Poll_result {command=None;_} -> true | _ -> false);
    control_identity ~sw ~owner)))
let ()=run "browser addon exported tool" ["contract",[
  test_case "selected hooks accept rich arguments and preserve closed boundaries" `Quick hook_contract];
  "execution",[test_case "caller running observation and partial receipt" `Quick scenario]]
