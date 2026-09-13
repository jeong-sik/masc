(** Operator features use the same TOML owner as Dashboard/Keeper. This test
    exercises files and returned wire data; workers are not launched here. *)
open Alcotest
module UI = Masc_tui_lane_addons
module Draft = Masc_tui_lane_declaration
module Owner = Masc.Lane_addon_declaration
let ok = function Ok value -> value | Error message -> fail message
let owner_ok = function Ok value -> value | Error error -> fail error.Owner.message
let write path text = Out_channel.with_open_bin path (fun channel -> output_string channel text)
let manifest = {|id="operator-test"
revision="1"
title="Operator fixture"
contributions=["observe"]
image="fixture/image"
command=["fixture"]
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=4096
|}
let source = "id=\"observer\"\nrun_id=\"world\"\nmanifest_path=\"../lane.toml\"\n[binding]\nsources=[]\n"
let with_directory f =
  let root = Filename.temp_dir "tui-lane-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let directory = Filename.concat root "declarations" in
    Unix.mkdir directory 0o700;
    write (Filename.concat root "lane.toml") manifest;
    f directory)
let save directory session =
  let request = Owner.write_request (Draft.write_json session) |> owner_ok in
  let status, json = match Owner.write ~directory request with
    | Ok receipt -> 200,Owner.receipt_to_json receipt
    | Error error -> (match error.code with Owner.Revision_conflict -> 409 | _ -> 400),Owner.error_to_json error in
  Draft.decode_response (Draft.Save session) ~status ~body:(Yojson.Safe.to_string json) |> ok
let read directory session =
  let path = Filename.concat directory session.Draft.file_name in
  let document = Owner.read ~directory ~source_path:path |> owner_ok in
  Draft.decode_response (Draft.Read path) ~status:200
    ~body:(Yojson.Safe.to_string (Owner.document_to_json document)) |> ok

let create_and_conflict_repair () = with_directory (fun directory ->
  let session = { (Draft.create "observer.toml" |> ok) with text=source } in
  let created = save directory session in
  let session = Draft.after_response session created in
  check string "TOML creates the actual owner file" source
    (In_channel.with_open_bin (Filename.concat directory "observer.toml") In_channel.input_all);
  check bool "successful create becomes an editable document" true (Option.is_some session.base);
  let external_text = "# Keeper edited the same file\n" ^ source in
  write (Filename.concat directory "observer.toml") external_text;
  let session = {session with text="# operator draft\n" ^ source} in
  let rejected = save directory session in
  check bool "stale save is a conflict" true
    (match rejected with Draft.Rejected {code=Draft.Revision_conflict;_} -> true | _ -> false);
  let session = Draft.after_response session rejected in
  check string "conflict preserves operator text" ("# operator draft\n" ^ source) session.text;
  check bool "current file is reviewable before replacement" true
    (List.mem "# Keeper edited the same file" (Draft.summary session));
  let session = Draft.use_current_revision session |> ok in
  let saved = save directory session in
  check bool "explicit current revision permits saving" true
    (match saved with Draft.Written {state=Draft.Saved;_} -> true | _ -> false);
  let session = Draft.after_response session saved in
  let current = read directory session in
  check bool "all consumers read the exact new bytes" true
    (match current with Draft.Read_document d -> d.source_text=session.text | _ -> false))

let malformed_file_stays_editable () = with_directory (fun directory ->
  let path = Filename.concat directory "broken.toml" in
  write path "id = [";
  let fresh = Draft.create "broken.toml" |> ok in
  let document = match read directory fresh with Draft.Read_document d -> d | _ -> fail "read did not return raw TOML" in
  check bool "invalid file is not replaced by a fabricated valid default" false document.valid;
  let session = {(Draft.from_document document) with text=source} in
  let invalid = {session with text="id = ["} in
  let response = save directory invalid in
  let retained = Draft.after_response invalid response in
  check string "rejected edit is preserved" "id = [" retained.text;
  check bool "repair uses the raw existing revision" true
    (match save directory session with Draft.Written _ -> true | _ -> false))

