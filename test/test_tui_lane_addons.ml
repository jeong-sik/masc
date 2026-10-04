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
  ignore (Draft.create ".toml" |> ok);
  check bool "enumerated suffix-only declaration is selectable" true
    (Draft.editable_source_path ~directory (Filename.concat directory ".toml"));
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
    ["../outside.toml";"nested/file.toml";"file.json"];
  check bool "suffix-only filename follows the declaration loader" true (Result.is_ok (Draft.create ".toml")))

let configuration_and_ports () =
  let json = Yojson.Safe.from_string {|{
    "instances":[{"instance_id":"actual-1","run_id":"world","addon_id":"custom","title":"Custom layer",
      "revision":"package-1","phase":{"kind":"attached"},"observation_seq":2,"rows_count":0,
      "incarnation":"actual-1","action_schema":null,
      "configuration":{"id":"custom","source_path":"/config/lane-addons/custom.toml","revision":"applied"},
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
  check (option string) "decode retains the worker's applied configuration owner" (Some "custom")
    (List.hd snapshot.instances).installation_id;
  let overview = {UI.initial with snapshot=Some snapshot} in
  let worker = List.hd snapshot.instances in
  check bool "known revision mismatch blocks removal before dispatch" true
    (Option.is_some (UI.removal_block_reason overview worker));
  let current = {snapshot with configuration=Option.map (fun (c:UI.configuration) ->
    {c with complete=true; declarations=List.map (fun (d:UI.declaration) -> {d with desired=d.applied}) c.declarations}) snapshot.configuration} in
  check (option string) "matching current owner may be removed" None
    (UI.removal_block_reason {overview with snapshot=Some current} worker);
  check bool "unknown configured inventory blocks removal" true
    (Option.is_some (UI.removal_block_reason {overview with snapshot=Some {snapshot with configuration=None}} worker));
  let config = Option.get current.configuration in
  let owned = List.hd config.declarations in
  let removal declarations complete = UI.removal_block_reason
    {overview with snapshot=Some {current with configuration=Some {config with declarations;complete}}} worker in
  check bool "partial inventory blocks matching revision" true
    (Option.is_some (removal [owned] false));
  check bool "duplicate owner ID blocks removal even at another path" true
    (Option.is_some (removal [owned;{owned with source_path="/config/lane-addons/duplicate.toml";instance_id=None}] true));
  check bool "same ID issue elsewhere blocks removal" true
    (Option.is_some (removal [owned;{owned with source_path="/config/lane-addons/duplicate.toml";
      desired=None;applied=None;instance_id=None;issues=["duplicate"];origin=UI.Issue_only}] true));
  check bool "invalid owned file with no recoverable ID blocks removal" true
    (Option.is_some (removal [{owned with installation_id=None;desired=None;applied=None;
      instance_id=None;issues=["invalid TOML"];origin=UI.Issue_only}] true));
  check (option string) "missing owned file permits retained worker cleanup" None (removal [] true);
  check (option string) "unrelated invalid declaration does not block cleanup" None
    (removal [{UI.installation_id=None;source_path="/config/lane-addons/unrelated.toml";
      desired=None;applied=None;instance_id=None;issues=["invalid TOML"];origin=UI.Issue_only}] true);
  check (option string) "manual cleanup remains available" None
    (UI.removal_block_reason overview {worker with installation_id=None;source_path=None});

  let empty = {snapshot with instances=[];
    configuration=Some {directory="/config/lane-addons";complete=true;declarations=[]}} in
  let first = {snapshot with instances=[];
    configuration=Some {directory="/config/lane-addons";complete=true;
      declarations=[List.hd (Option.get snapshot.configuration).declarations]}} in
  let first = UI.reconcile_snapshot {overview with snapshot=Some empty} first in
  check int "first saved TOML becomes the selected list row" 0 first.instance_cursor;
  check int "Enter opens the first saved TOML" 0
    (UI.open_selected_instance first).configuration_cursor;
  let overview_lines = UI.lines ~width:120 overview in
  check int "overview offers the worker and four configuration issues" 5
    (UI.overview_count snapshot);
  check bool "issue-only rows do not become declared installations" true
    (List.mem "Lane Add-ons · 1 declared · 4 config issues · inventory partial · 1 active · 0 failed workers" overview_lines);
  let issue = UI.open_selected_instance {overview with instance_cursor=1} in
  check bool "Enter opens the exact broken installation" true
    (issue.focus=UI.Configurations && issue.presentation=UI.Technical
     && issue.configuration_cursor=1);
  let raw_issue = UI.lines ~width:120
    {overview with instance_cursor=1; focus=UI.Instances; presentation=UI.Technical} in
  check bool "raw detail follows the selected unresolved installation" true
    (List.exists
      (String.starts_with ~prefix:"> unresolved installation · /config/lane-addons/broken.toml")
      raw_issue
     && not (List.exists (fun line -> String.ends_with ~suffix:"custom.toml" line)
       raw_issue));
  check bool "Installation detail retains the selected source and a return path" true
    (List.exists (String.starts_with ~prefix:"Installation details · broken.toml")
       (UI.lines ~width:120 issue)
     && List.exists (String.starts_with ~prefix:"?:help  Esc:back  E:edit TOML")
       [UI.overview_hints issue]);
  check bool "Installation detail does not offer refresh during an in-flight read" true
    (let lines = UI.lines ~width:120 {issue with loading=true} in
     List.exists (String.starts_with ~prefix:"Esc:back  E:edit TOML  Reading") lines
     && not (List.exists (fun line -> List.mem "r:refresh" (String.split_on_char ' ' line)) lines));
  let directory_issue = UI.open_selected_instance {overview with instance_cursor=2} in
  check bool "directory issue detail does not advertise TOML editing" true
    (not (List.exists (fun line -> List.mem "E:edit" (String.split_on_char ' ' line))
      (UI.lines ~width:120 directory_issue)));
  check bool "failed refresh labels retained Add-on counts stale" true
    (List.exists (String.ends_with ~suffix:" · STALE")
      (UI.lines ~width:120 {overview with snapshot_read_error=Some "read failed"}));
  check bool "a configuration issue has no worker action" true
    (Result.is_error (UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" issue));
  let refreshed = UI.reconcile_snapshot {overview with instance_cursor=1} snapshot in
  check int "refresh keeps a selected issue row" 1 refreshed.instance_cursor;
  let view = {UI.initial with presentation=UI.Technical;focus=UI.Configurations;snapshot=Some snapshot;configuration_cursor=1} in
  check int "partial inventory cannot fabricate subscription choices" 0
    (List.length (UI.subscription_targets view));
  let complete_config = {(Option.get snapshot.configuration) with complete=true} in
  let complete = {snapshot with configuration=Some complete_config} in
  let choices = UI.subscription_targets {view with snapshot=Some complete} in
  check int "declared instance supplies its two actual named outputs" 2 (List.length choices);
  List.iter (fun (target:Masc_tui_lane_subscriptions.target) ->
    check string "subscription uses declared installation identity" "custom" target.installation_id;
    check string "subscription uses actual observed run" "world" target.run_id;
    check string "subscription remembers observed worker" "actual-1" target.instance_id) choices;
  let manual = {complete with instances=List.map (fun (instance:UI.instance) ->
    {instance with source_path=None}) complete.instances} in
  check int "manual instances cannot masquerade as declared producers" 0
    (List.length (UI.subscription_targets {view with snapshot=Some manual}));
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
  check int "unapplied parsed TOML remains selectable" 6 (UI.overview_count past);
  let selected_unapplied = {overview with snapshot=Some past;instance_cursor=1} in
  let unapplied = UI.open_selected_instance selected_unapplied in
  check int "Enter opens the saved declaration without a worker" 0 unapplied.configuration_cursor;
  check (option string) "E can edit the saved declaration from its list row"
    (Some "/config/lane-addons/custom.toml")
    (UI.selected_source_path selected_unapplied);
  check bool "saved declaration is shown without claiming an active worker" true
    (List.exists (String.starts_with ~prefix:"  custom · no current worker · custom.toml")
       (UI.lines ~width:120 {overview with snapshot=Some past}));
  let wrong_source = {snapshot with instances=List.map (fun (i : UI.instance) ->
    {i with source_path=Some "/config/lane-addons/elsewhere.toml"}) snapshot.instances} in
  check int "matching worker ID at another source cannot hide a declaration" 6
    (UI.overview_count wrong_source);
  check (option string) "retained historical source does not authorize a new owner edit" None
    (UI.selected_source_path {view with focus=UI.Instances;snapshot=Some past});
  let lines = UI.lines ~width:100 view in
  check bool "unknown parse identity remains unknown" true
    (List.exists (String.starts_with ~prefix:"> unresolved installation") lines);
  let worker_detail = UI.open_selected_instance {view with focus=UI.Instances;instance_cursor=0} in
  let worker_lines = UI.lines ~width:100
    {worker_detail with focus=UI.Instances;presentation=UI.Technical} in
  check bool "named output is projected without domain branch" true (List.mem "   output metrics → speed" worker_lines);
  check bool "package Skill directory is visible" true (List.mem "   Skills skills" worker_lines);
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
  let view = {UI.initial with presentation=UI.Technical;focus=UI.Timeline;snapshot=Some snapshot;
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
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=0;configuration_revision=None;installation_id=None;source_path=None;binding=`Assoc [];outputs=[];
    skills_directory=None;action_schema=Some schema; binding_schema=None; display=Masc.Lane_addon_presentation.empty} in
  let snapshot : UI.snapshot = {instances=[instance];configuration=None;
    output={rows=[];coverage=[]};complete=Some true} in
  let view = UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" {UI.initial with focus=UI.Instances; snapshot=Some snapshot} |> ok in
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
    (Result.is_error (UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000001" {UI.initial with focus=UI.Instances; snapshot=Some
      {snapshot with instances=[{instance with action_schema=None; binding_schema=None; display=Masc.Lane_addon_presentation.empty}]}}));
  let technical = UI.open_actions ~request_id:first.request_id
    {UI.initial with focus=UI.Instances; presentation=UI.Technical;snapshot=Some snapshot} |> ok in
  check bool "opening actions exposes the choice even from technical mode" true (technical.presentation=UI.Summary);
  List.iter (fun width -> check int "refresh does not move compact content"
    (List.length (UI.lines ~width {UI.initial with focus=UI.Instances; snapshot=Some snapshot}))
    (List.length (UI.lines ~width {UI.initial with focus=UI.Instances; loading=true;snapshot=Some snapshot}))) [10;40;100];
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
  let reverse_view = UI.open_actions ~request_id:first.request_id {UI.initial with focus=UI.Instances;
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
  let compact = UI.lines ~width:100 {UI.initial with focus=UI.Instances; snapshot=Some snapshot} in
  check bool "first screen names installed package" true
    (List.exists (fun line -> String.starts_with ~prefix:"> Useful observer" line) compact);
  let failed = {instance with title="MSX";phase=UI.Row.Failed (String.make 120 'x');
    action_schema=None} in
  let failed_lines = UI.lines ~width:76 {UI.initial with focus=UI.Instances;
    snapshot=Some {snapshot with instances=[failed]}} in
  check bool "failed row keeps retry and cleanup visible with its long reason" true
    (List.exists (String.starts_with ~prefix:"> MSX · failed") failed_lines
     && List.exists (String.starts_with
       ~prefix:"    Enter:open  o:retry observation  d:remove worker") failed_lines
     && List.mem "    D:full ·" failed_lines
     && List.exists (String.starts_with ~prefix:("    " ^ String.make 8 'x')) failed_lines);
  check int "long failure reason survives wrapping" 120
    (List.fold_left (fun total line ->
       String.fold_left (fun total char -> if char='x' then total+1 else total) total line)
       0 failed_lines);
  check bool "technical action schema is folded by default" false
    (List.exists (fun line -> String.contains line '{') compact);
  let form_schema = match schema with
    | `Assoc fields ->
        let properties = match List.assoc "properties" fields with `Assoc p -> p | _ -> assert false in
        let action = Yojson.Safe.from_string
          {|{"type":"object","properties":{"query":{"type":"string","minLength":3}},"required":["query"],"additionalProperties":false}|} in
        `Assoc (("properties",`Assoc (("action",action)::List.remove_assoc "action" properties))::List.remove_assoc "properties" fields)
    | _ -> assert false in
  let form_view = UI.open_actions ~request_id:"01901234-1234-7000-8000-000000000002"
    {UI.initial with focus=UI.Instances; snapshot=Some {snapshot with instances=[{instance with action_schema=Some form_schema}]}} |> ok in
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
      {UI.initial with focus=UI.Instances; snapshot=Some {snapshot with instances=[{instance with action_schema=Some schema}]}} |> ok in
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
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=0;configuration_revision=Some "1";installation_id=Some "project-observer";source_path=Some "/config/project-observer.toml";binding=`Assoc ["sources",`List []];
    outputs=["events",UI.Row.All_lanes];skills_directory=None;action_schema=None; binding_schema=None; display=Masc.Lane_addon_presentation.empty} in
  let consumer = {producer with id="metric-worker";incarnation="metric-worker";title="Project metric";
    installation_id=Some "project-metric";source_path=Some "/config/project-metric.toml";
    binding=Yojson.Safe.from_string {|{"sources":[{"source_id":"input","kind":"lane_output",
      "installation_id":"project-observer","output_id":"events","selection":"latest_completed"},
      {"source_id":"external-fusion","kind":"fusion_run","run_id":"retained-fusion-run"}]}|}} in
  let declaration installation_id instance_id : UI.declaration =
    {source_path="/config/" ^ installation_id ^ ".toml";installation_id=Some installation_id;
      instance_id=Some instance_id;desired=Some "1";applied=Some "1";issues=[];
      origin=UI.Parsed_declaration} in
  let configuration : UI.configuration = {directory="/config";complete=true;
    declarations=[declaration "project-observer" producer.id;declaration "project-metric" consumer.id]} in
  let snapshot : UI.snapshot = {instances=[producer;consumer];configuration=Some configuration;
    output={rows=[];coverage=[]};complete=None} in
  let view = {UI.initial with focus=UI.Connections;presentation=UI.Flow;snapshot=Some snapshot} in
  check bool "flow exposes the selected action target" true
    (List.mem "Action target: Project observer · source-worker" (UI.lines ~width:160 view));
  let links = UI.lines ~width:160 {view with presentation=UI.Summary;
    screen=UI.Detail (producer.id,producer.incarnation);focus=UI.Connections} in
  check bool "embedded Links advertises the first f press accurately" true
    (List.mem "f:open full flow  D:technical details  J/K:scroll" links
     && not (List.mem "f:back to observations  D:technical details  J/K:scroll" links));
  check bool "full Flow keeps its actual return action" true
    (List.mem "f:back to observations  D:technical details  J/K:scroll" (UI.lines ~width:160 view));
  let moved = UI.lines ~width:160 {view with instance_cursor=1} in
  check bool "flow target follows instance selection" true
    (List.mem "Action target: Project metric · metric-worker" moved
      && List.mem "> project-metric · Project metric · attached" moved);
  check bool "flow names the actual configured dependency" true
    (List.mem "  project-observer -> project-metric" (UI.lines ~width:160 view));
  let configured = {view with presentation=UI.Summary;focus=UI.Configurations;
    configuration_cursor=0;instance_cursor=1} in
  let configured_lines = UI.lines ~width:160 configured in
  check (option string) "summary actions target the visibly selected worker despite hidden configuration focus" (Some consumer.id)
    (Option.map (fun (i : UI.instance) -> i.id) (UI.selected_instance configured));
  check (option string) "technical installation actions target their selected declaration" (Some producer.id)
    (Option.map (fun (i : UI.instance) -> i.id)
      (UI.selected_instance {configured with presentation=UI.Technical}));
  check bool "overview starts with its selected worker regardless of hidden focus" true
    (List.exists (String.starts_with ~prefix:"> project-metric · Project metric · attached") configured_lines
     && not (List.exists (String.starts_with ~prefix:"  project-observer · Project observer · attached") configured_lines));
  let observer_lines = UI.lines ~width:160 {configured with instance_cursor=0} in
  check bool "moving selection still exposes the preceding observer" true
    (List.exists (String.starts_with ~prefix:"> project-observer · Project observer · attached") observer_lines
     && List.exists (String.starts_with ~prefix:"  project-metric · Project metric · attached") observer_lines);
  check bool "overview offers help and opening" true
    (List.exists (String.starts_with ~prefix:"?:help  Colon:palette  Esc:back  Enter:open  h:history/current  i:install  n:new  S:subs  A:command  r:refresh") configured_lines);
  check bool "overview omits the old timeline" true
    (not (List.exists (String.starts_with ~prefix:"Activity timeline") configured_lines));
  let worker_lines = UI.lines ~width:160 {configured with focus=UI.Instances} in
  check bool "worker controls remain visible for the selected worker" true
    (List.exists (String.starts_with ~prefix:"    Enter:open  o:observe  d:remove") worker_lines);
  let partial = {snapshot with instances=[consumer];configuration=Some {configuration with complete=false}} in
  let partial_view = {view with snapshot=Some partial;snapshot_read_error=Some "network failure"} in
  let partial_lines = UI.lines ~width:160 partial_view in
  check bool "failed read remains visible in flow" true
    (List.mem "Read: network failure · previous graph retained" partial_lines);
  let unread_lines = UI.lines ~width:160
      {partial_view with snapshot=None} in
  check bool "unread flow does not claim a graph is retained" true
    (List.mem "Read: network failure" unread_lines
     && not (List.mem "Read: network failure · previous graph retained" unread_lines));
  let input_lines = UI.lines ~width:160
      {partial_view with error=Some (UI.Input_failure "choose a worker")} in
  check bool "input and earlier graph read failure remain distinct" true
    (List.mem "Input: choose a worker" input_lines
     && List.mem "Read: network failure · previous graph retained" input_lines);
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

(* Marked rows are frozen with `e`. The choice of Keeper is made by name from
   the workspace roster; before this prompt the only way to name one was the
   raw `:evidence {...,"keeper_name"}` command. The bundle is preserved either
   way, and a failed delivery is reported apart from the frozen bundle. *)
let evidence_export_chooses_a_keeper_by_name () =
  let row ~owner id : UI.Row.row = {id;lane_id=owner ^ "/events";kind=UI.Row.Event;
    title=id;observed_at=1.;subject_id="project";clock=None;actor=None;
    fields=[];evidence=[];related_ids=[]} in
  let worker id : UI.instance = {id;incarnation=id;run_id="project";
    addon_id="fixture";title="Observed value changes";revision="1";phase=UI.Row.Attached;
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=1;configuration_revision=None;installation_id=None;source_path=None;binding=`Assoc ["sources",`List []];
    outputs=[];skills_directory=None;action_schema=None;binding_schema=None;
    display=Masc.Lane_addon_presentation.empty} in
  let snapshot : UI.snapshot = {instances=[worker "worker";worker "other"];
    output={rows=[row ~owner:"worker" "chosen";row ~owner:"worker" "second";row ~owner:"other" "foreign"];coverage=[]};
    complete=Some true;configuration=None} in
  let view = {UI.initial with focus=UI.Timeline;snapshot=Some snapshot;selected=["second";"chosen"]} in
  let opened = UI.open_evidence ~request_id:"fixture-send" ~keepers:["researcher";"imp"] view |> ok in
  let prompt = Option.get opened.evidence_prompt in
  check (list string) "keepers are offered by name in a stable order" ["imp";"researcher"] prompt.keepers;
  check int "preserve only is the default" 0 prompt.choice;
  let lines = UI.lines ~width:100 opened in
  check bool "the prompt names the owner and the count" true
    (List.mem "Preserve 2 marked rows from Observed value changes" lines);
  check bool "the default is marked" true (List.mem "> Preserve only" lines);
  check bool "each Keeper is a choice" true
    (List.mem "  Preserve and send the reference to imp" lines
     && List.mem "  Preserve and send the reference to researcher" lines);
  let bundle = ["instance_id",`String "worker";"row_ids",`List [`String "chosen";`String "second"]] in
  let closed, request = UI.submit_evidence opened |> ok in
  check bool "preserve only sends no keeper" true (request = UI.Evidence (`Assoc bundle));
  check bool "the prompt closes on submit" true (Option.is_none closed.evidence_prompt);
  let moved = UI.move_evidence (UI.move_evidence opened 1) 1 in
  let _, request = UI.submit_evidence moved |> ok in
  check bool "the second choice names the second keeper" true
    (request = UI.Evidence (`Assoc (bundle @ ["keeper_name",`String "researcher"])));
  let broadcast = UI.move_evidence moved 5 in
  check int "the choice stops at Broadcast" 3 (Option.get broadcast.evidence_prompt).choice;
  let submitted, request = UI.submit_evidence broadcast |> ok in
  check bool "Broadcast shares the same selected evidence with no Keeper target" true
    (request = UI.Evidence (`Assoc (bundle @ ["broadcast",`Bool true;"request_id",`String "fixture-send"])));
  let reopened = UI.open_evidence ~request_id:"discarded-new-id" ~keepers:[] submitted |> ok in
  let _, retried = UI.submit_evidence (UI.move_evidence reopened 1) |> ok in
  check bool "unanswered Broadcast retry retains its original identity" true (request=retried);
  let acknowledged = UI.acknowledge_broadcast submitted (`Assoc ["delivery",`Assoc [
    "request_id",`String "fixture-send";"status",`String "committed"]]) in
  let next = UI.open_evidence ~request_id:"new-deliberate-send" ~keepers:[] acknowledged |> ok in
  let _, next_request = UI.submit_evidence (UI.move_evidence next 1) |> ok in
  check bool "new deliberate send after receipt uses a fresh identity" true
    (next_request=UI.Evidence (`Assoc (bundle @ ["broadcast",`Bool true;
      "request_id",`String "new-deliberate-send"])));
  check int "the choice stops at preserve only" 0 (Option.get (UI.move_evidence moved (-5)).evidence_prompt).choice;
  let alone = UI.open_evidence ~request_id:"fixture-send" ~keepers:[] view |> ok in
  check bool "Broadcast remains available without a roster" true
    (List.mem "  Preserve and share the reference via Broadcast" (UI.lines ~width:100 alone));
  check int "without a roster Broadcast is the next choice" 1 (Option.get (UI.move_evidence alone 1).evidence_prompt).choice;
  check bool "rows of two owners are refused before any request" true
    (Result.is_error (UI.open_evidence ~request_id:"fixture-send" ~keepers:["imp"] {view with selected=["chosen";"foreign"]}));
  check bool "nothing marked opens nothing" true
    (Result.is_error (UI.open_evidence ~request_id:"fixture-send" ~keepers:["imp"] {view with selected=[]}));
  check bool "submit without an open prompt is refused" true (Result.is_error (UI.submit_evidence view));
  let evidence = `Assoc ["sha256",`String "abc"] in
  check (list string) "receipt shows the exact owner selection and intended Keeper without claiming a read"
    ["Evidence preserved: 2 rows · sha256 abc";"Evidence owner: worker";
     "Selected row: worker/1/chosen";"Selected row: worker/2/second";
     "Keeper delivery to imp accepted · Keeper reads and actions are unverified"]
    (UI.evidence_receipt_lines (`Assoc ["evidence",evidence;"row_count",`Int 2;
      "instance_id",`String "worker";"row_ids",`List [`String "worker/1/chosen";`String "worker/2/second"];
      "delivery",`Assoc ["destination",`String "keeper";"keeper_name",`String "imp";"status",`String "accepted"]]));
  check (list string) "a failed delivery is reported apart from the frozen bundle"
    ["Evidence preserved: 1 row · sha256 abc";
     "Keeper delivery failed: keeper not found: imp · the bundle stays preserved"]
    (UI.evidence_receipt_lines (`Assoc ["evidence",evidence;"row_count",`Int 1;
      "delivery",`Assoc ["status",`String "failed";"error",`String "keeper not found: imp"]]));
  check (list string) "a receipt without delivery says so"
    ["Evidence preserved: 2 rows · sha256 abc";"Not shared."]
    (UI.evidence_receipt_lines (`Assoc ["evidence",evidence;"row_count",`Int 2]));
  check (list string) "Broadcast publication is not a read receipt"
    ["Evidence preserved: 2 rows · sha256 abc";"Broadcast committed · Keeper reads and actions are unverified"]
    (UI.evidence_receipt_lines (`Assoc ["evidence",evidence;"row_count",`Int 2;
      "delivery",`Assoc ["destination",`String "broadcast";"status",`String "committed"]]));
  let broadcast_receipt = `Assoc ["evidence",evidence;"row_count",`Int 2;
    "delivery",`Assoc ["destination",`String "broadcast";"status",`String "committed"]] in
  let detail = {(UI.open_selected_instance view) with focus=UI.Rows;
    receipt=Some broadcast_receipt} in
  let summary_lines = UI.lines ~width:100 detail in
  check bool "normal Summary visibly confirms the last evidence operation" true
    (List.mem "Last evidence receipt" summary_lines
     && List.mem "Evidence preserved: 2 rows · sha256 abc" summary_lines
     && List.mem "Broadcast committed · Keeper reads and actions are unverified" summary_lines);
  let position value = List.find_index (String.equal value) summary_lines |> Option.get in
  check bool "receipt confirmation precedes potentially long record content" true
    (position "Last evidence receipt" < position "Row chosen");
  let another_worker = {view with instance_cursor=1;receipt=Some broadcast_receipt} in
  check bool "navigation retains an explicitly past receipt without assigning it to another worker" true
    (List.mem "Last evidence receipt" (UI.lines ~width:100 another_worker)
     && Option.map (fun (item : UI.instance) -> item.id) (UI.selected_instance another_worker)=Some "other");
  let overview_with_receipt = UI.lines ~width:40 another_worker in
  let selected_position = List.find_index (String.starts_with ~prefix:"> Observed value changes")
      overview_with_receipt |> Option.get in
  let receipt_position = List.find_index (String.equal "Last evidence receipt")
      overview_with_receipt |> Option.get in
  check bool "Overview presents the selected installation before its retained past receipt" true
    (selected_position < receipt_position);
  let unsafe_receipt = `Assoc ["evidence",evidence;"row_count",`Int 2;
    "delivery",`Assoc ["destination",`String "broadcast";"status",`String "failed";
      "error",`String ("observer\027[2J" ^ String.make 120 'x')]] in
  let narrow = UI.lines ~width:40 {detail with receipt=Some unsafe_receipt} in
  check bool "Summary receipt wraps and escapes external terminal controls" true
    (List.for_all (fun line -> not (String.contains line '\027')
      && Masc_tui_message_layout.display_width line <= 40) narrow);
  check (list string) "uncertain sharing requests verification before resending"
    ["Evidence preserved: 2 rows · sha256 abc";"Broadcast outcome unknown · evidence preserved; verify before resending"]
    (UI.evidence_receipt_lines (`Assoc ["evidence",evidence;"row_count",`Int 2;
      "delivery",`Assoc ["destination",`String "broadcast";"status",`String "outcome_unknown"]]));
  check (list string) "other receipts add nothing" [] (UI.evidence_receipt_lines (`Assoc ["instance_id",`String "x"]))

let refresh_preserves_operator_target () =
  let row id : UI.Row.row = {id;lane_id="worker/events";kind=UI.Row.Event;
    title=id;observed_at=1.;subject_id="project";clock=None;actor=None;
    fields=[];evidence=[];related_ids=[]} in
  let worker id : UI.instance = {id;incarnation=id;run_id="project";
    addon_id="fixture";title=id;revision="1";phase=UI.Row.Attached;
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=1;configuration_revision=None;installation_id=None;source_path=None;binding=`Assoc ["sources",`List []];
    outputs=[];skills_directory=None;action_schema=None;binding_schema=None;
    display=Masc.Lane_addon_presentation.empty} in
  let declaration id : UI.declaration = {source_path=id ^ ".toml";
    installation_id=Some id;desired=Some "1";applied=Some "1";
    instance_id=Some id;issues=[];origin=UI.Parsed_declaration} in
  let snapshot : UI.snapshot = {instances=[worker "worker";worker "other"];
    output={rows=[row "chosen";row "other"];coverage=[]};complete=Some true;
    configuration=Some {directory="/config";complete=true;
      declarations=[declaration "worker";declaration "other"]}} in
  let view = {UI.initial with focus=UI.Instances;snapshot=Some snapshot;scroll=7;selected=["chosen"]} in
  let reordered = {snapshot with instances=List.rev snapshot.instances;
    output={snapshot.output with rows=List.rev snapshot.output.rows};
    configuration=Option.map (fun (c : UI.configuration) -> {c with declarations=List.rev c.declarations}) snapshot.configuration} in
  let refreshed = UI.reconcile_snapshot view reordered in
  check (option string) "worker identity survives reorder" (Some "worker")
    (Option.map (fun (i : UI.instance) -> i.id) (UI.selected_instance refreshed));
  check (option string) "row identity survives reorder" (Some "chosen")
    (Option.map (fun (r : UI.Row.row) -> r.id) (UI.selected_row refreshed));
  check (option string) "declaration identity survives reorder" (Some "worker.toml")
    (Option.map (fun (d : UI.declaration) -> d.source_path) (UI.selected_declaration refreshed));
  check int "refresh retains requested scroll position" 7 refreshed.scroll;
  let removed = UI.reconcile_snapshot refreshed {snapshot with instances=[worker "other"];
    output={snapshot.output with rows=[row "other"]};configuration=None} in
  check bool "removed targets do not select arbitrary replacement" true
    (UI.selected_instance removed=None && UI.selected_row removed=None && UI.selected_declaration removed=None);
  let replaced = UI.reconcile_snapshot view {snapshot with instances=[{(worker "worker") with incarnation="replacement"}]} in
  check bool "new incarnation requires explicit selection" true (UI.selected_instance replaced=None);
  check bool "timeline cannot act through a replaced row owner" true
    (UI.selected_instance {replaced with focus=UI.Timeline}=None);
  let draft = Draft.create "worker.toml" |> ok in
  let editing = UI.put_document {view with focus=UI.Configurations;presentation=UI.Technical} draft in
  let changed declaration instances = UI.reconcile_snapshot editing {snapshot with instances;
    configuration=Some {directory="/config";complete=true;declarations=[declaration]}} in
  List.iter (fun (label,declaration,instances) ->
    let replaced = changed declaration instances in
    check bool (label ^ " invalidates same-path operator selection") true
      (UI.selected_declaration replaced=None && UI.selected_instance replaced=None);
    check bool (label ^ " retains the independent document draft") true
      (UI.selected_document replaced=Some draft))
    ["installation",{(declaration "worker") with installation_id=Some "new-installation"},snapshot.instances;
     "instance",{(declaration "worker") with instance_id=Some "other"},snapshot.instances;
     "run",declaration "worker",[{(worker "worker") with run_id="new-run"}];
     "incarnation",declaration "worker",[{(worker "worker") with incarnation="new-incarnation"}]];
  (* The timeline status line is painted: its warning tone reaches the text
     wrapped in SGR codes, so read the text those codes carry. *)
  let plain line =
    let n = String.length line in
    let buf = Buffer.create n in
    let rec walk i =
      if i < n then
        if line.[i] = '\027' then
          let j = ref (i + 1) in
          while !j < n && line.[!j] <> 'm' do incr j done;
          walk (if !j < n then !j + 1 else !j)
        else (Buffer.add_char buf line.[i]; walk (i + 1)) in
    walk 0;
    Buffer.contents buf in
  let failed = {view with focus=UI.Timeline;snapshot_read_error=Some "network failed"} in
  check bool "stale snapshot exposes refresh failure" true
    (List.exists (fun line -> String.starts_with ~prefix:"Read: network failed" (plain line))
      (UI.lines ~height:24 ~width:120 failed))

let detail_keeps_installation_ownership () =
  let worker id : UI.instance = {id;incarnation=id ^ "-run";run_id="project";
    addon_id="fixture";title=id;revision="1";phase=UI.Row.Attached;
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=2;configuration_revision=Some "1";installation_id=Some id;source_path=Some ("/config/" ^ id ^ ".toml");
    binding=`Assoc ["sources",`List []];outputs=[];skills_directory=None;
    action_schema=None;binding_schema=None;display=Masc.Lane_addon_presentation.empty} in
  let declaration id : UI.declaration = {source_path="/config/" ^ id ^ ".toml";
    installation_id=Some id;desired=Some "1";applied=Some "1";
    instance_id=Some id;issues=[];origin=UI.Parsed_declaration} in
  let row owner lane observed_at : UI.Row.row = {id=owner ^ "-" ^ lane;
    lane_id=owner ^ "/" ^ lane;kind=UI.Row.Value;title=owner ^ " " ^ lane;
    observed_at;subject_id=(if owner="b" && lane="last" then "guest" else "project");
    clock=(if owner="b" && lane="last" then Some {domain="emulator";value="17"} else None);
    actor=(if owner="b" && lane="last" then Some "operator" else None);
    fields=[];evidence=[];related_ids=[]} in
  let snapshot : UI.snapshot = {instances=[worker "a";worker "b"];
    output={rows=[row "a" "first" 1.;row "b" "first" 2.;
      row "a" "last" 3.;row "b" "last" 4.];
      coverage=[{source_id="source-b";incarnation="inc-17";cursor=Some "offset-42";
        complete=false;detail=Some "partial read"}]};complete=Some false;
    configuration=Some {directory="/config";complete=true;
      declarations=[declaration "a";declaration "b"]}} in
  let overview = {UI.initial with snapshot=Some snapshot;focus=UI.Instances;
    instance_cursor=1;configuration_cursor=0;row_cursor=0;selected=["a-first"]} in
  let overview = UI.put_document overview (Draft.create "a.toml" |> ok) in
  let detail = UI.open_selected_instance overview in
  check bool "Enter pins the selected incarnation" true (detail.screen=UI.Detail ("b","b-run"));
  check (list string) "opening detail clears another installation's evidence" [] detail.selected;
  check bool "opening detail clears another installation's active document" true
    (UI.selected_document detail=None);
  check (option string) "Installation E targets the displayed TOML despite global cursor zero"
    (Some "/config/b.toml") (UI.selected_source_path {detail with focus=UI.Configurations});
  let selected_id view = Option.map (fun (r : UI.Row.row) -> r.id) (UI.selected_row view) in
  check (option string) "Records starts at displayed installation" (Some "b-first") (selected_id detail);
  let last = UI.move_record {detail with focus=UI.Rows} 1 in
  let raw = String.concat "" (UI.lines ~width:80 {last with presentation=UI.Technical}) in
  let contains text =
    let n = String.length text in
    let rec at i = i+n <= String.length raw
      && (String.sub raw i n=text || at (i+1)) in
    at 0 in
  List.iter (fun text -> check bool "selected empty-field record keeps its provenance" true
    (contains text))
    ["Row b-last";"Observed 1970-01-01 00:00:04.000 UTC";"Subject guest";
     "Actor operator";"Clock emulator · 17";"Snapshot partial";
     "source-b · partial · incarnation inc-17 · cursor offset-42 · partial read"];
  check bool "raw detail excludes another installation's record" false (contains "Row a-last");
  check (option string) "Records next skips another installation's intervening row"
    (Some "b-last") (selected_id last);
  check (option string) "Records next stays within displayed installation"
    (Some "b-last") (selected_id (UI.move_record last 1));
  check (option string) "Activity next stays within displayed installation"
    (Some "b-last") (selected_id (UI.move_observation detail 1));
  check (option string) "Activity previous lane cannot select another installation"
    (Some "b-first") (selected_id (UI.move_lane detail (-1)));
  let selected = {last with selected=["b-last"]} in
  (match UI.evidence_request selected |> ok with
   | UI.Evidence evidence ->
       check string "export belongs to the displayed installation" "b"
         Yojson.Safe.Util.(evidence |> member "instance_id" |> to_string);
       check (list string) "export contains the displayed record" ["b-last"]
         Yojson.Safe.Util.(evidence |> member "row_ids" |> to_list |> List.map to_string)
   | _ -> fail "expected evidence export");
  check bool "invisible evidence cannot be exported from detail" true
    (Result.is_error (UI.evidence_request {detail with selected=["a-first"]}));
  let replacement = {snapshot with instances=[worker "a";{(worker "b") with incarnation="new-run"}]} in
  let refreshed = UI.reconcile_snapshot selected replacement in
  check bool "replacement cannot inherit old detail's edit or row selection" true
    (UI.selected_instance refreshed=None && UI.selected_row refreshed=None
     && UI.selected_source_path {refreshed with focus=UI.Configurations}=None);
  check bool "replacement cannot inherit old detail's evidence export" true
    (Result.is_error (UI.evidence_request refreshed))

let declared_results_show_body_before_activity_and_keep_raw_evidence () =
  let module P = Masc.Lane_addon_presentation in
  let display = P.of_json (`Assoc ["description",`String "Read an analysis report";
    "readings",`List [
      `Assoc ["lane_id",`String "report";"path",`List [`String "body"];
        "label",`String "Report";"format",`String "text"];
      `Assoc ["lane_id",`String "report";"path",`List [`String "complete"];
        "label",`String "Input complete";"format",`String "boolean"];
      `Assoc ["lane_id",`String "report";"path",`List [`String "delivery"];
        "label",`String "Delivery";"format",`String "text"]]]) |> ok in
  let worker : UI.instance = {id="report-worker";incarnation="incarnation";run_id="project";
    addon_id="custom";title="Project report";revision="1";phase=UI.Row.Attached;
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=1;configuration_revision=None;installation_id=None;source_path=None;binding=`Assoc ["sources",`List []];
    outputs=[];skills_directory=None;action_schema=None;binding_schema=None;display} in
  let row : UI.Row.row = {id="report-row";lane_id="report-worker/report";kind=UI.Row.Value;
    title="Useful analysis";observed_at=1.;subject_id="project";clock=None;actor=None;
    fields=["body",`String "First finding\nSecond finding";"complete",`Bool false;
      "delivery",`String "not attempted";"private_coordinate",`String "retained in raw"];
    evidence=[];related_ids=[]} in
  let snapshot : UI.snapshot = {instances=[worker];output={rows=[row];coverage=[]};
    complete=None;configuration=None} in
  let overview = {UI.initial with snapshot=Some snapshot} in
  check bool "package purpose is visible before opening" true
    (List.mem "    Read an analysis report" (UI.lines ~width:100 overview));
  let detail = UI.open_selected_instance overview in
  let lines = UI.lines ~width:100 detail in
  check bool "body is multiline text, not escaped JSON" true
    (List.mem "  Report: First finding" lines && List.mem "  Second finding" lines);
  check bool "partial input and delivery remain distinct" true
    (List.mem "  Input complete: false" lines && List.mem "  Delivery: not attempted" lines);
  check bool "the visible report carries the selected marker" true
    (List.mem "> Useful analysis" lines);
  let index value = List.find_index (String.equal value) lines |> Option.get in
  check bool "results precede the activity timeline" true
    (index "  Second finding" < index "Activity timeline");
  let raw_lines = UI.lines ~width:100 {detail with presentation=UI.Technical} in
  check bool "raw coordinates remain under details with the JSON formatter's layout" true
    (List.for_all (fun line -> List.mem line raw_lines)
      (String.split_on_char '\n' (Yojson.Safe.pretty_to_string (`Assoc row.fields))));
  let second = {row with id="second-report";title="Another analysis";observed_at=2.;
    fields=["body",`String "Other first finding\nOther second finding";
      "complete",`Bool true;"delivery",`String "not attempted"]} in
  let two = {detail with snapshot=Some {snapshot with output={rows=[row;second];coverage=[]}}} in
  let before = UI.lines ~width:100 two in
  check bool "only the selected report expands its body" true
    (List.mem "> Useful analysis" before && List.mem "  Another analysis" before
     && not (List.mem "  Report: Other first finding" before));
  let moved = UI.move_observation {two with scroll=7} 1 in
  let after = UI.lines ~width:100 moved in
  check int "selecting another report starts at its visible result" 0 moved.scroll;
  check bool "actual activity navigation moves the expanded body and marker together" true
    (List.mem "> Another analysis" after
     && List.mem "  Report: Other first finding" after
     && List.mem "  Other second finding" after
     && not (List.mem "  Report: First finding" after));
  check (option string) "the raw detail target is the visible selected report"
    (Some second.id) (Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row moved));
  let moved_raw = UI.lines ~width:100 {moved with presentation=UI.Technical} in
  check bool "D exposes the same report and excludes the previous one" true
    (List.mem "Row second-report" moved_raw && not (List.mem "Row report-row" moved_raw));
  let unselected = {two with row_cursor=(-1)} in
  let unselected_lines = UI.lines ~width:100 unselected in
  check bool "a vanished selection asks for explicit navigation without choosing a report" true
    (List.mem "Choose a result with j/k." unselected_lines
     && not (List.mem "> Useful analysis" unselected_lines)
     && not (List.mem "  Report: First finding" unselected_lines));
  check (option string) "j explicitly chooses a report from no selection" (Some row.id)
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row (UI.move_observation unselected 1)));
  let missing = {row with fields=[]} in
  let missing_detail = {detail with snapshot=Some {snapshot with output={rows=[missing];coverage=[]}}} in
  check bool "missing declared data is explicitly unavailable" true
    (List.mem "  Report: unavailable · field unavailable" (UI.lines ~width:100 missing_detail));
  let foreign = {row with lane_id="report-worker/other"} in
  check bool "readings are scoped to the exact declared Lane" true
    (not (List.mem "  Report: First finding" (UI.lines ~width:100
      {detail with snapshot=Some {snapshot with output={rows=[foreign];coverage=[]}}})));
  let windows = {row with fields=["body",`String "First\r\n\r\nSecond\rstandalone\r"]} in
  let windows_detail = {detail with snapshot=Some {snapshot with output={rows=[windows];coverage=[]}}} in
  let windows_lines = UI.lines ~width:100 windows_detail in
  check bool "CRLF report lines omit terminator CR and expose standalone CR" true
    (List.mem "  Report: First" windows_lines
     && List.mem "  " windows_lines
     && List.mem "  Second\\x0Dstandalone\\x0D" windows_lines);
  let grade = {row with id="grade";lane_id=worker.id ^ "/grades";
    title="Old grade";observed_at=0.;fields=["grade",`String "incorrect"]} in
  let score = {row with id="score";title="Declared score";observed_at=3.} in
  let score_snapshot = {snapshot with output={rows=[grade;score];coverage=[]}} in
  let preferred = UI.open_selected_instance {overview with snapshot=Some score_snapshot} in
  check (option string) "opening selects declared result after preceding ordinary observations"
    (Some score.id) (Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row preferred));
  let context = {row with id="context";lane_id=worker.id ^ "/report-context";
    title="Internal report context";observed_at=0.;fields=["raw",`String "retained source"]} in
  let with_context = {detail with snapshot=Some
    {snapshot with output={rows=[context;row;second];coverage=[]}};row_cursor=1} in
  let context_lines = UI.lines ~width:100 with_context in
  check (option string) "opening a context-only observation does not select its internal row" None
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row (UI.select_initial_result {with_context with snapshot=Some
        {snapshot with output={rows=[context];coverage=[]}}})));
  let generic = {worker with display=(P.of_json (`Assoc []) |> ok)} in
  check (option string) "packages without presentation keep generic records as results" (Some context.id)
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row (UI.select_initial_result {with_context with snapshot=Some
        {snapshot with instances=[generic];output={rows=[context];coverage=[]}}})));
  check bool "supporting context is not presented as a user result" true
    (not (List.exists (fun line -> String.equal (String.trim line) context.title) context_lines));
  check (option string) "result navigation skips the supporting context" (Some second.id)
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row (UI.move_observation with_context 1)));
  check (option string) "reverse result navigation stops before supporting context" (Some row.id)
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row (UI.move_observation with_context (-1))));
  let context_records = {with_context with focus=UI.Rows;row_cursor=0} in
  check bool "Records retains the exact supporting context" true
    (List.mem "Row context" (UI.lines ~width:100 context_records));
  check bool "supporting context remains explicitly selectable for evidence" true
    (Result.is_ok (UI.evidence_request {context_records with selected=[context.id]}));
  let returned_results = {context_records with focus=UI.Timeline} in
  check (option string) "Records-to-Results transition cannot target hidden context for Space" None
    (Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row returned_results));
  check (option string) "Flow has no invisible record action target" None
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row {returned_results with presentation=UI.Flow}));
  check (option string) "overview Flow has no invisible record action target" None
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row {returned_results with screen=UI.Overview;presentation=UI.Flow}));
  check (option string) "raw details explicitly retain the exact context target" (Some context.id)
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row {returned_results with presentation=UI.Technical}));
  check (option string) "j after returning to Results selects the first displayed report" (Some row.id)
    (Option.map (fun (row : UI.Row.row) -> row.id)
      (UI.selected_row (UI.move_observation returned_results 1)));
  let only_context = {detail with snapshot=Some
    {snapshot with output={rows=[context];coverage=[]}};row_cursor=0} in
  check bool "context-only observations explain that declared results are absent" true
    (List.mem "No declared result rows in this received view." (UI.lines ~width:100 only_context)
     && List.mem "Supporting records remain available in 4 Records." (UI.lines ~width:100 only_context));
  let producer_last = {row with id="last";title="Last result";observed_at=5.} in
  let producer_middle = {row with id="middle";title="Middle result";observed_at=2.} in
  let unsorted = UI.open_selected_instance {overview with snapshot=Some
    {snapshot with output={rows=[producer_last;row;producer_middle];coverage=[]}}} in
  check (option string) "opening uses the same chronology as navigation" (Some row.id)
    (Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row unsorted));
  let unsorted_lines = UI.lines ~width:100 unsorted in
  let index text = List.find_index (String.equal text) unsorted_lines |> Option.get in
  check bool "other results follow the advertised navigation order" true
    (index "  Middle result" < index "  Last result");
  check (option string) "j reaches the next displayed result" (Some producer_middle.id)
    (Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row (UI.move_observation unsorted 1)));
  let retained_worker = {worker with phase=UI.Row.Detached} in
  let other_worker = {worker with id="foreign-worker";incarnation="foreign-incarnation"} in
  let foreign_row = {row with id="foreign-row";lane_id="foreign-worker/report";observed_at=0.} in
  let same_title = {producer_middle with id="middle-a";title=row.title;
    lane_id=worker.id ^ "/other"} in
  let tied = {producer_middle with id="middle-z"} in
  let original_rows = [producer_last;foreign_row;tied;row;same_title] in
  let retained_snapshot = {snapshot with instances=[retained_worker;other_worker];
    output={rows=original_rows;coverage=[]}} in
  let records = {detail with snapshot=Some retained_snapshot;
    screen=UI.Detail (retained_worker.id, retained_worker.incarnation); focus=UI.Rows;
    row_cursor=(List.find_index (fun (candidate : UI.Row.row) -> candidate.id=row.id) original_rows |> Option.get)} in
  let selected_id view = Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row view) in
  let records_lines = UI.lines ~width:100 records in
  let index text = List.find_index (String.equal text) records_lines |> Option.get in
  check bool "Records displays retained owner rows chronologically with deterministic ties" true
    (index ("Row " ^ row.id) < index "Row middle-a"
     && index "Row middle-a" < index "Row middle-z"
     && index "Row middle-z" < index "Row last"
     && not (List.mem "Row foreign-row" records_lines));
  let next = UI.move_record {records with scroll=9} 1 in
  check (option string) "Records j selects the next displayed exact row" (Some same_title.id) (selected_id next);
  check int "Records movement resets document scrolling" 0 next.scroll;
  check (option string) "Records k returns to the displayed predecessor" (Some row.id)
    (selected_id (UI.move_record next (-1)));
  check (option string) "Records timestamp ties use row identity order" (Some tied.id)
    (selected_id (UI.move_record next 1));
  check bool "rendering and navigation preserve immutable producer order" true
    (Option.map (fun (snapshot : UI.snapshot) -> snapshot.output.rows) next.snapshot = Some original_rows);
  let same_title_summary = UI.lines ~width:100 {next with focus=UI.Timeline} in
  check bool "an undeclared record stays out of Results until a result is chosen" true
    (List.mem "Choose a result with j/k." same_title_summary
     && not (List.mem ("  Lane " ^ same_title.lane_id) same_title_summary));
  let same_title_raw = UI.lines ~width:100 {next with presentation=UI.Technical} in
  check bool "raw evidence joins the same selected row and Lane" true
    (List.mem ("Row " ^ same_title.id) same_title_raw
     && List.mem ("Lane " ^ same_title.lane_id) same_title_raw
     && not (List.mem ("Row " ^ row.id) same_title_raw));
  let exported = UI.evidence_request {next with selected=[same_title.id]} |> ok in
  check bool "chronological movement preserves exact export ownership" true
    (exported = UI.Evidence (`Assoc ["instance_id",`String worker.id;
      "row_ids",`List [`String same_title.id]]));
  let many = List.init 6 (fun index -> {worker with id=Printf.sprintf "worker-%d" index;
    title=Printf.sprintf "Worker %d" index;
    display={display with description=Some (String.concat " " (List.init 30 (fun _ -> Printf.sprintf "description-%d" index)))}}) in
  let selected_overview = {overview with instance_cursor=5;snapshot=Some {snapshot with instances=many}} in
  let selected_lines = UI.lines ~width:30 selected_overview in
  let first_rows = List.filteri (fun index _ -> index < 12) selected_lines |> String.concat "\n" in
  check bool "selected Add-on remains near the overview top despite preceding long descriptions" true
    (List.exists (String.starts_with ~prefix:"> Worker 5") (String.split_on_char '\n' first_rows)
     && not (List.exists (fun line -> String.starts_with ~prefix:"    description-4" line) selected_lines))

let empty_completed_results_keep_capability_identity_and_input_details () =
  let display = Masc.Lane_addon_presentation.of_json (`Assoc [
    "description",`String "Combine independent panel answers into a report";
    "readings",`List []]) |> ok in
  let worker installation_id id : UI.instance = {id;incarnation=id;run_id="project";
    addon_id="fusion-compute";title="Shared Fusion package";revision="1";
    phase=UI.Row.Attached;runtime_presence=UI.Live_entry;observation_seq=1;rows_count=0;
    configuration_revision=Some "1";installation_id=Some installation_id;source_path=Some ("/config/" ^ id ^ ".toml");binding=`Assoc ["sources",`List []];
    outputs=[];skills_directory=None;action_schema=None;binding_schema=None;display} in
  let judge = worker "judge" "judge-worker" and panel = worker "panel-a" "panel-worker" in
  let declaration name (item : UI.instance) : UI.declaration = {
    source_path=Option.get item.source_path;installation_id=Some name;
    desired=Some "1";applied=Some "1";instance_id=Some item.id;
    issues=[];origin=UI.Parsed_declaration} in
  let coverage : UI.Row.coverage = {source_id="panel-input";incarnation="unobserved";
    cursor=None;complete=false;detail=Some "Waiting for supplied input observations"} in
  let snapshot : UI.snapshot = {instances=[judge;panel];complete=None;
    configuration=Some {directory="/config";complete=true;
      declarations=[declaration "judge" judge;declaration "panel-a" panel]};
    output={rows=[];coverage=[coverage]}} in
  let overview = {UI.initial with snapshot=Some snapshot} in
  let overview_lines = UI.lines ~width:180 overview in
  check bool "same package installations remain distinguishable" true
    (List.exists (String.starts_with ~prefix:"> judge · Shared Fusion package") overview_lines
     && List.exists (String.starts_with ~prefix:"  panel-a · Shared Fusion package") overview_lines);
  check bool "primary overview counts results instead of observation calls" true
    (List.exists (fun line -> String.ends_with ~suffix:"0 records" line) overview_lines);
  let detail = {overview with screen=UI.Detail (judge.id,judge.incarnation);focus=UI.Timeline} in
  let lines = UI.lines ~width:180 detail in
  check bool "capability description remains visible before any result row" true
    (List.mem "Combine independent panel answers into a report" lines);
  check bool "empty completed observation is not reported as missing observation" true
    (List.mem "Last completed observation contains no result rows." lines
     && not (List.mem "No completed observation received yet." lines));
  check bool "input details are visible with their honest snapshot scope" true
    (List.mem "Received snapshot coverage · all Add-ons" lines
     && List.exists (String.ends_with ~suffix:"Waiting for supplied input observations") lines);
  let changed item = {detail with snapshot=Some {snapshot with instances=[item;panel]}} in
  check bool "first observation remains distinct" true
    (List.mem "No completed observation received yet."
      (UI.lines ~width:180 (changed {judge with observation_seq=0})));
  let failed_lines = UI.lines ~width:180 (changed {judge with phase=UI.Row.Failed "model route unavailable"}) in
  check bool "failed Add-on exposes its actual cause and retry/cleanup controls" true
    (List.mem "Add-on failed: model route unavailable" failed_lines
     && List.mem "o:retry observation  d:remove TOML + worker" failed_lines);
  check bool "filtered view does not claim latest result was empty" true
    (List.mem "No result rows in this received view."
      (UI.lines ~width:180 (changed {judge with rows_count=2})))

let current_installations_and_grouped_history_keep_exact_targets () =
  let worker id run addon phase source_path : UI.instance = {
    id;incarnation=id;run_id=run;addon_id=addon;title="Repeated title";
    revision="1";phase;runtime_presence=UI.Live_entry;observation_seq=1;rows_count=1;configuration_revision=Some "1";installation_id=Option.map (fun _ -> addon) source_path;source_path;
    binding=`Assoc ["sources",`List []];outputs=[];skills_directory=None;
    action_schema=None;binding_schema=None;display=Masc.Lane_addon_presentation.empty} in
  let old = worker "old-a" "project" "analysis" UI.Row.Detached (Some "/config/a.toml") in
  let current = worker "live-a" "project" "analysis" UI.Row.Attached (Some "/config/a.toml") in
  let old_two = {old with id="old-a-two";incarnation="old-a-two"} in
  let other = worker "old-b" "project" "analysis" UI.Row.Detached (Some "/elsewhere/a.toml") in
  let declaration : UI.declaration = {source_path="/config/b.toml";installation_id=Some "b";
    desired=Some "1";applied=Some "1";instance_id=Some "old-b-config";
    issues=["missing image"];origin=UI.Parsed_declaration} in
  let retired_declaration = worker "old-b-config" "project" "b" UI.Row.Detached (Some declaration.source_path) in
  let historical_row : UI.Row.row = {id="old-a/1/result";lane_id="old-a/result";
    kind=UI.Row.Value;title="Old result";observed_at=1.;subject_id="project";
    clock=None;actor=None;fields=[];evidence=[];related_ids=[]} in
  let snapshot : UI.snapshot = {instances=[old;current;other;old_two;retired_declaration];
    configuration=Some {directory="/config";complete=true;declarations=[declaration]};
    output={rows=[historical_row];coverage=[]};complete=None} in
  let view = {UI.initial with snapshot=Some snapshot} in
  check int "current worker and inactive declaration replace repeated retained rows" 2
    (UI.overview_count snapshot);
  check int "every retained incarnation remains available" 4
    (UI.overview_count ~mode:UI.Retained_runs snapshot);
  check (option string) "overview actions target visible live worker, not hidden old worker" (Some current.id)
    (Option.map (fun (item : UI.instance) -> item.id) (UI.selected_instance view));
  List.iter (fun focus ->
    check (option string) "hidden overview focus cannot select a historical row owner" (Some current.id)
      (Option.map (fun (item : UI.instance) -> item.id)
        (UI.selected_instance {view with focus}))) [UI.Timeline;UI.Rows];
  let lines = UI.lines ~width:120 view in
  check bool "history is collapsed to an explicit navigation summary" true
    (List.mem "Retained history · 4 instances · h:open" lines
     && not (List.exists (String.starts_with ~prefix:"    Instance old-") lines));
  let config = UI.open_selected_instance {view with instance_cursor=1} in
  check int "inactive declaration still opens repair details" 0 config.configuration_cursor;
  check (option string) "inactive current declaration cannot advertise its detached worker" None
    (Option.map (fun (item : UI.instance) -> item.id) (UI.selected_instance config));
  let history = UI.toggle_history view in
  check bool "history mode is explicit" true (history.overview_mode=UI.Retained_runs);
  let history_lines = UI.lines ~width:120 history in
  List.iter (fun header ->
    check bool "history identifies the full declaration path and package" true
      (List.mem header history_lines))
    ["/config/a.toml · add-on analysis · run project";
     "/elsewhere/a.toml · add-on analysis · run project"];
  let other_addon = {old with id="old-package";incarnation="old-package";addon_id="other"} in
  let packages = {history with snapshot=Some {snapshot with instances=other_addon::snapshot.instances}} in
  check bool "packages on the same source and run have distinct headers" true
    (List.mem "/config/a.toml · add-on other · run project" (UI.lines ~width:120 packages));
  List.iter (fun id -> check bool "retained run identity is visible" true
    (List.mem ("    Instance " ^ id) history_lines)) ["old-a";"old-a-two";"old-b";"old-b-config"];
  let opened = UI.open_selected_instance history in
  check (option string) "history Enter pins the selected incarnation" (Some "old-a")
    (Option.map (fun (item : UI.instance) -> item.id) (UI.selected_instance opened));
  let refreshed = UI.reconcile_snapshot history
    {snapshot with instances=List.filter (fun (item : UI.instance) -> item.id<>"old-a") snapshot.instances} in
  check int "refresh never selects another retained run when selected run disappears" (-1) refreshed.instance_cursor;
  check (option string) "removed history target cannot become a live action target" None
    (Option.map (fun (item : UI.instance) -> item.id) (UI.selected_instance refreshed));
  let returned = UI.toggle_history refreshed in
  check (option string) "explicit return restores current list selection" (Some "live-a")
    (Option.map (fun (item : UI.instance) -> item.id) (UI.selected_instance returned));
  check bool "detail ignores history toggle and stays pinned" true
    (UI.toggle_history opened = opened);
  let nonzero = {view with instance_cursor=1} in
  let nonzero_history = UI.toggle_history nonzero in
  let reordered = UI.reconcile_snapshot nonzero_history
    {snapshot with instances=worker "new-live" "project" "analysis" UI.Row.Attached None::snapshot.instances} in
  let restored = UI.toggle_history reordered in
  check int "return follows the saved declaration identity after list insertion" 2 restored.instance_cursor;
  check (option string) "nonzero declaration selection survives history navigation" (Some declaration.source_path)
    (Option.map (fun (item : UI.declaration) -> item.source_path)
      (UI.selected_declaration (UI.open_selected_instance restored)));
  let revisit = UI.toggle_history returned in
  check int "a removed retained selection remains unselected when revisiting" (-1) revisit.instance_cursor;
  let no_cached_rows = {snapshot with output={rows=[];coverage=[]}} in
  let empty_open = UI.open_selected_instance {history with snapshot=Some no_cached_rows} in
  check int "opening retained detail before its slice has no invented record" (-1) empty_open.row_cursor;
  let loaded = UI.select_initial_result (UI.reconcile_snapshot empty_open snapshot) in
  check (option string) "fresh scoped records initialize the pinned retained detail" (Some historical_row.id)
    (Option.map (fun (row : UI.Row.row) -> row.id) (UI.selected_row loaded))

let declared_layers_use_exact_configured_owners () =
  let binding upstream = `Assoc ["sources",`List (List.mapi (fun index id ->
    `Assoc ["source_id",`String ("input-" ^ string_of_int index);
      "kind",`String "lane_output";"installation_id",`String id;
      "selection",`String "latest_completed"]) upstream)] in
  let worker id upstream : UI.instance = {id="worker-" ^ id;incarnation="worker-" ^ id;
    run_id="project";addon_id="fixture";title=id;revision="1";phase=UI.Row.Attached;
    runtime_presence=UI.Live_entry;observation_seq=1;rows_count=0;configuration_revision=Some "1";installation_id=Some id;source_path=Some ("/config/" ^ id ^ ".toml");
    binding=binding upstream;outputs=[];skills_directory=None;action_schema=None;
    binding_schema=None;display=Masc.Lane_addon_presentation.empty} in
  let declaration id (item : UI.instance) : UI.declaration = {
    source_path="/config/" ^ id ^ ".toml";installation_id=Some id;
    instance_id=Some item.id;desired=Some "1";applied=Some "1";issues=[];
    origin=UI.Parsed_declaration} in
  let roots = [worker "a" [];worker "b" []] in
  let branches = [worker "c" ["a"];worker "d" ["a";"b"]] in
  let joined = worker "e" ["c";"d"] in
  let configured = roots @ branches @ [joined] in
  let declarations = List.map (fun (item : UI.instance) -> declaration item.title item) configured in
  let snapshot instances declarations : UI.snapshot = {instances;
    configuration=Some {directory="/config";complete=true;declarations};
    output={rows=[];coverage=[]};complete=None} in
  let view instances declarations = {UI.initial with presentation=UI.Flow;
    snapshot=Some (snapshot instances declarations)} in
  let lines instances declarations = UI.lines ~width:200 (view instances declarations) in
  let graph = lines configured declarations in
  List.iter (fun text -> check bool "fan-out and join retain their exact horizontal and vertical layers"
    true (List.mem text graph)) ["Layer 0";"  [a]  |  [b]";
      "Layer 1";"  [c]  |  [d]";"Layer 2";"  [e]"];
  let snapshot_binding path = `Assoc ["sources",`List [
    `Assoc ["source_id",`String "project-input";"kind",`String "snapshot_file";
      "path",`String path]]] in
  let panel_a = {(worker "a" []) with binding=snapshot_binding "/data/research.json";
    rows_count=1} in
  let panel_b = {(worker "b" []) with binding=snapshot_binding "/data/second.json";
    phase=UI.Row.Observing;observation_seq=0} in
  let judge = {(worker "judge" ["a";"b"]) with phase=UI.Row.Failed "provider unavailable";
    rows_count=2} in
  let assembly = [panel_a;panel_b;judge] in
  let assembly_declarations = List.map (fun (item : UI.instance) -> declaration item.title item) assembly in
  let assembly_view = view assembly assembly_declarations in
  let assembly_lines = UI.lines ~width:200 assembly_view in
  List.iter (fun text -> check bool "bound source identity and worker result states remain distinct"
    true (List.mem text assembly_lines)) [
      "  project-input · snapshot /data/research.json -> a";
      "  project-input · snapshot /data/second.json -> b";
      "  [a]  |  [b]";"Layer 1";"  [judge]";
      "    a: attached · last completed: 1 record";
      "    b: observing · no completed observation received";
      "    judge: failed: provider unavailable · last completed: 2 records";
      "No evidence sharing receipt in this session."];
  let shared = UI.lines ~width:200 {assembly_view with receipt=Some (`Assoc [
    "row_count",`Int 1;"evidence",`Assoc ["sha256",`String "fixture-sha"];
    "delivery",`Assoc ["destination",`String "broadcast";"status",`String "committed"]])} in
  check bool "connection view exposes session sharing without asserting agent reading" true
    (List.mem "Last evidence sharing receipt · this session" shared
     && List.mem "Evidence preserved: 1 row · sha256 fixture-sha" shared
     && List.mem "Broadcast committed · Keeper reads and actions are unverified" shared);
  let unrelated_receipt = UI.lines ~width:200
    {assembly_view with receipt=Some (`Assoc ["instance_id",`String "worker-a"])} in
  check bool "a worker action receipt never proves evidence sharing" true
    (List.mem "No evidence sharing receipt in this session." unrelated_receipt);
  let cycle = [worker "a" ["b"];worker "b" ["a"]] in
  let cyclic = lines cycle (List.map (fun (item : UI.instance) -> declaration item.title item) cycle) in
  check bool "a dependency cycle never receives an execution layer" true
    (not (List.mem "Layer 0" cyclic)
     && List.mem "Layer unavailable: a" cyclic && List.mem "Layer unavailable: b" cyclic);
  let producer = worker "a" [] in
  let consumer = worker "consumer" ["a"] in
  let assert_unplaced label producer declarations consumer =
    let graph = lines [producer;consumer] declarations in
    check bool (label ^ " cannot supply the consumer's configured upstream") true
      (List.mem "Layer unavailable: consumer" graph && not (List.mem "  [consumer]" graph)) in
  let consumer_declaration = declaration "consumer" consumer in
  assert_unplaced "missing applied installation" {producer with installation_id=None} [consumer_declaration] consumer;
  assert_unplaced "wrong applied installation" {producer with installation_id=Some "other"}
    [declaration "a" producer;consumer_declaration] consumer;
  assert_unplaced "another run" {producer with run_id="other-project"}
    [declaration "a" producer;consumer_declaration] consumer;
  let manual = {producer with id="manual-uuid";installation_id=None;source_path=None} in
  let uuid_consumer = {consumer with binding=binding [manual.id]} in
  assert_unplaced "manual worker UUID" manual [consumer_declaration] uuid_consumer;
  check bool "declaration ambiguity does not erase an exact applied worker owner" true
    (List.mem "  a -> consumer" (lines [producer;consumer]
      [declaration "a" producer;declaration "a" producer;consumer_declaration]));
  let named_consumer port = {consumer with binding=`Assoc ["sources",`List [
    `Assoc ["source_id",`String "analysis-input";"kind",`String "lane_output";
      "installation_id",`String "a";"output_id",`String port;
      "selection",`String "latest_completed"]]]} in
  let advertised = {producer with outputs=["events",UI.Row.All_lanes]} in
  let known_port = lines [advertised;named_consumer "events"]
    [declaration "a" advertised;consumer_declaration] in
  check bool "a declared advertised port connects the consumer layer and preserves its source selection" true
    (List.mem "Layer 1" known_port && List.mem "  [consumer]" known_port
     && List.mem "  a -> consumer" known_port
     && List.mem "    Input analysis-input: a/events" known_port);
  let unknown_port = lines [advertised;named_consumer "missing-port"]
    [declaration "a" advertised;consumer_declaration] in
  check bool "an unknown output port cannot receive a layer or an unqualified available arrow" true
    (List.mem "Layer unavailable: consumer" unknown_port
     && List.mem "  Producer output unavailable: a/missing-port" unknown_port
     && List.mem "  a -> consumer · producer output unavailable: missing-port" unknown_port
     && not (List.mem "  a -> consumer" unknown_port));
  let duplicate = {producer with id="worker-a-two";incarnation="worker-a-two"} in
  let ambiguous_declaration = {(declaration "a" producer) with instance_id=None} in
  let ambiguous = lines [producer;duplicate;consumer]
    [ambiguous_declaration;consumer_declaration] in
  check bool "duplicate current producer identity is qualified in the flat wiring list" true
    (List.mem "  a -> consumer · producer identity ambiguous across live workers" ambiguous
     && List.mem "Layer unavailable: consumer" ambiguous);
  let other_run = {duplicate with run_id="another-project"} in
  let cross_run = lines [producer;other_run;consumer] [consumer_declaration] in
  check bool "all live owners are counted before selecting a run" true
    (List.mem "Layer unavailable: consumer" cross_run
     && List.mem "  a -> consumer · producer identity ambiguous across live workers" cross_run);
  let prior = {producer with runtime_presence=UI.Retained_binding;
    phase=UI.Row.Failed "previous process; explicit detach can verify container cleanup"} in
  assert_unplaced "previous-process record" prior [consumer_declaration] consumer;
  let stored = lines [prior;consumer] [consumer_declaration] in
  check bool "stored failure remains visible without a layer" true
    (List.mem "Layer unavailable: a" stored
     && List.mem "  No live runtime entry; stored binding cannot supply output" stored);
  let with_prior = lines [producer;{prior with id="prior-a"};consumer] [consumer_declaration] in
  check bool "retained owner does not create false ambiguity" true
    (List.mem "  a -> consumer" with_prior);
  assert_unplaced "unknown runtime presence" {producer with runtime_presence=UI.Presence_unknown}
    [consumer_declaration] consumer;
  let retired = {producer with phase=UI.Row.Detached;runtime_presence=UI.Retained_binding} in
  let history = UI.lines ~width:200
    {(view [retired] [declaration "a" retired]) with overview_mode=UI.Retained_runs} in
  check bool "stored retired wiring is never presented as a current layer" true
    (List.mem "Stored bindings · producer incarnations are not reconstructed as current layers" history
     && not (List.mem "Layer 0" history))

let () = run "TUI Lane package operations" ["operator scenarios",[
  test_case "empty completed results show capability, identity and input details" `Quick
    empty_completed_results_keep_capability_identity_and_input_details;
  test_case "declared layers use exact configured owners" `Quick
    declared_layers_use_exact_configured_owners;
  test_case "current installations and grouped retained runs preserve exact targets" `Quick
    current_installations_and_grouped_history_keep_exact_targets;
  test_case "declared results show body before activity and preserve raw evidence" `Quick
    declared_results_show_body_before_activity_and_keep_raw_evidence;
  test_case "detail keeps installation ownership for edit, navigation and export" `Quick detail_keeps_installation_ownership;
  test_case "refresh retains exact operator targets and exposes failure" `Quick refresh_preserves_operator_target;
  test_case "evidence export chooses a Keeper by name" `Quick evidence_export_chooses_a_keeper_by_name;
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
