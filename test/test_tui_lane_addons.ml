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
  let view = {UI.initial with technical_details=true;focus=UI.Configurations;snapshot=Some snapshot;configuration_cursor=1} in
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
  let lines = UI.lines ~width:100 view in
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
  let lines = UI.lines ~width:100 {UI.initial with technical_details=true;last_action=Some request;action_receipt=Some received} in
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
  let view = {UI.initial with technical_details=true;snapshot=Some snapshot;
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
    skills_directory=None;action_schema=Some schema} in
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
    {UI.initial with technical_details=true;snapshot=Some snapshot} |> ok in
  check bool "opening actions exposes the choice even from technical mode" false technical.technical_details;
  check int "refresh does not move compact content"
    (List.length (UI.lines ~width:100 {UI.initial with snapshot=Some snapshot}))
    (List.length (UI.lines ~width:100 {UI.initial with loading=true;snapshot=Some snapshot}));
  let replace key value = function
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "object fixture expected" in
  let property_fields = match schema with `Assoc fields -> List.assoc "properties" fields | _ -> fail "schema" in
  let reverse_action = Yojson.Safe.from_string {|{"type":"object","required":["z","a"],
    "additionalProperties":false,"properties":{"z":{"const":"last"},"a":{"const":"first"}}}|} in
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

let () = run "TUI Lane package operations" ["operator scenarios",[
  test_case "choose advertised action without entering IDs or JSON" `Quick guided_actions;
  test_case "create TOML, conflict, compare and explicitly save" `Quick create_and_conflict_repair;
  test_case "read invalid existing TOML and repair it" `Quick malformed_file_stays_editable;
  test_case "switch drafts and reject mismatched file identity" `Quick file_identity_and_draft_sessions;
  test_case "configuration issues, named outputs and partial slice" `Quick configuration_and_ports;
  test_case "action identity and unknown outcome survive TUI projection" `Quick action_identity_and_uncertainty;
  test_case "metric fields and receipts remain readable at terminal widths" `Quick metric_fields_and_receipts_remain_readable]]
