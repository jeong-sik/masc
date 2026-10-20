open Alcotest
module Catalog = Masc_tui_resource_catalog
module Published = Masc.Published_artifact
module Updates = Masc_tui_resources_updates

let get = function Ok value -> value | Error error -> fail error
let refused = function Error _ -> () | Ok _ -> fail "invalid report was admitted"
let id = "artifact-0123456789abcdef0123456789abcdef"
let markdown = "# 보고서 🎵\r\n\r\n| 음 | 값 |\r\n|---|---|\r\n| C | 36 |\r\n"
let html = "<!doctype html>\r\n<script>window.location='/secret'</script>\t<p>원문</p>"
let revision ?(format=Published.Markdown) ?(number=1) content =
  let body = get (Result.map_error Tool_output.make_error_to_string
    (Tool_output.make_artifact_ref ~sha256:Digestif.SHA256.(to_hex (digest_string content))
      ~bytes:(String.length content) ~preview:content ~mime:(Published.media_type format))) in
  { Published.revision = number; title = "음악 보고서"; summary = "원문";
    format; author = "keeper"; created_at = "2026-10-21T00:00:00Z"; body;
    task_id = None; goal_id = None }
let summary revision = Published.summary_to_json ~id revision
let listing revisions diagnostics = `Assoc [
  "artifacts", `List (List.map summary revisions); "diagnostics", `List diagnostics]
let entry revision =
  match get (Catalog.reports_of_json (listing [revision] [])) with
  | [entry], [] -> entry
  | _ -> fail "expected report"
let report entry = match Catalog.key entry with
  | Catalog.Report_revision report -> report
  | Catalog.Mcp_uri _ -> fail "expected report transport"
let detail selected revisions content = `Assoc [
  "artifact", summary selected; "content", `String content;
  "revisions", `List (List.map Published.revision_to_json revisions)]
let rewrite name value = function
  | `Assoc fields -> `Assoc (List.map (fun (key, original) -> key, if key=name then value else original) fields)
  | _ -> fail "expected object"
let state () = Masc_tui_types.create_state ~workspace:"reports" ~port:0 ~refresh_interval:0. ()

let exact_revision () =
  let first = revision markdown in
  let second = revision ~number:2 "# revised" in
  let selected = entry first in
  let report = report selected in
  check string "read pins listed revision" ("/api/v1/published-artifacts/" ^ id ^ "?revision=1")
    (Catalog.report_path report);
  let reading = get (Catalog.report_contents report (detail first [second;first] markdown)) in
  let parts = reading.parts in
  (match parts with
   | [{ Masc_tui_mcp.rc_kind = Resource_text raw; _ }] -> check string "UTF8/CRLF exact source" markdown raw
   | [{ Masc_tui_mcp.rc_kind = Resource_blob _; _ }] | [] | _ :: _ :: _ -> fail "original text missing");
  refused (Catalog.report_contents report (detail second [second;first] "# revised"));
  refused (Catalog.report_contents report (detail first [first] (markdown ^ " ")));
  let changed = String.mapi (fun i c -> if i=0 then '!' else c) markdown in
  refused (Catalog.report_contents report (detail first [first] changed));
  refused (Catalog.report_contents report (detail first [second] markdown))

let html_source () =
  let selected = revision ~format:Published.Html html in
  let entry = entry selected in
  let reading = get (Catalog.report_contents (report entry) (detail selected [selected] html)) in
  let contents = reading.parts in
  let state = state () in
  let key = Catalog.key entry in
  state.resource_pending_key <- Some key;
  let owner = ref () in
  state.resource_read_owner <- Some owner;
  Updates.read_done state ~request:{Catalog.key;owner} (Ok reading);
  check bool "admission retains immutable original" true
    (match state.resource_content with Some (_, actual) -> actual == contents | None -> false);
  match contents with
  | [{ Masc_tui_mcp.rc_mime_type = Some mime; rc_kind = Resource_text raw; _ }] ->
    check string "HTML format retained" "text/html" mime;
    check string "HTML original retained as text" html raw
  | [{ Masc_tui_mcp.rc_kind = (Resource_blob _ | Resource_text _); _ }] | [] | _ :: _ :: _ -> fail "expected HTML source part"

