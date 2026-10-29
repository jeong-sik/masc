open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
let ok = function Ok value -> value | Error message -> fail message
let id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000001")
let route = B.Live_route (Some id)
let incarnation = "0b000000-0000-4000-8000-000000000001"
let decode verb args = W.verb_of_json ~route (`Assoc ["verb",`String verb;"args",`Assoc args])
let roundtrips () =
  let native=ok (B.Native_workflow.of_json (`Assoc ["tabId",`Int 7;"expectedUrl",`String "https://example.org";
    "steps",`List [`Assoc ["method",`String "waitForSelector";"selector",`String "@12";"state",`String "visible"]];"maxChars",`Int 1000])) in
  let verbs = [B.Page_native_workflow native;B.Tabs_list; Page_read {tab_id=None;max_chars=None};Page_document {tab_id=7};
    Page_downloads {tab_id=7};Page_capture {tab_id=7;options=None};
    Page_capture {tab_id=7;options=Some (ok (B.Capture.of_json (`Assoc ["fullPage",`Bool true;"raw",`Bool false])))};
    Page_scene {tab_id=7;max_chars=1000;view=B.Regions;scope=Some {document_id="doc";node_id="region"}};
    Page_snapshot {tab_id=7;max_chars=1000;scope=B.Snapshot_viewport};
    Page_snapshot {tab_id=7;max_chars=1000;scope=B.Snapshot_full_page};
    Page_snapshot {tab_id=7;max_chars=1000;scope=B.Snapshot_subtree 12};
    Page_interact {frame_path=[];tab_id=7;expected_url=Some "https://example.org";action=B.Fill_node {target={document_id="doc";node_id="edit"};text=""}};
    Session_open {headless=Some false};Session_close;Session_status;
    Page_goto {url="https://example.org";tab_id=Some 7};Page_elements {tab_id=Some 7;filter={within=None;selector=None}};
    Page_elements {tab_id=None;filter={within=Some "nav[aria-label=\"Channels\"] > ul";selector=Some "[role=row]"}};
    Page_context {tab_id=7;frame_path=["#frame"];mode=`Elements {within=Some "#sidebar";selector=None}};
    Page_act (B.Action.On_tab {tab_id=7;frame_path=["#frame"];interaction=B.Action.Upload {target=B.Action.File_input "#edit";paths=["/staged/a.txt"]}});
    Page_act (B.Action.Control B.Action.Space_status);
    Page_act (B.Action.Control (B.Action.Finish_space (B.Action.Keep_labels ["p2"])));
    Page_act (B.Action.Control (B.Action.Finish_space B.Action.Keep_all));
    Page_act (B.Action.Control (B.Action.Wait_for_control {interval_ms=Some 0.5;timeout_ms=Some 100000.}));
    Page_act (B.Action.Control (B.Action.Adopt_tab {tab_id=7;label=Some "login"}));
    Page_act (B.Action.Control (B.Action.Release_tab 7));
    Page_context {tab_id=7;frame_path=["#frame"];mode=`Text 1000};
    Page_instruct {tab_id=7;instruction="Open the menu"};Page_locate {tab_id=7;instruction=None};
    Page_extract {tab_id=7;instruction="Read totals";schema=Some (`Assoc ["type",`String "object"])}] in
  let hooks = ok (Masc.Lane_addon_tool_hooks.prepare
    ~hooks:[Validate_input] Masc.Browser_addon_tool.definition) in
  let public command = `Assoc ["lane",`String "live";
    "clientId",`String (B.client_id_to_string id);"command",command] in
  List.iter (fun verb ->
    let request = {W.incarnation;command=W.Issue {route;verb;actor=Some "keeper";timeout_sec=3.;only_if_idle=false}} in
    check bool (B.verb_to_string verb) true (ok (W.of_json (W.to_json request))=request);
    match Masc.Lane_addon_tool_hooks.before_call hooks (public (B.verb_json verb)) with
    | Ok () -> ()
    | Error detail -> failf "%s must pass the advertised input contract: %s" (B.verb_to_string verb) detail) verbs;
  check bool "the same input hook rejects an unsupported wire verb" true
    (Result.is_error (Masc.Lane_addon_tool_hooks.before_call hooks
      (public (`Assoc ["verb",`String "page.unsupported";"args",`Assoc []]))))
(* A native host may poll as the extension or a BiDi host; the ego
   connection polls only from inside the worker. *)
let a_native_host_cannot_poll_as_ego () =
  let poll transport =
    let client = {B.client_id=id;browser=B.Ego_lite;version="0.6.0.16";engine_version="154.0.8037.44";transport;space=(match transport with Browser_lane.Ego_task_space -> Some ({id=51;name="fixture Space"} : Browser_lane.ego_space) | Web_extension|Webdriver_bidi -> None)} in
    W.of_json (W.to_json {W.incarnation;command=W.Poll {client;window_sec=1.}}) in
  check bool "ego_task_space is refused" true (Result.is_error (poll B.Ego_task_space));
  check bool "a BiDi host still polls" true (Result.is_ok (poll B.Webdriver_bidi))

let rejections () =
  check bool "caller cannot choose a screenshot path" true
    (Result.is_error (decode "page.capture" ["tabId",`Int 7;"options",`Assoc ["path",`String "/tmp/caller.png"]]));
  check bool "native screenshot options cannot be null" true
    (Result.is_error (decode "page.capture" ["tabId",`Int 7;"options",`Null]));
  check bool "unknown lifecycle fields stay closed" true
    (Result.is_error (decode "page.act" ["action",`String "adopt_tab";"tabId",`Int 7;"force",`Bool true]));
  check bool "duplicate lifecycle options stay closed" true
    (Result.is_error (decode "page.act" ["action",`String "wait_for_control";
      "controlOptions",`Assoc ["timeout",`Int 1;"timeout",`Int 2]]));
  check bool "nested action route cannot override selected browser" true
    (Result.is_error (decode "page.act" ["action",`String "open_tab";"url",`String "https://example.org";"lane",`String "automation"]));
  check bool "nested action client cannot conflict" true
    (Result.is_error (decode "page.act" ["action",`String "open_tab";"url",`String "https://example.org";"clientId",`String (B.client_id_to_string id)]));
  check bool "duplicate verb rejected" true (Result.is_error (W.verb_of_json ~route
    (`Assoc ["verb",`String "tabs.list";"verb",`String "tabs.list";"args",`Assoc []])));
  check bool "irrelevant read field rejected" true (Result.is_error (decode "tabs.list" ["tabId",`Int 7]));
  let snapshot fields = decode "page.snapshot" (["tabId",`Int 7;"maxChars",`Int 1000] @ fields) in
  check bool "a subtree snapshot needs its root" true (Result.is_error (snapshot ["scope",`String "subtree"]));
  check bool "a snapshot root is a ref" true
    (Result.is_error (snapshot ["scope",`String "subtree";"root",`String "12"]));
  check bool "a viewport snapshot has no root" true
    (Result.is_error (snapshot ["scope",`String "viewport";"root",`String "@12"]));
  check bool "ref=N names the same root as @N" true
    (snapshot ["scope",`String "subtree";"root",`String "ref=12"]
     = Ok (B.Page_snapshot {tab_id=7;max_chars=1000;scope=B.Snapshot_subtree 12}));
  check bool "empty within is not a scope" true
    (Result.is_error (decode "page.elements" ["tabId",`Int 7;"within",`String ""]));
  check bool "within scopes elements only" true (Result.is_error (decode "page.context"
    ["tabId",`Int 7;"framePath",`List [];"mode",`String "frames";"within",`String "#sidebar"]));
  check bool "pointer needs observed viewport" true (Result.is_error (decode "page.interact"
    ["tabId",`Int 7;"action",`String "hover_at";"point",`Assoc ["x",`Float 0.5;"y",`Float 0.5]]));
  check bool "native input needs expected document" true (Result.is_error (decode "page.interact"
    ["tabId",`Int 7;"action",`String "type_text";"text",`String "hello"]));
  check bool "idle cannot admit input" true (Result.is_error (W.of_json (W.to_json
    {W.incarnation;command=W.Issue {route;verb=B.Page_act (B.Action.Open_tab "https://example.org");actor=None;timeout_sec=3.;only_if_idle=true}})))
let results () =
  let payload = `Assoc ["ok",`Bool false;"effectPhase",`String "partial";
    "data",`Assoc ["created_tab_ids",`List [`Int 9]];"error",`String "partial failure"] in
  List.iter (fun answer -> check bool "answer disposition retained" true
    (ok (W.answer_of_json (W.answer_to_json answer))=answer))
    [Ok (B.Answered payload);Ok B.Lane_absent;Ok B.Timed_out;Ok (B.Refused "unknown outcome");
     Ok (B.Rejected_before_effect "guard failed");Error (B.Selected_client_disconnected id);
     Error (B.Activity_rejected (B.Lane_off B.Lane_name.Live));Error (B.Activity_rejected B.Activity_unavailable);
     Error B.No_live_client;Error (B.Ambiguous_clients [id]);
     Error (B.Transport_unsupported {client_id=id;transport=B.Web_extension;capability=B.Trusted_hover})];
  List.iter (fun reply -> check bool "service reply retained" true
    (ok (W.reply_of_json (W.reply_to_json reply))=reply))
    [W.Poll_result {command=None;state_id="snapshot-1"};
     W.Poll_result {command=Some {B.id="command";verb_json=B.verb_json B.Tabs_list};state_id="snapshot-2"};
     W.Receipt;W.Snapshot_result (`Assoc []);W.Model_reply (`Assoc ["requests",`List []]);
     W.Extension_reply (`Assoc ["private_reference",`String "opaque"]);W.Issue_result (Ok (B.Answered payload));
     W.Service_refusal {message="retired";disposition=W.Outcome_unknown}]
let retirement () =
  let request={W.incarnation;command=W.Retire} in
  check bool "private retirement retains incarnation" true (W.of_json (W.to_json request)=Ok request)
let model_ports () =
  List.iter (fun command -> let request={W.incarnation;command} in
    check bool "private model port retains exact incarnation and payload" true
      (W.of_json (W.to_json request)=Ok request))
    [W.Model_requests;W.Model_result (`Assoc ["request_id",`String "one";"result",`Assoc []]);
     W.Model_wait {after=None};W.Model_wait {after=Some "revision"}]
(* A read the host makes before it chooses a browser must not decide the
   worker's lifetime; a browser command that may have started must. *)
let commands_that_change_nothing () =
  let issue only_if_idle=W.Issue {route;verb=B.Page_document {tab_id=7};actor=None;timeout_sec=3.;only_if_idle} in
  List.iter (fun (name,command,expected) -> check bool name expected (W.changes_nothing command))
    ["snapshot",W.Snapshot,true;"model listing",W.Model_requests,true;"model wait",W.Model_wait {after=None},true;
     "idle document read",issue true,true;"browser command",issue false,false;"retire",W.Retire,false;
     "native poll",W.Poll {client={B.client_id=id;browser=B.Firefox;version="158";engine_version="158";transport=B.Webdriver_bidi;space=None};window_sec=0.},false;
     "disconnect",W.Disconnect id,false;
     "upload stage",W.Upload_stage {id="up";actor="keeper";route;verb=B.Tabs_list},false;
     "upload discard",W.Upload_discard "up",false;
     "download claim",W.Download_claim {id="dl";actor="keeper";route;verb=B.Tabs_list},false;
     "download commit",W.Download_commit {id="dl";actor="keeper";route;verb=B.Tabs_list;receipt=`Null},false;
     "download release",W.Download_release {id="dl";actor="keeper";route;verb=B.Tabs_list},false;
     "model result",W.Model_result `Null,false;
     "private extension",W.Extension (Masc.Browser_extension_protocol.Release incarnation),false;
     "native delivery",W.Deliver {client_id=id;id="cmd";payload=`Null},false]
let extension_ports () =
  let module P=Masc.Browser_extension_protocol in
  List.iter (fun command -> let request={W.incarnation;command=W.Extension command} in
    check bool "private extension preserves exact program and arguments" true
      (W.of_json (W.to_json request)=Ok request))
    [P.Prepare {operation_id=incarnation;tab_id=7;extension_id=String.make 32 'a';directory="/private/extension";
       program="async()=>({ready:true})";arguments=`Assoc []};
     P.Invoke {operation_id=incarnation;program="async context=>context.arguments";
       arguments=`Assoc ["private",`String "PRIVATE_MARKER"]}; P.Release incarnation];
  let valid=P.to_json (P.Invoke {operation_id=incarnation;program="async()=>({})";arguments=`Assoc []}) in
  let fields=match valid with `Assoc fields -> fields | _ -> fail "expected object" in
  List.iter (fun fields -> check bool "unknown duplicate and invalid arguments refuse" true
    (Result.is_error (P.of_json (`Assoc fields))))
    [("program",`String "async()=>({})")::fields;("extra",`Bool true)::fields;
     List.map (fun (key,value) -> key,if key="arguments" then `String "not-object" else value) fields]
let client_space_context () =
  let space : B.ego_space = {id=51;name="SDK Space"} in
  List.iter (fun transport ->
    let client={B.client_id=id;browser=B.Ego_lite;version="0.6.1.11";engine_version="154";
      transport;space=(if transport=B.Ego_task_space then Some space else None)} in
    let value=W.client_to_json client in
    check bool "client and Space roundtrip together" true (W.client_of_json value=Ok client);
    let fields=match value with `Assoc fields -> fields | _ -> fail "expected object" in
    List.iter (fun fields -> check bool "missing duplicate or cross-transport Space refuses" true
      (Result.is_error (W.client_of_json (`Assoc fields))))
      [List.remove_assoc "space" fields;("space",`Null)::fields;
       ("space",if transport=B.Ego_task_space then `Null else B.ego_space_to_json space)::List.remove_assoc "space" fields])
    [B.Web_extension;B.Webdriver_bidi;B.Ego_task_space]

let () = run "browser addon wire" ["boundary",[
  test_case "private client preserves strict Space context" `Quick client_space_context;
  test_case "closed verbs roundtrip" `Quick roundtrips;
  test_case "guards and competing identities" `Quick rejections;
  test_case "a native host cannot poll as ego" `Quick a_native_host_cannot_poll_as_ego;
  test_case "partial effects and receipts" `Quick results;
  test_case "private retirement retains incarnation" `Quick retirement;
  test_case "private model ports preserve incarnation" `Quick model_ports;
  test_case "private extension ports preserve authority" `Quick extension_ports;
  test_case "commands that change nothing" `Quick commands_that_change_nothing]]