let file_identity_and_draft_sessions () = with_directory (fun directory ->
  let session = { (Draft.create "observer.toml" |> ok) with text=source } in
  let saved = save directory session in
  let first = Draft.after_response session saved in
  let second = { (Draft.create "statistics.toml" |> ok) with text="# unfinished statistics" } in
  let view = UI.put_document (UI.put_document UI.initial first) second in
  let view = UI.put_document view first in
  check int "switching documents retains both drafts" 2 (List.length view.documents);
  check string "unsubmitted second draft retained" second.text
    (List.find (fun (s : Draft.session) -> s.file_name=second.file_name) view.documents).text;
  let document = Owner.read ~directory ~source_path:(Filename.concat directory first.file_name) |> owner_ok in
  check bool "another source path cannot replace requested file" true
    (Result.is_error (Draft.decode_response (Draft.Read (Filename.concat directory "other.toml")) ~status:200
      ~body:(Yojson.Safe.to_string (Owner.document_to_json document))));
  List.iter (fun name -> check bool "only one TOML filename" true (Result.is_error (Draft.create name)))
    ["../outside.toml";"nested/file.toml";"file.json";".toml"])

let configuration_and_ports () =
  let json = Yojson.Safe.from_string {|{
    "instances":[{"instance_id":"actual-1","run_id":"world","addon_id":"custom","title":"Custom layer",
      "revision":"package-1","phase":{"kind":"attached"},"observation_seq":2,"rows_count":0,
      "incarnation":"actual-1","action_schema":null,
      "configuration":{"source_path":"/config/lane-addons/custom.toml"},
      "binding":{"sources":[{"kind":"lane_output","id":"input","installation_id":"upstream","output_id":"frames"}]},
      "package":{"outputs":{"metrics":{"lanes":["speed"]},"all":{"all_lanes":true}},"skills_directory":"skills"}}],
    "configuration":{"directory":"/config/lane-addons","complete":false,
      "declarations":[{"id":"custom","source_path":"/config/lane-addons/custom.toml",
        "desired_revision":"desired","applied_revision":"applied","instance_id":"actual-1"}],
      "issues":[{"id":null,"source_path":"/config/lane-addons/broken.toml","message":"invalid TOML"},
        {"id":null,"source_path":"/config/lane-addons","message":"inventory unavailable"},
        {"id":null,"source_path":"/config/lane-addons/nested/a.toml","message":"nested file"},
        {"id":null,"source_path":"/config/sibling/a.toml","message":"other directory"}]},
    "rows":[],"coverage":[]
  }|} in
  let snapshot = UI.decode json |> ok in
  let view = {UI.initial with snapshot=Some snapshot;focus=UI.Configurations;configuration_cursor=1} in
  check string "invalid declaration has its own selectable source" "/config/lane-addons/broken.toml"
    (Option.get (UI.selected_declaration view)).source_path;
  check (option string) "malformed file stays repairable" (Some "/config/lane-addons/broken.toml")
    (UI.selected_source_path view);
  List.iter (fun configuration_cursor ->
    check (option string) "directory/nested/sibling issues cannot become edit targets" None
      (UI.selected_source_path {view with configuration_cursor})) [2;3;4];
  check (option string) "current instance can edit its declaration" (Some "/config/lane-addons/custom.toml")
    (UI.selected_source_path {view with focus=UI.Instances});
  let past = {snapshot with instances=List.map (fun (i : UI.instance) -> {i with id="past-worker"}) snapshot.instances} in
  check (option string) "retained historical source does not authorize a new owner edit" None
    (UI.selected_source_path {view with focus=UI.Instances;snapshot=Some past});
  let lines = UI.lines ~width:100 view @ UI.lines ~width:100 {view with focus=UI.Instances} in
  check bool "unknown parse identity remains unknown" true
    (List.exists (String.starts_with ~prefix:"> unresolved installation") lines);
  check bool "named output is projected without domain branch" true (List.mem "   output metrics → speed" lines);
  check bool "package Skill directory is visible" true (List.mem "   Skills skills" lines);
  let slice = UI.decode_slice ~snapshot (Yojson.Safe.from_string {|{"rows":[],"coverage":[],"complete":false}|}) |> ok in
  check bool "slice keeps TOML inventory" true (slice.configuration=snapshot.configuration);
  check (option bool) "partial slice stays partial" (Some false) slice.complete

