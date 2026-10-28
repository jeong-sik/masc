open Alcotest
module Tui_decode = Masc.Tui_decode
module Types = Masc_tui_types
module Mcp = Masc_tui_mcp
module Catalog = Masc_tui_resource_catalog
module Doc = Masc_tui_resource_document
module Updates = Masc_tui_resources_updates
module Reading = Masc_tui_resource_reading

let key = Catalog.Mcp_uri "masc://report"
let text source = { Mcp.rc_uri=Some "file:///never-followed";
  rc_mime_type=Some "application/json";rc_kind=Mcp.Resource_text source }
let blob = { Mcp.rc_uri=Some "file:///never-decoded";
  rc_mime_type=Some "image/png";rc_kind=Mcp.Resource_blob {base64="QUJD"} }
let raw = "{\r\n\t\"원문🎵\": 1\r\n}\000\027[31m"
let parts = [blob;text raw;blob;text "<p>second\tpart</p>";text ""]
let state () =
  let s=Types.create_state ~workspace:"copy" ~port:0 ~refresh_interval:0. () in
  s.server_identity <- Some {Tui_decode.sid_version="test";sid_binary_commit="test";
    sid_binary_commit_age_s=None;sid_base_path=Tui_decode.Canonical_path.of_path "/workspace";
    sid_masc_root=Tui_decode.Canonical_path.of_path "/workspace/.masc";
    sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
    sid_sse_clients=None;sid_gc=None;sid_scheduler=None};
  s.workspace_identity <- Types.Workspace_identity_match;
  s.view <- Types.Resources;
  s.resource_focus <- Types.Right_pane;
  s.resources_list <- Some [Catalog.Mcp {Mcp.uri="masc://report";name="report";
    title=None;description=None;mime_type=Some "text/plain";size=None}];
  s.resource_content <- Some (key,parts); s
let source s = match Doc.copy_source s with
  | Ok (_,raw) -> raw | Error detail -> fail detail
let refused s = match Doc.copy_source s with
  | Error _ -> () | Ok _ -> fail "unreadable source was copied"
let unchanged s original =
  check bool "original part list retained" true
    (match s.Types.resource_content with Some (_,parts) -> parts == original | None -> false)

let exact_source () =
  let s=state () in
  Updates.place_search_match s ~cols:120 ~query:"원문" ~count:30 ~index:23;
  s.resource_scroll <- Masc_tui_scroll.Position.at 17;
  check string "original source bytes, not a display projection" raw (source s);
  check int "copy leaves scroll" 17 (Masc_tui_scroll.Position.offset ~count:40 ~height:1 s.resource_scroll);
  check int "copy leaves logical match" 23 (Reading.cursor s.resource_search_position);
  check int "copy leaves catalog selection" 0 s.resources_cursor;
  unchanged s parts
let selection () =
  let s=state () in
  check int "only text parts selectable" 3 (Doc.text_part_count s);
  Updates.step_text_part s ~delta:(-1);
  check int "first clamps" 0 s.resource_text_cursor;
  Updates.step_text_part s ~delta:1;
  check string "selected part alone" "<p>second\tpart</p>" (source s);
  Updates.step_text_part s ~delta:1;
  check string "empty text is an exact original" "" (source s);
  Updates.step_text_part s ~delta:1;
  check int "last clamps" 2 s.resource_text_cursor;
  unchanged s parts
let pending_same () =
  let s=state () in s.resource_pending_key<-Some key;
  refused s; Updates.step_text_part s ~delta:1;
  check int "pending read cannot move retained selection" 0 s.resource_text_cursor
let pending_other () =
  let s=state () in s.resource_pending_key<-Some (Catalog.Mcp_uri "masc://other"); refused s
let failure () =
  let s=state () in s.resource_content_error<-Some (key,"403"); refused s; unchanged s parts
let withdrawal () =
  let s=state () in s.resources_list<-Some []; refused s
let unread () = let s=state () in s.resource_content<-None; refused s
let focus () =
  let s=state () in s.resource_focus<-Types.Left_pane;refused s;
  Updates.step_text_part s ~delta:1;
  check int "list focus leaves text selection" 0 s.resource_text_cursor;
  s.resource_focus<-Types.Right_pane;s.view<-Types.Code;refused s;
  Updates.step_text_part s ~delta:1;
  check int "other view leaves text selection" 0 s.resource_text_cursor
let authority () =
  let s=state () in s.server_identity<-None;refused s;
  let s=state () in
  s.workspace_identity<-Types.Workspace_identity_match_unconfirmed "refresh refused";
  refused s
