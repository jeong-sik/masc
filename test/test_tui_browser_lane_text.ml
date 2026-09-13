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
  let lines = (fst (Masc_tui_types.browser_lane_page_layout ~cols:100 view)) in
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
  let copied_target source client_id selected =
    let scene = {scene with source;client_id;content={content with nodes=[selected]}} in
    match Lane.scene_context {view with scene=Some scene} with
    | None -> failwith "selected target context missing"
    | Some text -> Yojson.Safe.from_string text in
  let client = "10000000-0000-4000-8000-000000000001" in
  let region = {node with node_id="channels";kind=Region "navigation";tag="nav";text="Channels"} in
  let open Yojson.Safe.Util in
  let region_context = copied_target Live (Some client) region in
  let region_action = region_context |> member "defaultAction" in
  let region_input = region_action |> member "input" in
  assert (region_context |> member "targetKind" = `String "region");
  assert (Lane.scene_target_action region = Some Read_region);
  assert (region_action |> member "kind" = `String "read_region");
  assert (region_action |> member "tool" = `String "BrowserRead");
  assert (region_input |> member "mode" = `String "scene");
  assert (region_input |> member "clientId" = `String client);
  assert (region_input |> member "expectedUrl" = `String content.url);
  assert (Masc.Browser_scene.scope_of_json (region_input |> member "scope") =
    Ok {Browser_lane.document_id=content.document_id;node_id=region.node_id});
  let control = {node with kind=Control {clickable=true;editable=false;disabled=false};tag="button"} in
  let control_context = copied_target Automation None control in
  let control_action = control_context |> member "defaultAction" in
  assert (Lane.scene_target_action control = Some Click_control);
  assert (control_action |> member "tool" = `String "BrowserInteract");
  (match Masc.Browser_interaction.parse (control_action |> member "input") with
   | Ok {action=Browser_lane.Click_node target;expected_url=Some url;client_id=None;_} ->
       assert (target.document_id=content.document_id && target.node_id=control.node_id && url=content.url)
   | _ -> failwith "copied control action does not satisfy the actual interaction contract");
  List.iter (fun kind ->
    let selected={node with kind} in
    assert (Lane.scene_target_action selected=None);
    assert (copied_target Automation None selected |> member "defaultAction" = `Null))
    [Text;Raster;Control {clickable=true;editable=false;disabled=true};
     Control {clickable=false;editable=true;disabled=false}];
  let lines = (fst (Masc_tui_types.browser_lane_page_layout ~cols:80 view)) in
  List.iter (fun line ->
    if Masc_tui_message_layout.display_width ("  " ^ line) > 76 then
      failwith "scene line plus indentation exceeds the framed content width") lines;
  (match lines with
   | "[>1]" :: content_lines when String.concat "" content_lines = node.text -> ()
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
  let clicked = {focused with load=Loading (42,Scene_click {tab_id=1;
    document_id=content.document_id;node_id=node.node_id;expected_url=content.url;scope=Some target})} in
  assert ((Lane.accept_scene ~generation:42 (Ok scoped_scene) clicked).scene=Some scoped_scene);
  assert ((Lane.accept_scene ~generation:42 (Ok scene) clicked).scene=None);
  let invalidated = Lane.accept_scene ~generation:42 (Error "scene_document_changed") clicked in
  assert (invalidated.scene=None && invalidated.load=Failed "scene_document_changed");
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
       assert (json |> member "source" |> member "sha256" |> to_string = located.digest);
       assert (json |> member "scope" = `Null);
       assert (json |> member "truncated" = `Bool false));
  let focused_view = {view with scene=Some {scene with content={content with
    nodes=[mapped];scope=Some target;scroll_y=240.;truncated=true}}} in
  (match Lane.scene_context focused_view with
   | None -> failwith "scoped element context missing"
   | Some text ->
       let open Yojson.Safe.Util in
       let json=Yojson.Safe.from_string text in
       assert (json |> member "view" = `String "content");
       (* The copied scope is accepted by the browser read boundary, keeping
          the region distinct from the selected element within it. *)
       assert (Masc.Browser_scene.scope_of_json (json |> member "scope") = Ok target);
       assert (json |> member "nodeId" = `String mapped.node_id);
       assert (json |> member "viewport" |> member "scrollY" = `Float 240.);
       assert (json |> member "truncated" = `Bool true));
  print_endline "PASS scene wrapping, source handoff, node deduplication and asynchronous ownership"

(* Repeated ids are what the target index is for: a scene can hold the same
   node twice, and both copies must carry the number of its first appearance.
   The projection used to answer this by rescanning the deduplicated list for
   every node, which rebuilt that list each time. *)
let () =
  let node node_id text : Masc.Browser_scene.node =
    { node_id; kind = Text; tag = "p"; text;
      rects = [{ x = 0.; y = 0.; width = 10.; height = 10. }];
      color = "rgb(0, 0, 0)"; font_size = 14.; font_weight = "400";
      white_space = "normal"; source_context = Masc.Browser_source_context.Unmapped } in
  let content : Masc.Browser_scene.t = {
    document_id = "doc"; url = "https://example.org/doc"; title = "Doc";
    width = 800.; height = 600.; scroll_x = 0.; scroll_y = 0.; truncated = false;
    view = Content; scope = None;
    nodes = [node "a" "first"; node "b" "second"; node "a" "first again"; node "c" "third"] } in
  let view = { (Lane.create ()) with
    scene = Some { source = Live; client_id = None; tab_id = 1; content; elapsed_ms = 1. };
    scene_cursor = 2 } in
  if List.length (Lane.scene_targets view) <> 3 then
    failwith "repeated node ids must collapse to one target each";
  let lines = (fst (Masc_tui_types.browser_lane_page_layout ~cols:100 view)) in
  if lines <> ["first"; "second"; "first again"; "[>3] third"] then
    failwith "text stays readable and the selected node retains its deduplicated number";
  let repeated, selected = Masc_tui_types.browser_lane_page_layout ~cols:100 {view with scene_cursor=0} in
  if repeated <> ["[>1] first"; "second"; "[>1] first again"; "third"] || selected <> Some 0 then
    failwith "repeated selected text must retain its identity and first row";
  print_endline "PASS repeated scene node ids keep one number each"
