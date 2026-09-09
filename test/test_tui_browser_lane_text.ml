module Lane = Masc_tui_types.Browser_lane_view

let () =
  let page : Lane.page = {
    tab_id = 1; title = "Discussion"; url = "https://example.org/discussion";
    text = "Alice\nFirst message\n\nBob\n두 번째 메시지\n"; chars = 44; truncated = false;
  } in
  let reading : Lane.reading = {
    tabs = [{ id = 1; title = "Discussion"; url = page.url; active = true }];
    page = Some page; source = Live; client_id = Some "11111111-1111-4111-8111-111111111111"; elapsed_ms = 1.;
  } in
  let view = { (Lane.create ()) with reading = Some reading } in
  let lines = Masc_tui_types.browser_lane_page_lines ~cols:100 view in
  if lines <> ["Alice"; "First message"; ""; "Bob"; "두 번째 메시지"; ""] then
    failwith "Page paragraph boundaries, blank lines and trailing newline must survive projection";
  print_endline "PASS page multiline and blank-line projection"

let () =
  let draft = "https://example.org/discussion/" ^ String.make 100 'q' ^ "/한글" in
  let row = Masc_tui_types.browser_lane_url_line ~cols:80 draft in
  if not (String.ends_with ~suffix:"/한글▏" row) then
    failwith "long Unicode URL must keep the edited tail and caret visible";
  if Masc_tui_message_layout.display_width row > 76 then
    failwith "URL editor must fit the terminal content cells";
  print_endline "PASS long Unicode URL viewport"

let () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.view <- Keepers Keeper_message;
  state.search <- Some "retained search";
  state.composer_focused <- true;
  Buffer.add_string state.msg_input "unsent draft";
  show_browser_lane state;
  release_composer_for_browser_reader state;
  let view = Option.get state.browser_lane in
  state.browser_lane <- Some { view with scroll = 7; selected_tab = Some 42;
    load = Lane.Loading (9, Lane.Read) };
  hide_browser_lane state;
  assert (state.view = Keepers Keeper_message);
  assert (state.search = Some "retained search" && state.composer_focused);
  assert (Buffer.contents state.msg_input = "unsent draft");
  assert (browser_lane_on_screen state = None);
  (* A reply can settle while hidden without showing the reader or losing
     its scroll. It is the retained model's request, not the visible surface's. *)
  state.browser_lane <- Option.map (Lane.accept ~generation:9 (Error "offline"))
    state.browser_lane;
  show_browser_lane state;
  let restored = Option.get (browser_lane_on_screen state) in
  assert (restored.scroll = 7 && restored.selected_tab = Some 42);
  assert (restored.load = Lane.Failed "offline");
  (* Reopening while shown must keep the original return destination. *)
  show_browser_lane state;
  hide_browser_lane state;
  assert (state.view = Keepers Keeper_message);
  state.view <- Connectors;
  assert (browser_lane_on_screen state = None);
  show_browser_lane state;
  hide_browser_lane state;
  assert (state.view = Connectors && browser_lane_on_screen state = None);
  show_browser_lane state;
  leave_browser_lane_for_surface state Overview;
  state.view <- Overview;
  state.composer_focused <- true;
  leave_browser_lane_for_surface state Connectors;
  state.view <- Connectors;
  assert (browser_lane_on_screen state = None);
  assert state.composer_focused;
  print_endline "PASS reader hide/reopen, hidden reply, navigation, repeated open and draft ownership"

let () =
  let node : Masc.Browser_scene.node = {
    node_id="n1";kind=Text;tag="p";text=String.make 152 'x' ^ "한글🙂";
    rects=[{x=0.;y=0.;width=800.;height=20.}];color="rgb(0,0,0)";
    font_size=16.;font_weight="400";white_space="normal";source_context=Masc.Browser_source_context.Unmapped } in
  let content : Masc.Browser_scene.t = {
    document_id="document";url="https://example.org";title="Scene";
    width=800.;height=600.;scroll_x=0.;scroll_y=0.;nodes=[node];truncated=false;view=Content;scope=None } in
  let scene : Lane.scene = {source=Automation;client_id=None;tab_id=1;content;elapsed_ms=1.} in
  let view = {(Lane.create ()) with source=Automation;selected_tab=Some 1;scene=Some scene} in
  let lines = Masc_tui_types.browser_lane_page_lines ~cols:80 view in
  List.iter (fun line ->
    if Masc_tui_message_layout.display_width ("  " ^ line) > 76 then
      failwith "scene line plus indentation exceeds the framed content width") lines;
  (match lines with
   | "[>1 p]" :: content_lines when String.concat "" content_lines = node.text -> ()
   | _ -> failwith "scene wrapping lost Unicode/ASCII text or the selected target prefix");
  let pending = {view with load=Loading (42,Scene_read 1)} in
  assert ((Lane.accept_scene ~generation:41 (Ok scene) pending).load = pending.load);
  assert ((Lane.accept_scene ~generation:42 (Ok {scene with tab_id=2}) pending).scene = None);
  assert ((Lane.accept_scene ~generation:42 (Ok scene) pending).scene = Some scene);
  let target = {Browser_lane.document_id="document";node_id="region"} in
  let focused = {pending with load=Loading (42,Scene_focus {tab_id=1;target})} in
  assert ((Lane.accept_scene ~generation:42 (Ok scene) focused).scene=None);
  let scoped_scene = {scene with content={content with scope=Some target}} in
  assert ((Lane.accept_scene ~generation:42 (Ok scoped_scene) focused).scene=Some scoped_scene);
  assert (List.length (Lane.scene_targets {view with scene=Some {scene with content={content with nodes=[node;node]}}})=1);
  let located : Masc.Browser_source_context.location = {file="dashboard/src/a.ts";line=2;column=3;
    kind=Template;digest=String.make 64 'a'} in
  let mapped = {node with source_context=Masc.Browser_source_context.Located located} in
  let view = {view with scene=Some {scene with content={content with nodes=[mapped]}}} in
  (match Lane.scene_context view with
   | None -> failwith "selected element context missing"
   | Some text ->
       let open Yojson.Safe.Util in
       let json=Yojson.Safe.from_string text in
       assert (json |> member "nodeId" |> to_string = mapped.node_id);
       assert (json |> member "source" |> member "sha256" |> to_string = located.digest));
  print_endline "PASS scene wrapping, source handoff, node deduplication and asynchronous ownership"
