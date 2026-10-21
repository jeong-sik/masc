open Alcotest
module Types = Masc_tui_types
module Catalog = Masc_tui_resource_catalog
module Doc = Masc_tui_resource_document
module Updates = Masc_tui_resources_updates
module Position = Masc_tui_scroll.Position
module Reading = Masc_tui_resource_reading
let key = Catalog.Mcp_uri "masc://report"
let parts = [{Masc_tui_mcp.rc_uri=Some "masc://report";
  rc_mime_type=Some "text/markdown";
  rc_kind=Masc_tui_mcp.Resource_text "# Original\r\n한글\tneedle **text**\n"}]
let state () =
  let s=Types.create_state ~workspace:"test" ~port:0 ~refresh_interval:0. () in
  s.resource_focus <- Types.Right_pane;
  s.resources_list <- Some [Catalog.Mcp {Masc_tui_mcp.uri="masc://report";
    name="report";title=None;description=None;mime_type=Some "text/markdown";size=None}]; s
let loaded () = let s=state () in s.resource_content<-Some(key,parts);s
let available s = Option.is_some (Doc.search_rows ~cols:120 s)
let test_admitted () =
  let s=loaded () in
  check bool "admitted original can be searched" true (available s);
  check bool "projection preserves original observation" true
    (match s.resource_content with Some(_,saved)-> saved==parts | None->false)
let test_unread () =
  check bool "metadata is not body search" false (available (state ()))
let test_pending_other () =
  let s=loaded () in s.resource_pending_key<-Some(Catalog.Mcp_uri "masc://other");
  check bool "hidden previous body is not searchable" false (available s)
let test_refused () =
  let s=loaded () in s.resource_content_error<-Some(key,"refused");
  check bool "retained body behind error is not searchable" false (available s)
let test_removed () =
  let s=loaded () in s.resources_list<-Some [];
  check bool "withdrawn inventory cannot authorize body search" false (available s)
let test_last_page () =
  let s=loaded () in Updates.place_search_match s ~cols:120 ~query:"needle" ~count:30 ~index:28;
  s.resource_scroll<-Masc_tui_scroll.Position.at 20; (* Renderer reports its clamped last page. *)
  check int "logical match survives page clamp" 28 (Reading.cursor s.resource_search_position);
  check int "catalog cursor is untouched" 0 s.resources_cursor;
  Updates.place_search_match s ~cols:120 ~query:"needle" ~count:30 ~index:29;
  check int "next match can advance past clamped scroll" 29 (Reading.cursor s.resource_search_position);
  check int "next landing asks for original match row" 29 (Masc_tui_scroll.Position.offset ~count:40 ~height:1 s.resource_scroll);
  Updates.place_search_match s ~cols:120 ~query:"needle" ~count:30 ~index:30;
  check int "invalid landing does not alter match" 29 (Reading.cursor s.resource_search_position)
let test_list_focus () =
  let s=loaded () in s.resource_focus<-Types.Left_pane;
  Updates.place_search_match s ~cols:120 ~query:"needle" ~count:30 ~index:20;
  check int "list focus cannot scroll hidden body" 0 (Masc_tui_scroll.Position.offset ~count:40 ~height:1 s.resource_scroll)
let test_new_read () =
  let s=loaded () in Updates.place_search_match s ~cols:120 ~query:"needle" ~count:30 ~index:28;
  s.resource_scroll <- Position.move ~count:100 ~height:20 Position.Last s.resource_scroll;
  Types.retain_resource_read s ~key:(Catalog.Mcp_uri "masc://other");
  check int "new resource retires previous match" 0 (Reading.cursor s.resource_search_position);
  check int "new resource releases the end selection" 0
    (Position.offset ~count:200 ~height:20 s.resource_scroll)
let test_end_after_reflow () =
  let s=loaded () in
  s.resource_scroll <- Position.move ~count:100 ~height:20 Position.Last s.resource_scroll;
  Types.apply_clamped_scroll s (Types.Resource_scroll
    (Position.clamp ~count:100 ~height:20 s.resource_scroll));
  check int "frame normalization retains end through a larger extent" 180
    (Position.offset ~count:200 ~height:20 s.resource_scroll);
  Types.apply_clamped_scroll s (Types.Resource_scroll
    (Position.clamp ~count:1 ~height:20 s.resource_scroll));
  check int "temporary short projection cannot retire end" 180
    (Position.offset ~count:200 ~height:20 s.resource_scroll);
  s.resource_scroll <- Position.move ~count:200 ~height:20 (Position.By (-1)) s.resource_scroll;
  check int "relative move uses current extent and releases end" 179
    (Position.offset ~count:300 ~height:20 s.resource_scroll);
  check bool "navigation retains original parts" true
    (match s.resource_content with Some (_, saved) -> saved == parts | None -> false)
let test_explicit_landings_release_end () =
  let s=loaded () in
  s.resource_scroll <- Position.move ~count:100 ~height:20 Position.Last s.resource_scroll;
  Updates.place_search_match s ~cols:120 ~query:"needle" ~count:100 ~index:29;
  check int "search owns its absolute landing after extent changes" 29
    (Position.offset ~count:200 ~height:20 s.resource_scroll);
  s.resource_scroll <- Position.move ~count:200 ~height:20 Position.Last s.resource_scroll;
  s.resource_scroll <- Position.move ~count:200 ~height:20 Position.First s.resource_scroll;
  check int "Home releases end after extent changes" 0
    (Position.offset ~count:300 ~height:20 s.resource_scroll)
let () = run "resource document search decisions" ["admission",[
  test_case "admitted original" `Quick test_admitted;
  test_case "unread" `Quick test_unread;
  test_case "pending other key" `Quick test_pending_other;
  test_case "refusal" `Quick test_refused;
  test_case "withdrawal" `Quick test_removed];"navigation",[
  test_case "logical last-page match" `Quick test_last_page;
  test_case "list focus" `Quick test_list_focus;
  test_case "new source retires match" `Quick test_new_read;
  test_case "end follows reflow and relative navigation" `Quick test_end_after_reflow;
  test_case "search and Home release end" `Quick test_explicit_landings_release_end]]
