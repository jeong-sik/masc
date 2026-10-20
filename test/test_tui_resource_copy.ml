open Alcotest
module Types = Masc_tui_types
module Mcp = Masc_tui_mcp
module Catalog = Masc_tui_resource_catalog
module Doc = Masc_tui_resource_document
module Updates = Masc_tui_resources_updates

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
    sid_binary_commit_age_s=None;sid_base_path="/workspace";sid_masc_root="/workspace/.masc";
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
  s.resource_scroll <- 17;s.resource_search_cursor <- 23;
  check string "original source bytes, not a display projection" raw (source s);
  check int "copy leaves scroll" 17 s.resource_scroll;
  check int "copy leaves logical match" 23 s.resource_search_cursor;
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
  Updates.listed s (Ok {Catalog.entries=[];notes=[]});
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
  test_case "invalid selection" `Quick invalid_selection;
  test_case "new observation and withdrawal" `Quick new_observation]]