let clipboard_request () =
  let s=state () in
  let request=Masc_tui_link.osc52_copy (source s) in
  let prefix="\027]52;c;" in
  check bool "clipboard write protocol" true (String.starts_with ~prefix request);
  check char "OSC terminator" '\007' request.[String.length request - 1];
  let encoded=String.sub request (String.length prefix)
      (String.length request - String.length prefix - 1) in
  match Base64.decode encoded with
  | Ok bytes -> check string "terminal request preserves original bytes" raw bytes
  | Error (`Msg detail) -> fail detail
let binary_only () = let s=state () in s.resource_content<-Some(key,[blob]);refused s

let public_link () =
  let previous = Sys.getenv_opt "MASC_HTTP_BASE_URL" in
  Fun.protect
    ~finally:(fun () -> match previous with
      | Some value -> Unix.putenv "MASC_HTTP_BASE_URL" value
      | None -> Unix.unsetenv "MASC_HTTP_BASE_URL")
    (fun () ->
      Unix.putenv "MASC_HTTP_BASE_URL" "https://reports.example";
      let body = match Tool_output.make_artifact_ref
        ~sha256:"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        ~bytes:4 ~preview:"test" ~mime:"text/markdown" with
        | Ok body -> body | Error _ -> fail "body fixture rejected" in
      let revision = { Masc.Published_artifact.revision=3; title="report"; summary="summary";
        format=Markdown; author="keeper"; created_at="2026-10-22T00:00:00Z";
        body; task_id=None; goal_id=None } in
      let id = "artifact-0123456789abcdef0123456789abcdef" in
      let json = `Assoc ["artifacts", `List [Masc.Published_artifact.summary_to_json ~id revision];
        "diagnostics", `List []] in
      let report = match Catalog.reports_of_json json with
        | Ok ([Catalog.Report report], []) -> report
        | Ok _ | Error _ -> fail "report fixture rejected" in
      let report_from_summary id revision =
        let json = `Assoc ["artifacts", `List [Masc.Published_artifact.summary_to_json ~id revision];
          "diagnostics", `List []] in
        match Catalog.reports_of_json json with
        | Ok ([Catalog.Report report], []) -> report
        | Ok _ | Error _ -> fail "additional report fixture rejected" in
      let older = report_from_summary id {revision with revision=2} in
      let other = report_from_summary "artifact-ffffffffffffffffffffffffffffffff" revision in
      let s = state () in
      let report_key = Catalog.Report_revision report in
      let older_key = Catalog.Report_revision older in
      let other_key = Catalog.Report_revision other in
      s.resources_list <- Some [Catalog.Report report];
      s.resource_content <- Some (report_key, [text "test"]);
      let refused () = match Doc.copy_public_url s with
        | Error _ -> () | Ok _ -> fail "link copied without a current shared reading" in
      s.resource_shared <- None; refused ();
      s.resource_shared <- Some false; refused ();
      check bool "known private report can be shared" true
        (match Doc.external_share_change s with Ok (current, true) -> current.id = id | Ok _ | Error _ -> false);
      s.resource_shared <- Some true;
      let url = match Doc.copy_public_url s with Ok url -> url | Error detail -> fail detail in
      check string "public link pins the admitted revision"
        ("https://reports.example/dashboard/#/workspace?section=artifacts&artifact=" ^ id ^ "&revision=3") url;
      let owner = ref () in
      s.resource_pending_key <- Some report_key; s.resource_read_owner <- Some owner;
      let request = match Updates.begin_share_change s ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      check bool "request captures workspace and target" true
        (request.share_workspace = s.workspace_authority && not request.share_target);
      check bool "another sharing change cannot overlap" true
        (Result.is_error (Updates.begin_share_change s ~report ~shared:true));
      Updates.read_done s ~request:{Catalog.key=report_key;owner}
        (Ok {Catalog.parts=[text "test"];revisions=[report];shared=Some true;share_version=Some 1});
      check (option bool) "older read cannot restore the share state" None s.resource_shared;
      refused ();
      Types.retain_resource_read s ~key:older_key;
      let during_owner = ref () in
      s.resource_read_owner <- Some during_owner;
      let during_parts = [text "body read during write"] in
      Updates.read_done s ~request:{Catalog.key=older_key;owner=during_owner}
        (Ok {Catalog.parts=during_parts;revisions=[report;older];shared=Some true;share_version=Some 1});
      check bool "a read during the write retains its body" true
        (match s.resource_content with Some (_, parts) -> parts == during_parts | None -> false);
      check (option bool) "a read during the write cannot admit sharing" None s.resource_shared;
      check bool "a read during the write cannot authorize a toggle" true
        (Result.is_error (Doc.external_share_change s));
      refused ();
      Types.retain_resource_read s ~key:older_key;
      let late_owner = ref () in
      s.resource_read_owner <- Some late_owner;
      let impostor = {request with share_owner=ref ()} in
      check bool "a different owner cannot settle the operation" true
        (Option.is_none (Updates.share_changed s impostor ~result:(Error "unowned")));
      check bool "an unowned error cannot mark sharing uncertain" false
        (Types.resource_share_uncertain s report);
      check bool "the real operation remains pending" true
        (match s.resource_share_pending with
         | Some pending -> pending.share_owner == request.share_owner | None -> false);
      check bool "settlement returns the current fixed report key" true
        (match Updates.share_changed s request ~result:(Ok false) with
         | Some key -> Catalog.equal_key key older_key | None -> false);
      Updates.read_done s ~request:{Catalog.key=older_key;owner=late_owner}
        (Ok {Catalog.parts=[text "late"];revisions=[report;older];shared=Some true;share_version=Some 1});
      check (option bool) "a read launched during the write is retired on settlement" None s.resource_shared;
      check bool "operation settlement is consumed once" true
        (Option.is_none (Updates.share_changed s request ~result:(Error "late")));
      check bool "a late error cannot mark sharing uncertain" false
        (Types.resource_share_uncertain s report);
      Types.retain_resource_read s ~key:older_key;
      let fresh_owner = ref () in
      s.resource_read_owner <- Some fresh_owner;
      Updates.read_done s ~request:{Catalog.key=older_key;owner=fresh_owner}
        (Ok {Catalog.parts=[text "test"];revisions=[report;older];shared=Some false;share_version=Some 1});
      check (option bool) "a fresh post-settlement observation is admitted" (Some false) s.resource_shared;
      s.resource_shared <- Some true;
      s.resource_pending_key <- Some report_key; refused ();
      s.resource_pending_key <- None;
      s.resource_content_error <- Some (report_key, "body unavailable");
      check bool "known shared report can be revoked after a failed read" true
        (match Doc.external_share_change s with Ok (current, false) -> current.id = id | Ok _ | Error _ -> false);
      s.resource_content <- None;
      check bool "known shared report can be revoked without retained body" true
        (match Doc.external_share_change s with Ok (current, false) -> current.id = id | Ok _ | Error _ -> false);
      let no_body_request = match Updates.begin_share_change s ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      check bool "a report with no body can be selected for a fresh read after settlement" true
        (match Updates.share_changed s no_body_request ~result:(Ok false) with
         | Some key -> Catalog.equal_key key report_key | None -> false);
      check bool "unknown share state cannot be toggled" true
        (Result.is_error (Doc.external_share_change s));
      s.resource_content <- Some (report_key, [text "test"]);
      s.resource_content_error <- None; s.resource_shared <- Some true;
      let old_workspace_request = match Updates.begin_share_change s ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      s.workspace_authority <- Types.Workspace_authority 1;
      Types.retain_resource_read s ~key:report_key;
      let successor_owner = ref () in
      s.resource_read_owner <- Some successor_owner;
      Updates.read_done s ~request:{Catalog.key=report_key;owner=successor_owner}
        (Ok {Catalog.parts=[text "successor"];revisions=[report];shared=Some true;share_version=Some 1});
      check (option bool) "same-id reads remain unknown across authority changes" None s.resource_shared;
      Types.retain_resource_read s ~key:report_key;
      let successor_late_owner = ref () in
      s.resource_read_owner <- Some successor_late_owner;
      check bool "old workspace settlement cannot request a new workspace reread" true
        (Option.is_none (Updates.share_changed s old_workspace_request ~result:(Ok false)));
      Updates.read_done s ~request:{Catalog.key=report_key;owner=successor_late_owner}
        (Ok {Catalog.parts=[text "stale successor"];revisions=[report];shared=Some true;share_version=Some 1});
      check (option bool) "old workspace settlement retires a same-id in-flight read" None s.resource_shared;
      s.resource_shared <- Some true;
      let successor_request = match Updates.begin_share_change s ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      check bool "an old owner cannot consume its successor" true
        (Option.is_none (Updates.share_changed s old_workspace_request ~result:(Error "late"))
         && match s.resource_share_pending with
         | Some pending -> pending.share_owner == successor_request.share_owner | None -> false);
      check bool "an old owner cannot taint a successor" false
        (Types.resource_share_uncertain s report);
      ignore (Updates.share_changed s successor_request ~result:(Ok false));
      s.resources_list <- Some [Catalog.Report report; Catalog.Report other];
      s.resource_shared <- Some true;
      let unrelated_request = match Updates.begin_share_change s ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      Types.retain_resource_read s ~key:other_key;
      let other_owner = ref () in
      s.resource_read_owner <- Some other_owner;
      Updates.read_done s ~request:{Catalog.key=other_key;owner=other_owner}
        (Ok {Catalog.parts=[text "other"];revisions=[other];shared=Some true;share_version=Some 1});
      check (option bool) "a different artifact can admit sharing during the write" (Some true) s.resource_shared;
      Types.retain_resource_read s ~key:other_key;
      let other_late_owner = ref () in
      s.resource_read_owner <- Some other_late_owner;
      check bool "settling the first artifact does not refresh a different one" true
        (Option.is_none (Updates.share_changed s unrelated_request ~result:(Ok false)));
      check bool "settling the first artifact preserves the other read owner" true
        (match s.resource_read_owner with
         | Some owner -> owner == other_late_owner | None -> false);
      Updates.read_done s ~request:{Catalog.key=other_key;owner=other_late_owner}
        (Ok {Catalog.parts=[text "other after"];revisions=[other];shared=Some false;share_version=Some 1});
      check (option bool) "the other artifact can finish its read" (Some false) s.resource_shared;
      s.resources_list <- Some [Catalog.Report report];
      s.resource_content <- Some (report_key, [text "test"]);
      s.resource_shared <- Some true;
      s.workspace_identity <- Types.Workspace_identity_match_unconfirmed "identity withdrawn"; refused ();
      s.workspace_identity <- Types.Workspace_identity_match;
      s.resources_list <- Some []; refused ();
      let historical = state () in
      historical.resources_list <- Some [Catalog.Report report; Catalog.Report other];
      historical.resource_content <- None;
      historical.resource_content_error <- None;
      historical.resource_pending_key <- Some older_key;
      historical.resource_read_owner <- Some (ref ());
      historical.resource_shared <- Some true;
      let historical_request = match Updates.begin_share_change historical ~report:older ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      check bool "the pending operation keeps the unread historical revision visible" true
        (match Doc.current historical with
         | Some {entry=Catalog.Report shown;_} -> Catalog.equal_key (Catalog.Report_revision shown) older_key
         | Some _ | None -> false);
      check bool "settlement preserves the unread historical revision" true
        (match Updates.share_changed historical historical_request ~result:(Ok false) with
         | Some key -> Catalog.equal_key key older_key | None -> false);
      check bool "the historical revision remains visible after settlement" true
        (match Doc.current historical with
         | Some {entry=Catalog.Report shown;_} -> Catalog.equal_key (Catalog.Report_revision shown) older_key
         | Some _ | None -> false);
      let interrupted = state () in
      interrupted.resources_list <- Some [Catalog.Report report];
      interrupted.resource_content <- Some (report_key, [text "test"]);
      interrupted.resource_shared <- Some true;
      let interrupted_request = match Updates.begin_share_change interrupted ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      Types.retain_resource_read interrupted ~key:older_key;
      interrupted.resource_read_owner <- Some (ref ());
      check bool "a pending historical read is returned on settlement" true
        (match Updates.share_changed interrupted interrupted_request ~result:(Error "timeout") with
         | Some key -> Catalog.equal_key key older_key | None -> false);
      check bool "a retired historical read keeps its key after uncertain settlement" true
        (match Doc.current interrupted with
         | Some {entry=Catalog.Report shown;_} -> Catalog.equal_key (Catalog.Report_revision shown) older_key
         | Some _ | None -> false);
      check bool "an uncertain result marks the artifact" true
        (Types.resource_share_uncertain interrupted report);
      Types.retain_resource_read interrupted ~key:older_key;
      let uncertain_read = ref () in
      interrupted.resource_read_owner <- Some uncertain_read;
      Updates.read_done interrupted ~request:{Catalog.key=older_key;owner=uncertain_read}
        (Ok {Catalog.parts=[text "later GET"];revisions=[report;older];shared=Some true;share_version=Some 1});
      check (option bool) "a later GET cannot settle the uncertain write" None interrupted.resource_shared;
      check bool "an uncertain artifact cannot be toggled" true
        (Result.is_error (Updates.begin_share_change interrupted ~report ~shared:false));
      check bool "an uncertain artifact cannot copy a public link" true
        (Result.is_error (Doc.copy_public_url interrupted));
      interrupted.workspace_authority <- Types.Workspace_authority 1;
      Types.retain_resource_read interrupted ~key:older_key;
      let uncertain_successor_read = ref () in
      interrupted.resource_read_owner <- Some uncertain_successor_read;
      Updates.read_done interrupted ~request:{Catalog.key=older_key;owner=uncertain_successor_read}
        (Ok {Catalog.parts=[text "successor GET"];revisions=[report;older];shared=Some true;share_version=Some 1});
      check (option bool) "uncertainty survives a workspace authority change" None interrupted.resource_shared;
      interrupted.resources_list <- Some [Catalog.Report report; Catalog.Report other];
      Types.retain_resource_read interrupted ~key:other_key;
      let untainted_read = ref () in
      interrupted.resource_read_owner <- Some untainted_read;
      Updates.read_done interrupted ~request:{Catalog.key=other_key;owner=untainted_read}
        (Ok {Catalog.parts=[text "other"];revisions=[other];shared=Some true;share_version=Some 1});
      check (option bool) "a different artifact remains usable" (Some true) interrupted.resource_shared;
      let other_request = match Updates.begin_share_change interrupted ~report:other ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      ignore (Updates.share_changed interrupted other_request ~result:(Ok false));
      let withdrawn = state () in
      withdrawn.resources_list <- Some [Catalog.Report report];
      withdrawn.resource_content <- Some (report_key, [text "test"]);
      withdrawn.resource_shared <- Some true;
      let withdrawn_request = match Updates.begin_share_change withdrawn ~report ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      withdrawn.workspace_authority <- Types.Workspace_authority 1;
      check bool "an old workspace error cannot request a successor reread" true
        (Option.is_none (Updates.share_changed withdrawn withdrawn_request ~result:(Error "interrupted")));
      check bool "an old workspace error still marks its artifact uncertain" true
        (Types.resource_share_uncertain withdrawn report);
      historical.resource_pending_key <- Some older_key;
      historical.resource_shared <- Some true;
      let away_request = match Updates.begin_share_change historical ~report:older ~shared:false with
        | Ok request -> request | Error detail -> fail detail in
      historical.resources_cursor <- 1;
      Types.retain_resource_read historical ~key:other_key;
      let away_owner = ref () in
      historical.resource_read_owner <- Some away_owner;
      check bool "opening another report is not replaced by the pending report" true
        (match Doc.current historical with
         | Some {entry=Catalog.Report shown;_} -> Catalog.equal_key (Catalog.Report_revision shown) other_key
         | Some _ | None -> false);
      check bool "settlement does not reread a different selected report" true
        (Option.is_none (Updates.share_changed historical away_request ~result:(Ok false)));
      check bool "settlement preserves the other report's read owner" true
        (match historical.resource_read_owner with
         | Some owner -> owner == away_owner | None -> false))

let invalid_selection () =
  List.iter (fun cursor ->
    let s=state () in s.resource_text_cursor<-cursor;refused s) [-1;10]
let new_observation () =
  let s=state () in s.resource_text_cursor<-2;
  Types.retain_resource_read s ~key:(Catalog.Mcp_uri "masc://other");
  check int "new resource retires selection" 0 s.resource_text_cursor;
  s.resource_pending_key<-Some key;let owner=ref () in s.resource_read_owner<-Some owner;
  s.resource_text_cursor<-2;
  Updates.read_done s ~request:{Catalog.key;owner} (Ok (Catalog.mcp_reading parts));
  check int "new admitted observation starts at first text" 0 s.resource_text_cursor;
  s.resource_text_cursor<-2;
  let owner = Updates.begin_listing s in
  Updates.listed s ~owner (Ok {Catalog.entries=[];notes=[];reports_complete=true});
  check int "withdrawal retires text selection" 0 s.resource_text_cursor;
  refused s

let () = run "resource original text copy" ["source and selection",[
  test_case "exact source and reading preservation" `Quick exact_source;
  test_case "multipart selection and empty source" `Quick selection;
  test_case "same-key pending" `Quick pending_same;
  test_case "other-key pending" `Quick pending_other;
  test_case "refused reading" `Quick failure;
  test_case "withdrawn inventory" `Quick withdrawal;
  test_case "unread" `Quick unread;
  test_case "focus and view" `Quick focus;
  test_case "missing authority" `Quick authority;
  test_case "exact OSC52 request bytes" `Quick clipboard_request;
  test_case "binary only" `Quick binary_only;
  test_case "public link requires an admitted shared report" `Quick public_link;
  test_case "invalid selection" `Quick invalid_selection;
  test_case "new observation and withdrawal" `Quick new_observation]]