let action_identity_and_uncertainty () =
  let module Action = Masc.Lane_addon_action in
  let parsed = UI.parse_request {|act {"instance_id":"worker-1","expected_incarnation":"worker-1","request_id":"request-1","action":{"value":1}}|} |> ok in
  let request = match parsed with UI.Act request -> request | _ -> fail "not an action" in
  let input = Action.arguments ~instance_id:request.instance_id ~request_id:request.request_id ~action:request.action
    |> Action.canonical |> ok in
  let receipt : Action.receipt = {instance_id=request.instance_id;incarnation=request.incarnation;
    request_id=request.request_id;requester="operator";executor=None;input_sha256=Action.input_digest input;
    action=request.action;state=Action.Outcome_unknown;result=None;detail=Some "worker disconnected after dispatch"} in
  let received = UI.action_receipt request (Action.to_json receipt) |> ok in
  let lines = UI.lines ~width:100 {UI.initial with presentation=UI.Technical;last_action=Some request;action_receipt=Some received} in
  check bool "unknown outcome is never displayed as a confirmed effect" true (List.mem "  state outcome_unknown" lines);
  check bool "missing executor stays unknown" true (List.mem "  requester operator · executor unknown" lines);
  check bool "different request cannot satisfy status read" true
    (Result.is_error (UI.action_receipt {request with request_id="request-2"} (Action.to_json receipt)));
  check bool "duplicate identity in command is rejected" true
    (Result.is_error (UI.parse_request {|act {"instance_id":"a","instance_id":"b","expected_incarnation":"a","request_id":"r","action":{}}|}))

let metric_fields_and_receipts_remain_readable () =
  let module Row = Masc.Lane_addon_types in
  let digest = String.make 192 'a' in
  let note = String.concat "" (List.init 48 (fun _ -> "지표")) in
  let row : Row.row = {
    id="metric/2/statistics";lane_id="metric/statistics";kind=Row.Value;
    title="Supplied \027[31m row statistics";observed_at=1.;subject_id="guest";
    clock=None;actor=None;
    fields=["source_id",`String digest;"incarnation",`String digest;
      "observed_row_count",`Int 1;"input_complete",`Bool true;
      "note",`String note];
    evidence=[{uri="lane-evidence:" ^ digest;sha256=Some digest}];related_ids=[] } in
  let snapshot : UI.snapshot = {instances=[];configuration=None;
    output={rows=[row];coverage=[]};complete=Some true} in
  let view = {UI.initial with snapshot=Some snapshot;focus=UI.Rows;
    receipt=Some (`Assoc ["uri",`String digest;"result",`String "last receipt value"])} in
  List.iter (fun width ->
    let lines = UI.lines ~width view in
    check bool "every printable row fits the actual terminal width" true
      (List.for_all (fun line -> Masc_tui_message_layout.display_width line <= width) lines);
    check bool "external terminal controls are escaped before measuring" true
      (List.for_all (fun line -> not (String.contains line '\027')) lines);
    let visible = String.concat "" lines in
    let contains text =
      let n = String.length text in
      let rec at i = i+n <= String.length visible
        && (String.sub visible i n=text || at (i+1)) in
      at 0 in
    List.iter (fun text -> check bool "scrollable rows retain complete field and receipt text" true (contains text))
      ["\"observed_row_count\": 1";digest;note;"lane-evidence:" ^ digest;"last receipt value"])
    [40;80;200]

