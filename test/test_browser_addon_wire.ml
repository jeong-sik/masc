open Alcotest
module B = Browser_lane
module W = Masc.Browser_addon_wire
let ok = function Ok value -> value | Error message -> fail message
let id = ok (B.client_id_of_string "0c000000-0000-4000-8000-000000000001")
let route = B.Live_route (Some id)
let incarnation = "0b000000-0000-4000-8000-000000000001"
let decode verb args = W.verb_of_json ~route (`Assoc ["verb",`String verb;"args",`Assoc args])
let roundtrips () =
  let verbs = [B.Tabs_list; Page_read {tab_id=None;max_chars=None};Page_document {tab_id=7};
    Page_downloads {tab_id=7};Page_capture {tab_id=7};
    Page_scene {tab_id=7;max_chars=1000;view=B.Regions;scope=Some {document_id="doc";node_id="region"}};
    Page_interact {frame_path=[];tab_id=7;expected_url=Some "https://example.org";action=B.Fill_node {target={document_id="doc";node_id="edit"};text=""}};
    Session_open {headless=Some false};Session_close;Session_status;
    Page_goto {url="https://example.org";tab_id=Some 7};Page_elements {tab_id=Some 7;within=None};
    Page_elements {tab_id=None;within=Some "nav[aria-label=\"Channels\"] > ul"};
    Page_context {tab_id=7;frame_path=["#frame"];mode=`Elements (Some "#sidebar")};
    Page_act (B.Action.On_tab {tab_id=7;frame_path=["#frame"];interaction=B.Action.Upload {selector="#edit";paths=["/staged/a.txt"]}});
    Page_context {tab_id=7;frame_path=["#frame"];mode=`Text 1000};
    Page_instruct {tab_id=7;instruction="Open the menu"};Page_locate {tab_id=7;instruction=None};
    Page_extract {tab_id=7;instruction="Read totals";schema=Some (`Assoc ["type",`String "object"])}] in
  List.iter (fun verb ->
    let request = {W.incarnation;command=W.Issue {route;verb;actor=Some "keeper";timeout_sec=3.;only_if_idle=false}} in
    check bool (B.verb_to_string verb) true (ok (W.of_json (W.to_json request))=request)) verbs
(* A native host may poll as the extension or a BiDi host; the ego
   connection polls only from inside the worker. *)
let a_native_host_cannot_poll_as_ego () =
  let poll transport =
    let client = {B.client_id=id;browser=B.Ego_lite;version="0.6.0.16";engine_version="154.0.8037.44";transport} in
    W.of_json (W.to_json {W.incarnation;command=W.Poll {client;window_sec=1.}}) in
  check bool "ego_task_space is refused" true (Result.is_error (poll B.Ego_task_space));
  check bool "a BiDi host still polls" true (Result.is_ok (poll B.Webdriver_bidi))

let rejections () =
  check bool "nested action route cannot override selected browser" true
    (Result.is_error (decode "page.act" ["action",`String "open_tab";"url",`String "https://example.org";"lane",`String "automation"]));
  check bool "nested action client cannot conflict" true
    (Result.is_error (decode "page.act" ["action",`String "open_tab";"url",`String "https://example.org";"clientId",`String (B.client_id_to_string id)]));
  check bool "duplicate verb rejected" true (Result.is_error (W.verb_of_json ~route
    (`Assoc ["verb",`String "tabs.list";"verb",`String "tabs.list";"args",`Assoc []])));
  check bool "irrelevant read field rejected" true (Result.is_error (decode "tabs.list" ["tabId",`Int 7]));
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
     W.Receipt;W.Snapshot_result (`Assoc []);W.Model_reply (`Assoc ["requests",`List []]);W.Issue_result (Ok (B.Answered payload));
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
let () = run "browser addon wire" ["boundary",[
  test_case "closed verbs roundtrip" `Quick roundtrips;
  test_case "guards and competing identities" `Quick rejections;
  test_case "a native host cannot poll as ego" `Quick a_native_host_cannot_poll_as_ego;
  test_case "partial effects and receipts" `Quick results;
  test_case "private retirement retains incarnation" `Quick retirement;
  test_case "private model ports preserve incarnation" `Quick model_ports]]
