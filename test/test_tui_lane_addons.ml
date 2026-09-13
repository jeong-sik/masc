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
  let view = {UI.initial with presentation=UI.Technical;focus=UI.Configurations;snapshot=Some snapshot;configuration_cursor=1} in
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
  let view = {UI.initial with presentation=UI.Technical;snapshot=Some snapshot;
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
    skills_directory=None;action_schema=Some schema;binding_schema=None;display=Masc.Lane_addon_presentation.empty} in
  let snapshot : UI.snapshot = {instances=[instance];configuration=None;
    output={rows=[];coverage=[]};complete=Some true} in
  let detached = {instance with id="retained-worker";phase=UI.Row.Detached} in
  let overview = {UI.initial with snapshot=Some {snapshot with instances=[instance;detached]};instance_cursor=1} in
  let interleaved = {overview with snapshot=Some {snapshot with instances=[detached;instance;
    {instance with id="failed-worker";phase=UI.Row.Failed "offline"};
    {instance with id="second-worker"}]}} in
  let selected = List.init 4 (fun instance_cursor ->
    match UI.selected_instance {interleaved with instance_cursor} with
    | Some instance -> instance.id | None -> fail "missing selection") in
  check (list string) "navigation follows the same active, attention, retained order as rendering"
    ["worker";"second-worker";"failed-worker";"retained-worker"] selected;
  let failed = {instance with id="retry-worker";phase=UI.Row.Failed "source capture failed"} in
  let retry = {UI.initial with snapshot=Some {snapshot with instances=[failed]}} in
  check bool "failed worker can request observation retry" true (UI.can_observe failed);
  (* Check worker controls independently of global navigation commands, which
     other Lane panels extend. Keep grouping assertions separate for diagnosis. *)
  check bool "failed worker exposes retry and advertised action controls" true
    (String.ends_with ~suffix:"o:retry observation  a:actions  d:cleanup  f:flow  D:details  J/K:scroll  Esc:back"
       (UI.overview_hints retry));
  check bool "failed worker retains attention grouping" true
    (List.mem "Needs attention" (UI.lines ~width:240 retry));
  check bool "failed worker is not grouped as active" false
    (List.mem "Active workers" (UI.lines ~width:240 retry));
  check bool "failed worker can request its advertised action without forced cleanup" true
    (Result.is_ok (UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" retry));
  let lines = UI.lines ~width:240 overview in
  check bool "active workers and retained history are distinct" true
    (List.mem "Active workers" lines && List.mem "Retained history" lines);
  check bool "retained worker carries its exact identity" true
    (List.mem "    run run · instance retained-worker" lines);
  check bool "detached selection offers no observe or action controls" true
    (String.ends_with ~suffix:"retained history · D:details  f:flow  D:details  J/K:scroll  Esc:back"
       (UI.overview_hints overview));
  check bool "detached schema cannot open actions" true
    (Result.is_error (UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" overview));
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
    (List.exists (fun line -> String.contains line '{') compact);
  let display = Masc.Lane_addon_presentation.of_json (Yojson.Safe.from_string
    {|{"readings":[{"lane_id":"quality","path":["missing"],"label":"Missing records","unit":"records","format":"number"}]}|}) |> ok in
  let row : UI.Row.row = {id="row";lane_id="worker/quality";kind=UI.Row.Value;
    title="Project quality";observed_at=1.;subject_id="project";clock=None;actor=None;
    fields=["missing",`Int 3];evidence=[];related_ids=[]} in
  let shown = UI.lines ~width:100 {UI.initial with snapshot=Some
    {snapshot with instances=[{instance with display}];output={rows=[row];coverage=[]}}} in
  check bool "package label and unit appear without domain host code" true
    (List.mem "    Missing records: 3 records" shown);
  let absent = UI.lines ~width:100 {UI.initial with snapshot=Some
    {snapshot with instances=[{instance with display}];output={rows=[{row with fields=[]}];coverage=[]}}} in
  check bool "missing readings are unavailable rather than zero" true
    (List.mem "    Missing records: unavailable (field unavailable)" absent);
  let wrong_type = UI.lines ~width:100 {UI.initial with snapshot=Some
    {snapshot with instances=[{instance with display}];
      output={rows=[{row with fields=["missing",`String "3"]}];coverage=[]}}} in
  check bool "numeric display does not coerce text into a measurement" true
    (List.mem "    Missing records: unavailable (field does not match declared display format)" wrong_type);
  let other = {instance with id="worker-other";incarnation="worker-other"} in
  let foreign = UI.lines ~width:100 {UI.initial with snapshot=Some
    {snapshot with instances=[{instance with display};other];
      output={rows=[{row with lane_id="worker-other/quality"}];coverage=[]}}} in
  check bool "another instance retains its generic reading" true
    (List.mem "    missing=3" foreign);
  check bool "presentation metadata cannot cross instance namespaces" false
    (List.exists (fun line -> String.starts_with ~prefix:"    Missing records:" line) foreign);
  let form_schema = match schema with
    | `Assoc fields ->
        let properties = match List.assoc "properties" fields with `Assoc p -> p | _ -> assert false in
        let action = Yojson.Safe.from_string
          {|{"type":"object","properties":{"query":{"type":"string","minLength":3}},"required":["query"],"additionalProperties":false}|} in
        `Assoc (("properties",`Assoc (("action",action)::List.remove_assoc "action" properties))::List.remove_assoc "properties" fields)
    | _ -> assert false in
  let form_view = UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000002"
    {UI.initial with snapshot=Some {snapshot with instances=[{instance with action_schema=Some form_schema}]}} |> ok in
  let edit key view = match UI.edit_action ~key view |> ok with
    | next,None -> next | _,Some _ -> fail "editing must not submit" in
  let typed = form_view |> edit "j" |> edit "o" |> edit "b" in
  let reviewed = edit "\019" typed in
  check bool "review remains explicit before submission" true
    (List.exists (fun line -> String.starts_with ~prefix:"Review input" line) (UI.lines ~width:100 reviewed));
  let submitted = match UI.edit_action ~key:"enter" reviewed |> ok with
    | _,Some request -> request | _ -> fail "review Enter must submit" in
  check bool "free text including navigation letters is preserved" true
    (submitted.action=`Assoc ["query",`String "job"]);
  let replaced = {reviewed with snapshot=Some {snapshot with instances=[{instance with id="replacement";incarnation="replacement";action_schema=Some form_schema}]}} in
  check bool "review does not authorize a replaced worker" true
    (Result.is_error (UI.edit_action ~key:"enter" replaced));
  let pasted_text = "https://예시.test/경기\n\019\r" in
  let pasted = UI.paste_action ~text:pasted_text form_view in
  let pasted_review = edit "\019" pasted in
  let pasted_review = UI.paste_action ~text:"must not change review" pasted_review in
  let request = match UI.edit_action ~key:"enter" pasted_review |> ok with
    | _,Some request -> request | _ -> fail "paste review must submit only on Enter" in
  check bool "paste is Unicode text, never input commands; review stays immutable" true
    (request.action=`Assoc ["query",`String pasted_text]);
  let open_schema action =
    let schema = match form_schema with
      | `Assoc fields ->
          let properties = match List.assoc "properties" fields with `Assoc p -> p | _ -> assert false in
          `Assoc (("properties",`Assoc (("action",Yojson.Safe.from_string action)::List.remove_assoc "action" properties))::List.remove_assoc "properties" fields)
      | _ -> assert false in
    UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000003"
      {UI.initial with snapshot=Some {snapshot with instances=[{instance with action_schema=Some schema}]}} |> ok in
  let optional = open_schema
    {|{"type":"object","properties":{"operation":{"type":"string","const":"search"},"query":{"type":"string"}},"required":["operation"],"additionalProperties":false}|} in
  let optional = optional |> edit "tab" |> UI.paste_action ~text:"검색" |> edit "\019" in
  let request = match UI.edit_action ~key:"enter" optional |> ok with
    | _,Some request -> request | _ -> fail "optional parameter action must submit" in
  check bool "optional fields remain editable beside a required constant" true
    (request.action=`Assoc ["operation",`String "search";"query",`String "검색"]);
  let nested = open_schema
    {|{"type":"object","properties":{"query":{"type":"string"},"options":{"type":"object","properties":{"mode":{"type":"string","const":"custom"},"target":{"type":"string"}},"required":["mode","target"],"additionalProperties":false}},"required":["query"],"additionalProperties":false}|} in
  let nested = nested |> UI.paste_action ~text:"search" |> edit "tab" in
  let reviewed = edit "\019" nested in
  let request = match UI.edit_action ~key:"enter" reviewed |> ok with
    | _,Some request -> request | _ -> fail "omitted optional object must submit" in
  check bool "nested constants never activate an omitted optional object" true
    (request.action=`Assoc ["query",`String "search"]);
  let enabled = nested |> edit "tab" |> UI.paste_action ~text:"selected" |> edit "\019" in
  let request = match UI.edit_action ~key:"enter" enabled |> ok with
    | _,Some request -> request | _ -> fail "explicit optional object must submit" in
  check bool "explicit child activates its object's required constants" true
    (request.action=`Assoc ["options",`Assoc ["mode",`String "custom";"target",`String "selected"];"query",`String "search"]);
  let unset = enabled |> edit "esc" |> edit "\021" |> edit "\019" in
  let request = match UI.edit_action ~key:"enter" unset |> ok with
    | _,Some request -> request | _ -> fail "unset last child must omit optional object" in
  check bool "unsetting the last explicit child removes optional object" true
    (request.action=`Assoc ["query",`String "search"])