let invalid_catalog () =
  let first = revision markdown in
  let wire = summary first in
  List.iter (fun invalid -> refused (Catalog.reports_of_json
    (`Assoc ["artifacts", `List [invalid]; "diagnostics", `List []])))
    [rewrite "url" (`String "https://evil.example/secret") wire;
     rewrite "id" (`String "../outside") wire;
     rewrite "format" (`String "pdf") wire;
     rewrite "format" (`String "html") wire;
     rewrite "revision" (`Int 0) wire];
  refused (Catalog.reports_of_json (listing [first;first] []))

let partial_sources () =
  let report = entry (revision markdown) in
  let mcp = { Masc_tui_mcp.uri = "masc://status"; name = "status"; title=None;
    description=None; mime_type=Some "application/json"; size=None } in
  let partial = get (Catalog.combine (Ok ([mcp], `Complete)) (Error "403")) in
  check int "MCP survives report refusal" 1 (List.length partial.entries);
  check bool "refusal visible" true (partial.notes <> []);
  let partial = get (Catalog.combine (Error "session failed") (Ok ([report], []))) in
  check bool "report survives MCP refusal" true (partial.entries = [report]);
  refused (Catalog.combine (Error "MCP failed") (Error "reports failed"));
  let _, diagnostics = get (Catalog.reports_of_json (listing []
    [`Assoc ["id", `String "broken"; "error", `String "body unavailable"]])) in
  check bool "storage diagnostics retained" true (diagnostics <> [])

let selection_and_withdrawal () =
  let first = entry (revision markdown) in
  let second = entry (revision ~number:2 "new revision") in
  let state = state () in
  let list entry = Updates.listed state (Ok { Catalog.entries=[entry]; notes=[] }) in
  list first;
  let opened = ref None in
  Updates.open_selected state ~read:(fun ~key:uri -> opened := Some uri);
  check bool "selection carries exact typed read" true (!opened = Some (Catalog.key first));
  state.resource_content <- Some (Catalog.key first, []);
  list first;
  check bool "unchanged listing keeps reading" true (Option.is_some state.resource_content);
  list second;
  check bool "listed report keeps explicitly pinned reading" true (Option.is_some state.resource_content);
  state.resource_pending_key <- Some (Catalog.key second);
  let owner = ref () in
  state.resource_read_owner <- Some owner;
  Updates.read_done state ~request:{Catalog.key=Catalog.key first;owner} (Ok (Catalog.mcp_reading []));
  check bool "late revision cannot settle new one" true (state.resource_pending_key=Some (Catalog.key second));
  Updates.listed state (Ok (get (Catalog.combine (Ok ([], `Complete)) (Error "403"))));
  check bool "revoked report loses pending ownership" true (state.resource_pending_key=None);
  Updates.read_done state ~request:{Catalog.key=Catalog.key second;owner} (Ok (Catalog.mcp_reading []));
  check bool "revoked late reply cannot restore content" true (state.resource_content=None)

let transport_identity () =
  let report = entry (revision markdown) in
  let mcp = Catalog.Mcp { (Catalog.metadata report) with name="same URI, another authority" } in
  check bool "URI collision cannot cross authority" false
    (Catalog.equal_key (Catalog.key report) (Catalog.key mcp))

let history () =
  let first = revision "one" in
  let second = revision ~number:2 "two" in
  let third = revision ~number:3 "three" in
  let current = report (entry second) in
  let reading = get (Catalog.report_contents current (detail second [third;second;first] "two")) in
  first, second, third, current, reading

let revision_requests () =
  let _, _, _, current, reading = history () in
  let state = state () in
  state.resource_content <- Some (Catalog.Report_revision current, reading.parts);
  state.resource_revision_history <- reading.revisions;
  let requests = ref [] in
  let read ~key = requests := key :: !requests;
    Masc_tui_types.retain_resource_read state ~key in
  Updates.step_revision state ~direction:Catalog.Older ~read;
  let first = match !requests with
    | [Catalog.Report_revision report] -> report
    | [] | Catalog.Mcp_uri _ :: _ | Catalog.Report_revision _ :: _ -> fail "older request missing" in
  check int "older exact revision" 1 first.revision.revision;
  check string "older fixed API path" ("/api/v1/published-artifacts/" ^ id ^ "?revision=1") (Catalog.report_path first);
  check bool "history is not a loaded body" true (state.resource_content=None);
  Updates.step_revision state ~direction:Catalog.Older ~read;
  check int "oldest does not wrap" 1 (List.length !requests);
  Updates.step_revision state ~direction:Catalog.Newer ~read;
  Updates.step_revision state ~direction:Catalog.Newer ~read;
  Updates.step_revision state ~direction:Catalog.Newer ~read;
  check int "newest does not wrap" 3 (List.length !requests);
  (match state.resource_pending_key with
   | Some (Catalog.Report_revision report) -> check int "rapid navigation uses pending revision" 3 report.revision.revision
   | Some (Catalog.Mcp_uri _) | None -> fail "newest request missing");
  Masc_tui_types.retain_resource_read state ~key:(Catalog.Mcp_uri "masc://next");
  Updates.step_revision state ~direction:Catalog.Older ~read;
  check int "MCP has no report revision requests" 3 (List.length !requests);
  check bool "switch withdraws report history" true (state.resource_revision_history=[])

let pinned_refresh () =
  let _, _, third, current, reading = history () in
  let state = state () in
  state.resource_content <- Some (Catalog.Report_revision current, reading.parts);
  state.resource_revision_history <- reading.revisions;
  Updates.listed state (Ok {Catalog.entries=[entry third];notes=[]});
  check bool "latest refresh retains older original" true
    (match state.resource_content with Some (_,parts) -> parts==reading.parts | None -> false);
  (match Catalog.entry_for_key [entry third] (Catalog.Report_revision current) with
   | Some (Catalog.Report report) -> check int "detail remains selected revision" 2 report.revision.revision
   | Some (Catalog.Mcp _) | None -> fail "pinned detail lost");
  Updates.listed state (Ok {Catalog.entries=[];notes=[]});
  check bool "withdrawal clears body and history" true
    (state.resource_content=None && state.resource_revision_history=[] && state.resource_read_owner=None)

let superseded_same_key () =
  let _, _, _, current, reading = history () in
  let state = state () in
  let key = Catalog.Report_revision current in
  let old_owner = ref () and new_owner = ref () in
  state.resource_pending_key <- Some key;
  state.resource_read_owner <- Some new_owner;
  Updates.read_done state ~request:{Catalog.key;owner=old_owner} (Ok reading);
  check bool "same key old request cannot settle newer read" true
    (state.resource_content=None && state.resource_pending_key=Some key);
  Updates.read_done state ~request:{Catalog.key;owner=new_owner} (Ok reading);
  check bool "current request admits original" true
    (match state.resource_content with Some (_,parts) -> parts==reading.parts | None -> false);
  Updates.read_done state ~request:{Catalog.key;owner=old_owner} (Error "old failure");
  check bool "detached error cannot replace admitted source" true (state.resource_content_error=None)

let failed_revision_navigation () =
  let _, _, _, current, reading = history () in
  let state = state () in
  let key = Catalog.Report_revision current and owner=ref () in
  state.resource_revision_history <- reading.revisions;
  state.resource_pending_key <- Some key; state.resource_read_owner <- Some owner;
  Updates.read_done state ~request:{Catalog.key;owner} (Error "revision unavailable");
  let next = ref None in
  Updates.step_revision state ~direction:Catalog.Newer ~read:(fun ~key -> next := Some key);
  (match !next with
   | Some (Catalog.Report_revision report) -> check int "failure can navigate to known neighbor" 3 report.revision.revision
   | Some (Catalog.Mcp_uri _) | None -> fail "neighbor after failure missing");
  check bool "failed body never fabricated from history" true (state.resource_content=None)

let () = run "published report resources" ["report reading",[
  test_case "pinned revision and body integrity" `Quick exact_revision;
  test_case "HTML original admission" `Quick html_source;
  test_case "malformed inventory refused" `Quick invalid_catalog;
  test_case "partial inventories and diagnostics" `Quick partial_sources;
  test_case "selection revision and revocation ownership" `Quick selection_and_withdrawal;
  test_case "separate read authority" `Quick transport_identity;
  test_case "exact neighboring revision requests" `Quick revision_requests;
  test_case "pinned refresh and withdrawal" `Quick pinned_refresh;
  test_case "same key new request ownership" `Quick superseded_same_key;
  test_case "navigation after a refused revision" `Quick failed_revision_navigation]]