let selection_stays_visible () =
  let module Row = Masc.Lane_addon_types in
  let rows = List.init 80 (fun index -> ({
    Row.id=Printf.sprintf "row-%d" index; lane_id=Printf.sprintf "lane-%d" index;
    kind=Row.Event; title=String.make 160 'x'; observed_at=float_of_int index;
    subject_id="fixture"; clock=None; actor=None; fields=[]; evidence=[]; related_ids=[]
  } : Row.row)) in
  let instance : UI.instance = {id=String.make 120 'i'; run_id="run"; addon_id="fixture";
    title=String.make 120 't'; revision="1"; phase=Row.Attached; observation_seq=1;
    rows_count=80; source_path=None; binding=`Assoc []; outputs=[];
    skills_directory=None; incarnation="instance"; action_schema=None; binding_schema=None; display=Masc.Lane_addon_presentation.empty} in
  let snapshot : UI.snapshot = {instances=[instance]; configuration=None;
    output={rows;coverage=[]}; complete=None} in
  List.iter (fun (width,height) ->
    let request : UI.action_request = {instance_id=instance.id;incarnation=instance.incarnation;
      request_id="long-receipt";action=`Assoc []} in
    let view = {UI.initial with snapshot=Some snapshot;focus=UI.Rows;row_cursor=79;
      last_action=Some request;receipt=Some (`String (String.make 1000 'r'))} in
    let lines = UI.lines ~height ~width view in
    let first_screen = List.filteri (fun index _ -> index < height) lines in
    check bool "last selection visible without manually scrolling inventory" true
      (List.exists (String.starts_with ~prefix:"> [ ] lane-79") first_screen);
    check bool "long labels fit a single row" true
      (List.for_all (fun line -> Masc_tui_message_layout.display_width line <= width) lines);
    check bool "selected lane detail has exact identity" true (List.mem "Row row-79" lines);
    check bool "unselected row details are not expanded" false (List.mem "Row row-0" lines))
    [40,16;80,24;120,50]

let concurrent_scene () =
  let module Row = Masc.Lane_addon_types in
  let owner = "35e30f7a-66d1-4e44-a4ed-762be081ee91" in
  let row id lane observed_at clock : Row.row = {
    id;lane_id=owner ^ "/" ^ lane;kind=Row.Event;title=id;observed_at;
    subject_id="shared";clock;actor=None;fields=[];evidence=[];related_ids=[]} in
  let rows = [row "browser read" "browser" 1789257600. (Some {domain="dom";value="revision-2"});
    row "frame advanced" "game" 1789257600. (Some {domain="frame";value="154618"});
    row "next day" "game" 1789344000. None] in
  let snapshot : UI.snapshot = {instances=[];configuration=None;complete=Some false;
    output={rows;coverage=[{source_id="frames";incarnation=owner;cursor=None;complete=false;detail=Some "source unavailable"}]}} in
  let view = {UI.initial with snapshot=Some snapshot} in
  let visual view = Option.get (UI.visual_lines ~height:30 ~width:120 view) in
  let lines view = UI.lines ~height:30 ~width:120 view in
  check bool "same timestamp is one aligned row" true
    (List.exists (fun (line : UI.visual_line) ->
      let cells = List.map snd line.cells in
      List.exists (fun text -> String.contains text '>') cells && List.length cells>=3) (visual view));
  check bool "partial source summary remains visible" true
    (List.exists (String.starts_with ~prefix:"PARTIAL") (lines view));
  check bool "full date survives" true
    (List.exists (String.starts_with ~prefix:"2026-09-14") (lines view));
  let next = UI.move_lane view 1 in
  check (option string) "horizontal comparison keeps shared timestamp" (Some "frame advanced")
    (Option.map (fun (row : Row.row) -> row.id) (UI.selected_row next));
  let previous = UI.move_lane next (-1) in
  check int "back to simultaneous event" view.row_cursor previous.row_cursor;
  let next = UI.move_observation next 1 in
  check (option string) "vertical move follows observed chronology" (Some "next day")
    (Option.map (fun (row : Row.row) -> row.id) (UI.selected_row next));
  let extreme = {snapshot with output={snapshot.output with rows=[row "extreme" "time" Float.max_float None]}} in
  ignore (lines {view with snapshot=Some extreme});
  List.iter (fun width ->
    check bool "visual cells stay within terminal width" true
      (List.for_all (fun line -> Masc_tui_message_layout.display_width line<=width)
        (UI.lines ~height:20 ~width {view with selected=["browser read"]}))) [40;64;120]

let failure_state_is_truthful () =
  let idle = UI.lines ~height:20 ~width:80 UI.initial in
  check bool "empty state does not claim a server reading" true
    (List.exists (String.starts_with ~prefix:"No reading yet") idle);
  let failed = UI.lines ~height:20 ~width:80
    {UI.initial with error=Some "GET failed: connection refused"} in
  check bool "failed request is labelled as a failure" true
    (List.exists (String.starts_with ~prefix:"Load failed:") failed);
  check bool "failure is not presented as an empty successful reading" false
    (List.exists (String.starts_with ~prefix:"No reading yet") failed)

let guided_actions () =
  let schema = Yojson.Safe.from_string {|{
    "type":"object","required":["context","request_id","action"],"additionalProperties":false,
    "properties":{
      "context":{"type":"object","required":["instance_id","incarnation"],"additionalProperties":false,
        "properties":{"instance_id":{"type":"string"},"incarnation":{"type":"string"}}},
      "request_id":{"type":"string","minLength":36},
      "action":{"type":"object","required":["operation"],"additionalProperties":false,
        "properties":{"operation":{"type":"string","enum":["capture","inspect"]}}}
    }}|} in
  let instance : UI.instance = {id="worker";incarnation="worker";run_id="run";
    addon_id="arbitrary-package";title="Useful observer";revision="1";phase=UI.Row.Attached;
    observation_seq=1;rows_count=0;source_path=None;binding=`Assoc [];outputs=[];
    skills_directory=None;action_schema=Some schema; binding_schema=None; display=Masc.Lane_addon_presentation.empty} in
  let snapshot : UI.snapshot = {instances=[instance];configuration=None;
    output={rows=[];coverage=[]};complete=Some true} in
  let view = UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" {UI.initial with snapshot=Some snapshot} |> ok in
  let first = UI.submit_action view |> ok in
  check string "current worker supplies identity" "worker" first.instance_id;
  check bool "arbitrary schema field and value are used" true
    (first.action=`Assoc ["operation",`String "capture"]);
  let second = UI.submit_action (UI.move_action view 1) |> ok in
  check bool "choosing a different action uses its payload" true
    (second.action=`Assoc ["operation",`String "inspect"]);
  let replaced = {snapshot with instances=[{instance with id="replacement";incarnation="replacement"}]} in
  check bool "replacement cannot inherit open menu authority" true
    (Result.is_error (UI.submit_action {view with snapshot=Some replaced}));
  check bool "observation-only package has no invented action" true
    (Result.is_error (UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" {UI.initial with snapshot=Some
      {snapshot with instances=[{instance with action_schema=None}]}}));
  let technical = UI.open_actions ~request_id:first.request_id
    {UI.initial with presentation=UI.Technical;snapshot=Some snapshot} |> ok in
  check bool "opening actions exposes the choice even from technical mode" true (technical.presentation=UI.Summary);
  List.iter (fun width -> check int "refresh does not move compact content"
    (List.length (UI.lines ~width {UI.initial with snapshot=Some snapshot}))
    (List.length (UI.lines ~width {UI.initial with loading=true;snapshot=Some snapshot}))) [10;40;100];
  let with_document = {technical with document_key=Some "draft.toml"} in
  check bool "menu remains visible over an open document" true
    (List.mem "operation: \"capture\"" (UI.lines ~width:100 with_document));
  let moved = UI.move_action {view with scroll=100} 1 in
  check int "next choice is brought back into view" 0 moved.scroll;
  let replace key value = function
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "object fixture expected" in
  let property_fields = match schema with `Assoc fields -> List.assoc "properties" fields | _ -> fail "schema" in
  let reverse_action = Yojson.Safe.from_string {|{"type":"object","required":["z","a"],
    "additionalProperties":false,"properties":{"z":{"type":"string","const":"last"},"a":{"type":"string","const":"first"}}}|} in
  let reverse_schema = replace "properties" (replace "action" reverse_action property_fields) schema in
  let reverse_view = UI.open_actions ~request_id:first.request_id {UI.initial with
    snapshot=Some {snapshot with instances=[{instance with action_schema=Some reverse_schema}]}} |> ok in
  let request = UI.submit_action reverse_view |> ok in
  check bool "request is canonical before receipt comparison" true
    (request.action=`Assoc ["a",`String "first";"z",`String "last"]);
  let input = UI.Action.arguments ~instance_id:request.instance_id ~request_id:request.request_id
    ~action:request.action |> UI.Action.canonical |> ok in
  let receipt : UI.Action.receipt = {instance_id=request.instance_id;incarnation=request.incarnation;
    request_id=request.request_id;requester="operator";executor=Some "worker";
    input_sha256=UI.Action.input_digest input;action=request.action;state=UI.Action.Confirmed;
    result=Some (`Assoc []);detail=None} in
  ignore (UI.action_receipt request (UI.Action.to_json receipt) |> ok);
  let compact = UI.lines ~width:100 {UI.initial with snapshot=Some snapshot} in
  check bool "first screen names installed package" true
    (List.exists (fun line -> String.starts_with ~prefix:"> Useful observer" line) compact);
  check bool "technical action schema is folded by default" false
    (List.exists (fun line -> String.contains line '{') compact)

let context_flow_uses_declared_connections () =
  let producer : UI.instance = {id="source-worker";incarnation="source-worker";run_id="project";
    addon_id="any-source";title="Project observer";revision="1";phase=UI.Row.Attached;
    observation_seq=1;rows_count=0;source_path=None;binding=`Assoc ["sources",`List []];
    outputs=["events",UI.Row.All_lanes];skills_directory=None;action_schema=None; binding_schema=None; display=Masc.Lane_addon_presentation.empty} in
  let consumer = {producer with id="metric-worker";incarnation="metric-worker";title="Project metric";
    binding=Yojson.Safe.from_string {|{"sources":[{"source_id":"input","kind":"lane_output",
      "installation_id":"project-observer","output_id":"events","selection":"latest_completed"}]}|}} in
  let declaration installation_id instance_id : UI.declaration =
    {source_path="/config/" ^ installation_id ^ ".toml";installation_id=Some installation_id;
      instance_id=Some instance_id;desired=Some "1";applied=Some "1";issues=[]} in
  let configuration : UI.configuration = {directory="/config";complete=true;
    declarations=[declaration "project-observer" producer.id;declaration "project-metric" consumer.id]} in
  let snapshot : UI.snapshot = {instances=[producer;consumer];configuration=Some configuration;
    output={rows=[];coverage=[]};complete=None} in
  let view = {UI.initial with presentation=UI.Flow;snapshot=Some snapshot} in
  check bool "flow exposes the selected action target" true
    (List.mem "Action target: Project observer · source-worker" (UI.lines ~width:160 view));
  let moved = UI.lines ~width:160 {view with instance_cursor=1} in
  check bool "flow target follows instance selection" true
    (List.mem "Action target: Project metric · metric-worker" moved
      && List.mem "> project-metric · Project metric · attached" moved);
  check bool "flow names the actual configured dependency" true
    (List.mem "  project-observer -> project-metric" (UI.lines ~width:160 view));
  let partial = {snapshot with instances=[consumer];configuration=Some {configuration with complete=false}} in
  let partial_view = {view with snapshot=Some partial;error=Some "network failure"} in
  let partial_lines = UI.lines ~width:160 partial_view in
  check bool "failed read remains visible in flow" true
    (List.mem "Refresh failed; graph may be stale: network failure" partial_lines);
  check bool "partial inventory cannot establish producer absence" true
    (List.mem "  project-observer -> project-metric · producer unresolved; inventory incomplete" partial_lines);
  check bool "missing producer stays visible" true
    (List.mem "  project-observer -> project-metric · producer absent in this run"
      (UI.lines ~width:160 {view with snapshot=Some {snapshot with instances=[consumer]}}))

let () = run "TUI Lane package operations" ["operator scenarios",[
  test_case "context flow follows declared Add-on dependencies" `Quick context_flow_uses_declared_connections;
  test_case "choose advertised action without entering IDs or JSON" `Quick guided_actions;
  test_case "create TOML, conflict, compare and explicitly save" `Quick create_and_conflict_repair;
  test_case "read invalid existing TOML and repair it" `Quick malformed_file_stays_editable;
  test_case "switch drafts and reject mismatched file identity" `Quick file_identity_and_draft_sessions;
  test_case "configuration issues, named outputs and partial slice" `Quick configuration_and_ports;
  test_case "action identity and unknown outcome survive TUI projection" `Quick action_identity_and_uncertainty;
  test_case "concurrent scene preserves clocks, coverage and selection" `Quick concurrent_scene;
  test_case "failed reads remain distinct from empty reads" `Quick failure_state_is_truthful;
  test_case "large inventories keep the selected lane visible" `Quick selection_stays_visible;
  test_case "metric fields and receipts remain readable at terminal widths" `Quick metric_fields_and_receipts_remain_readable]]