let context_flow_uses_declared_connections () =
  let producer : UI.instance = {id="source-worker";incarnation="source-worker";run_id="project";
    addon_id="any-source";title="Project observer";revision="1";phase=UI.Row.Attached;
    observation_seq=1;rows_count=0;source_path=None;binding=`Assoc ["sources",`List []];
    outputs=["events",UI.Row.All_lanes];skills_directory=None;action_schema=None;binding_schema=None;display=Masc.Lane_addon_presentation.empty} in
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

let guided_installation () =
  let module Install = Masc_tui_lane_installer in
  let edit key state = match Install.handle ~key state |> ok with
    | Install.Updated next -> next | _ -> fail "editing must not invoke a request" in
  let path = Install.create () |> ok |> Install.paste ~text:"/packages/arbitrary/lane.toml" |> edit "\019" in
  check string "manifest is requested only after explicit reviewed Enter" "/packages/arbitrary/lane.toml"
    (match Install.handle ~key:"enter" path |> ok with Preview path -> path | _ -> fail "expected preview");
  let schema = Yojson.Safe.from_string
    {|{"type":"object","properties":{"topic":{"type":"string","minLength":1}},"required":["topic"],"additionalProperties":false}|} in
  let preview image = `Assoc ["manifest_path",`String "/packages/arbitrary/lane.toml";
    "image",image;"package",`Assoc ["title",`String "Arbitrary observer";"revision",`String "revision-1";
      "image",`String "worker:revision-1";"binding_schema",schema]] in
  let response = preview (`Assoc ["state",`String "unverified";"detail",`String "engine offline"]) in
  let pending = Install.begin_preview ~request_id:10 ~path:"/packages/arbitrary/lane.toml" path |> ok in
  let reopened = Install.create () |> ok in
  check bool "canceled preview cannot replace a freshly opened wizard" true
    (Option.is_none (Install.receive_preview ~request_id:10 ~path:"/packages/arbitrary/lane.toml" (Ok response) reopened));
  check bool "different request identity cannot consume pending preview" true
    (Option.is_none (Install.receive_preview ~request_id:9 ~path:"/packages/arbitrary/lane.toml" (Ok response) pending));
  check bool "different manifest cannot consume pending preview" true
    (Option.is_none (Install.receive_preview ~request_id:10 ~path:"/other/lane.toml" (Ok response) pending));
  let failed,error = Install.receive_preview ~request_id:10 ~path:"/packages/arbitrary/lane.toml"
    (Error "preview failed") pending |> Option.get in
  check (option string) "failed preview retains error" (Some "preview failed") error;
  check bool "failed preview restores editable request for retry" true
    (Result.is_ok (Install.begin_preview ~request_id:11 ~path:"/packages/arbitrary/lane.toml" failed));
  let form,error = Install.receive_preview ~request_id:10 ~path:"/packages/arbitrary/lane.toml"
    (Ok response) pending |> Option.get in
  check (option string) "matching preview advances without error" None error;
  check bool "failed image inspection remains explicit" true
    (List.mem "Image unverified: engine offline" (Install.lines form));
  let reviewed = form |> Install.paste ~text:"research-observer" |> edit "tab"
    |> Install.paste ~text:"project-run" |> edit "tab"
    |> Install.paste ~text:"quoted \"topic\" and 한국어" |> edit "\019" in
  let session = match Install.handle ~key:"enter" reviewed |> ok with
    | Draft session -> session | _ -> fail "expected local declaration draft" in
  check bool "wizard produces unsaved create document" true (session.base=None);
  check string "declaration filename derives from entered installation" "research-observer.toml" session.file_name;
  let document = match Otoml.Parser.from_string_result session.text with
    | Ok document -> document | Error _ -> fail "generated TOML must parse" in
  check string "actual manifest path survives TOML encoding" "/packages/arbitrary/lane.toml"
    (Otoml.find_opt document Otoml.get_string ["manifest_path"] |> Option.get);
  check string "quoted Unicode binding survives serialization" "quoted \"topic\" and 한국어"
    (Otoml.find_opt document Otoml.get_string ["binding";"topic"] |> Option.get)

let object_array_fields () =
  let module Form = Masc_tui_schema_form in
  let schema = Yojson.Safe.from_string
    {|{"type":"object","properties":{"records":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"object","properties":{"label":{"type":"string","minLength":1},"kind":{"type":"string","const":"record"},"note":{"type":"string"}},"required":["label","kind"],"additionalProperties":false}}},"required":["records"],"additionalProperties":false}|} in
  let edit key form = match Form.handle ~key form |> ok with
    | Form.Updated form -> form | _ -> fail "array editing must not submit the enclosing form" in
  let add text form = form |> edit "a" |> Form.insert_text ~text |> edit "\019" |> edit "enter" in
  let initial = Form.create ~schema ~initial:(`Assoc []) |> ok in
  let array = edit "\005" initial in
  check bool "opening an array does not create a required value" true
    (Result.is_error (Form.value (edit "esc" array)));
  check bool "empty array enforces declared minItems when applied" true
    (Result.is_error (Form.handle ~key:"\019" array));
  let child = edit "a" array in
  check bool "item validates required fields before review" true
    (Result.is_error (Form.handle ~key:"\019" child));
  let two = array |> add "첫번째" |> add "second" in
  let too_many = add "third" two in
  check bool "multiple items enforce declared maxItems when applied" true
    (Result.is_error (Form.handle ~key:"\019" too_many));
  let fixed = too_many |> edit "d" |> edit "k" |> edit "e" |> edit "\021"
    |> Form.insert_text ~text:"edited" |> edit "\019" |> edit "enter" in
  let applied = edit "\019" fixed in
  let item label = `Assoc ["kind",`String "record";"label",`String label] in
  let expected = `Assoc ["records",`List [item "edited";item "second"]] in
  check bool "object items preserve order, constants and absent optional fields" true
    ((Form.value applied |> ok)=expected);
  let reviewed = edit "\019" applied in
  let submitted = match Form.handle ~key:"enter" reviewed |> ok with
    | Form.Submit json -> json | _ -> fail "only enclosing review Enter submits" in
  check bool "enclosing form submits the reviewed array" true (submitted=expected);
  let discarded = applied |> edit "\005" |> edit "d" |> edit "esc" in
  check bool "canceling array edits preserves its committed value" true
    ((Form.value discarded |> ok)=expected);
  let optional_schema = match schema with `Assoc fields ->
    `Assoc (("required",`List [])::List.remove_assoc "required" fields) | _ -> assert false in
  let optional = Form.create ~schema:optional_schema ~initial:(`Assoc []) |> ok in
  let optional = optional |> edit "\005" |> edit "a" |> edit "esc" |> edit "esc" in
  check bool "canceling new optional item never activates its array" true
    ((Form.value optional |> ok)=`Assoc []);
  let primitive_schema = Yojson.Safe.from_string
    {|{"type":"object","properties":{"values":{"type":"array","items":{"type":"string"}}},"required":["values"],"additionalProperties":false}|} in
  let primitive = Form.create ~schema:primitive_schema ~initial:(`Assoc []) |> ok in
  check bool "primitive arrays remain direct JSON input" true
    (Result.is_error (Form.handle ~key:"\005" primitive));
  let primitive = primitive |> Form.insert_text ~text:"[\"one\",\"two\"]" |> edit "\019" in
  check bool "primitive array JSON remains valid" true
    ((Form.value primitive |> ok)=`Assoc ["values",`List [`String "one";`String "two"]])

let () = run "TUI Lane package operations" ["operator scenarios",[
  test_case "edit object array items through nested schema forms" `Quick object_array_fields;
  test_case "inspect package and draft schema-bound installation" `Quick guided_installation;
  test_case "context flow follows declared Add-on dependencies" `Quick context_flow_uses_declared_connections;
  test_case "choose advertised action without entering IDs or JSON" `Quick guided_actions;
  test_case "create TOML, conflict, compare and explicitly save" `Quick create_and_conflict_repair;
  test_case "read invalid existing TOML and repair it" `Quick malformed_file_stays_editable;
  test_case "switch drafts and reject mismatched file identity" `Quick file_identity_and_draft_sessions;
  test_case "configuration issues, named outputs and partial slice" `Quick configuration_and_ports;
  test_case "action identity and unknown outcome survive TUI projection" `Quick action_identity_and_uncertainty;
  test_case "metric fields and receipts remain readable at terminal widths" `Quick metric_fields_and_receipts_remain_readable]]
