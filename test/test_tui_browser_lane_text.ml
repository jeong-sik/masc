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
  let node role = `Assoc [
    "kind", `String "region"; "nodeId", `String "n1"; "role", `String role;
    "tag", `String "main"; "text", `String "Reading surface";
    "rects", `List [`Assoc ["x", `Int 0; "y", `Int 0; "width", `Int 100; "height", `Int 40]];
    "color", `String "rgb(0,0,0)"; "fontSize", `Int 14;
    "fontWeight", `String "400"; "whiteSpace", `String "normal" ] in
  let json = `Assoc [
    "schema", `String "masc.browser.scene.v1"; "documentId", `String "doc";
    "url", `String "https://example.org"; "title", `String "Example";
    "viewport", `Assoc ["width", `Int 100; "height", `Int 40;
      "scrollX", `Int 0; "scrollY", `Int 0];
    "nodes", `List [node "MAIN"]; "truncated", `Bool false;
    "view", `String "regions"; "scope", `Null ] in
  (match Masc.Browser_scene.of_json json with
   | Ok {nodes=[{kind=Region Masc.Browser_scene.Main;_}];_} -> ()
   | Ok _ | Error _ -> failwith "scene parser did not classify the observed role");
  let heading_json = `Assoc [
    "kind", `String "text"; "nodeId", `String "heading";
    "tag", `String "span"; "text", `String "Nested title";
    "headingLevel", `Int 3;
    "ancestorRegion", `Assoc ["nodeId", `String "article";
      "role", `String "article"; "label", `String "Post A"];
    "rects", `List [`Assoc ["x", `Int 0; "y", `Int 0; "width", `Int 100; "height", `Int 20]];
    "color", `String "rgb(0,0,0)"; "fontSize", `Int 14;
    "fontWeight", `String "400"; "whiteSpace", `String "normal" ] in
  let heading_scene_json = `Assoc [
    "schema", `String "masc.browser.scene.v1"; "documentId", `String "doc";
    "url", `String "https://example.org"; "title", `String "Example";
    "viewport", `Assoc ["width", `Int 100; "height", `Int 40;
      "scrollX", `Int 0; "scrollY", `Int 0];
    "nodes", `List [heading_json]; "truncated", `Bool false;
    "view", `String "content"; "scope", `Null ] in
  (match Masc.Browser_scene.of_json heading_scene_json with
   | Ok {nodes=[{heading_level=Some 3;
                ancestor_region=Some {node_id="article"; role=Masc.Browser_scene.Article;
                                      label="Post A"}}];_} -> ()
   | Ok _ | Error _ -> failwith "scene parser dropped the observed heading level");
  print_endline "PASS semantic region roles are typed at the scene boundary"

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
    heading_level=None;
    ancestor_region=None;
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
  let region = {node with node_id="channels";kind=Region Masc.Browser_scene.Navigation;tag="nav";text="Channels"} in
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
  let article = {node with node_id="article-body";
    ancestor_region=Some {Masc.Browser_scene.node_id="article";
      role=Masc.Browser_scene.Article; label="Post A"}} in
  let article_context = copied_target Automation None article in
  assert (article_context |> member "ancestorRegion" =
    `Assoc ["documentId", `String content.document_id;
      "nodeId", `String "article"; "role", `String "article";
      "label", `String "Post A"]);
  let control = {node with kind=Control {clickable=true;editable=false;disabled=false;href=None};tag="button"} in
  let control_context = copied_target Automation None control in
  let control_action = control_context |> member "defaultAction" in
  assert (Lane.scene_target_action control = Some Click_control);
  assert (control_action |> member "tool" = `String "BrowserInteract");
  (match Masc.Browser_interaction.parse (control_action |> member "input") with
   | Ok {action=Browser_lane.Click_node target;expected_url=Some url;client_id=None;_} ->
       assert (target.document_id=content.document_id && target.node_id=control.node_id && url=content.url)
   | _ -> failwith "copied control action does not satisfy the actual interaction contract");
  let link = {node with node_id="link"; kind=Control {
      clickable=true;editable=false;disabled=false;
      href=Some "https://example.org/observed"}; tag="a"; text="Observed thread"} in
  let link_context = copied_target Automation None link in
  let link_action = link_context |> member "defaultAction" in
  assert (Lane.scene_target_action link = Some Follow_link);
  assert (link_context |> member "targetKind" = `String "link");
  assert (link_context |> member "href" = `String "https://example.org/observed");
  assert (link_action |> member "kind" = `String "follow_link");
  (match Masc.Browser_interaction.parse (link_action |> member "input") with
   | Ok {action=Browser_lane.Follow_link target;expected_url=Some url;client_id=None;_} ->
       assert (target.document_id=content.document_id && target.node_id=link.node_id && url=content.url)
   | _ -> failwith "copied link action does not satisfy the actual follow contract");
  let raster = {node with node_id="image";kind=Raster;tag="img";text="Preview"} in
  let typed_scene = {scene with content={content with nodes=[region;control;link;raster]}} in
  assert (Lane.scene_summary typed_scene = Some "1 region · 1 link · 1 control · 1 image");
  assert (Lane.scene_summary scene = None);
  List.iter (fun kind ->
    let selected={node with kind} in
    assert (Lane.scene_target_action selected=None);
    assert (copied_target Automation None selected |> member "defaultAction" = `Null))
    [Text;Raster;Control {clickable=true;editable=false;disabled=true;href=None};
     Control {clickable=false;editable=true;disabled=false;href=None}];
  let lines = (fst (Masc_tui_types.browser_lane_page_layout ~cols:80 view)) in
  List.iter (fun line ->
    if Masc_tui_message_layout.display_width ("  " ^ line) > 76 then
      failwith "scene line plus indentation exceeds the framed content width") lines;
  (match lines with
   | "[>1]" :: content_lines when String.concat "" content_lines = node.text -> ()
   | _ -> failwith "scene wrapping lost Unicode/ASCII text or the selected target prefix");
  assert (Masc.Browser_scene.text_role_of_tag "H6" = Masc.Browser_scene.Heading 6);
  assert (Masc.Browser_scene.text_role_of_tag "p" = Masc.Browser_scene.Plain_text);
  let heading = {node with node_id="heading"; tag="h2"; text="Post title"} in
  let body = {node with node_id="body"; tag="p"; text="Post body"} in
  let nested_heading = {heading with node_id="nested-heading"; tag="span"; heading_level=Some 2} in
  let aria_heading = {heading with node_id="aria-heading"; tag="span"; heading_level=Some 3} in
  let heading_link = {heading with node_id="heading-link"; kind=Control {
      clickable=true; editable=false; disabled=false; href=Some "https://example.org/post"};
      tag="a"; heading_level=Some 2} in
  assert (Masc.Browser_scene.text_role nested_heading = Masc.Browser_scene.Heading 2);
  assert (Masc.Browser_scene.text_role aria_heading = Masc.Browser_scene.Heading 3);
  assert (Masc.Browser_scene.text_role heading_link = Masc.Browser_scene.Heading 2);
  assert (Masc.Browser_scene.text_role {heading with kind=Raster} = Masc.Browser_scene.Plain_text);
  let heading_scene = {scene with content={content with nodes=[heading;body]}} in
  let heading_lines = fst (Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some heading_scene; scene_cursor=0}) in
  assert (heading_lines = ["[>1] ## Post title"; "Post body"]);
  let paragraph = {node with node_id="paragraph"; tag="p"; text="Hello "} in
  let emphasis = {node with node_id="emphasis"; tag="span"; text="world"} in
  let paragraph_tail = {node with node_id="paragraph"; tag="p"; text="!"} in
  let inline_scene = {scene with content={content with
    nodes=[paragraph; emphasis; paragraph_tail]}} in
  let inline_lines, inline_selected = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some inline_scene; scene_cursor=0} in
  assert (inline_lines = ["[>1] Hello world!"] && inline_selected = Some 0);
  let inline_selected_lines, inline_selected_row = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some inline_scene; scene_cursor=1} in
  assert (inline_selected_lines = ["[>2] Hello world!"] && inline_selected_row = Some 0);
  let separate_paragraphs = {scene with content={content with nodes=[
    {paragraph with node_id="paragraph-a"; text="A"};
    {emphasis with node_id="paragraph-b-inline"; text="B"}]}} in
  let separate_lines, _ = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some separate_paragraphs; scene_cursor=0} in
  assert (separate_lines = ["[>1] A"; "B"]);
  let trailing_inline = {scene with content={content with nodes=[
    {paragraph with node_id="paragraph-a"; text="A"};
    {emphasis with node_id="paragraph-a-inline"; text="B"};
    {paragraph with node_id="paragraph-a"; text="C"};
    {emphasis with node_id="paragraph-b-inline"; text="D"}]}} in
  let trailing_lines, _ = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some trailing_inline; scene_cursor=0} in
  assert (trailing_lines = ["[>1] ABC"; "D"]);
  (* One paragraph with two inline elements arrives as five fragments, the
     paragraph's own id between them: "a " <b>b</b> " c " <i>d</i> " e". *)
  let two_inlines = {scene with content={content with nodes=[
    {paragraph with node_id="paragraph-a"; text="a "};
    {emphasis with node_id="bold"; text="b"};
    {paragraph with node_id="paragraph-a"; text=" c "};
    {emphasis with node_id="italic"; text="d"};
    {paragraph with node_id="paragraph-a"; text=" e"}]}} in
  let two_inline_lines, two_inline_selected = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some two_inlines; scene_cursor=2} in
  assert (two_inline_lines = ["[>3] a b c d e"] && two_inline_selected = Some 0);
  let two_inlines_then_trailing = {scene with content={content with nodes=[
    {paragraph with node_id="paragraph-a"; text="A"};
    {emphasis with node_id="bold"; text="B"};
    {paragraph with node_id="paragraph-a"; text="C"};
    {emphasis with node_id="italic"; text="D"};
    {paragraph with node_id="paragraph-a"; text="E"};
    {emphasis with node_id="paragraph-b-inline"; text="F"}]}} in
  let two_inline_trailing_lines, _ = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some two_inlines_then_trailing; scene_cursor=0} in
  assert (two_inline_trailing_lines = ["[>1] ABCDE"; "F"]);
  let article : Masc.Browser_scene.region_ref =
    {node_id="article"; role=Masc.Browser_scene.Article; label="Post A"} in
  let article_heading = {heading with ancestor_region=Some article} in
  let article_body = {body with ancestor_region=Some article} in
  let article_scene = {scene with content={content with nodes=[article_heading;article_body]}} in
  let article_lines, article_selected = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some article_scene; scene_cursor=0} in
  assert (article_lines = ["[article] Post A"; "[>1] ## Post title"; "Post body"]
    && article_selected = Some 1);
  let scoped_article = {article_scene with content={article_scene.content with
    scope=Some {Browser_lane.document_id="document"; node_id="article"}}} in
  let scoped_article_lines, scoped_article_selected = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some scoped_article; scene_cursor=0} in
  assert (scoped_article_lines = ["[>1] ## Post title"; "Post body"]
    && scoped_article_selected = Some 0);
  let article_b = {node with node_id="article-b-body"; text="Second post";
    ancestor_region=Some {node_id="article-b"; role=Masc.Browser_scene.Article;
      label="Post B"}} in
  let multiple_article_scene = {scene with content={content with
    nodes=[article_heading; article_body; article_b]}} in
  let multiple_article_lines = fst (Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some multiple_article_scene; scene_cursor=0}) in
  assert (multiple_article_lines = ["[article 1/2] Post A"; "[>1] ## Post title";
    "Post body"; "[article 2/2] Post B"; "Second post"]);
  let spaced_heading = {heading with rects=[{x=0.;y=0.;width=800.;height=20.}]} in
  let spaced_body = {body with rects=[{x=0.;y=40.;width=800.;height=20.}]} in
  let spaced_scene = {scene with content={content with nodes=[spaced_heading;spaced_body]}} in
  let spaced_lines = fst (Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some spaced_scene; scene_cursor=0}) in
  assert (spaced_lines = ["[>1] ## Post title"; ""; "Post body"]);
  let spaced_lines, spaced_selected = Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some spaced_scene; scene_cursor=1} in
  assert (spaced_selected = Some 2 && spaced_lines = ["## Post title"; ""; "[>2] Post body"]);
  let metadata = {body with node_id="metadata"; tag="time"; text="10:30";
    rects=[{x=0.;y=25.;width=800.;height=10.}]} in
  let inline_scene = {scene with content={content with nodes=[spaced_heading;metadata;spaced_body]}} in
  let inline_lines = fst (Masc_tui_types.browser_lane_page_layout ~cols:80
    {view with scene=Some inline_scene; scene_cursor=0}) in
  assert (inline_lines = ["[>1] ## Post title"; "10:30"; "Post body"]);
  let pending = {view with load=Loading (42,Scene_read 1)} in
  assert ((Lane.accept_scene ~generation:41 (Ok scene) pending).load = pending.load);
  assert ((Lane.accept_scene ~generation:42 (Ok {scene with tab_id=2}) pending).scene = None);
  assert ((Lane.accept_scene ~generation:42 (Ok scene) pending).scene = Some scene);
  let target = {Browser_lane.document_id="document";node_id="region"} in
  let focused = {pending with load=Loading (42,Scene_focus {tab_id=1;target})} in
  assert ((Lane.accept_scene ~generation:42 (Ok scene) focused).scene=None);
  let scoped_scene = {scene with content={content with scope=Some target}} in
  assert ((Lane.accept_scene ~generation:42 (Ok scoped_scene) focused).scene=Some scoped_scene);
  let scrolled = {focused with load=Loading (42,Scene_scroll {
      tab_id=1;document_id=content.document_id;expected_url=content.url;scene_view=Browser_lane.Content;
      scope=None;delta_y=600})} in
  let scrolled_scene = {scene with content={content with scroll_y=600.}} in
  assert ((Lane.accept_scene ~generation:42 (Ok scrolled_scene) scrolled).scene=Some scrolled_scene);
  let replaced_scene = {scrolled_scene with content={scrolled_scene.content with document_id="new-document"}} in
  assert ((Lane.accept_scene ~generation:42 (Ok replaced_scene) scrolled).scene=None);
  let clicked = {focused with load=Loading (42,Scene_click {tab_id=1;
    document_id=content.document_id;node_id=node.node_id;expected_url=content.url;scope=Some target})} in
  assert ((Lane.accept_scene ~generation:42 (Ok scoped_scene) clicked).scene=Some scoped_scene);
  assert ((Lane.accept_scene ~generation:42 (Ok scene) clicked).scene=None);
  let followed = {focused with load=Loading (42,Scene_follow {tab_id=1;
    document_id=content.document_id;node_id=link.node_id;expected_url=content.url})} in
  let followed_scene = {scene with content={content with scope=None}} in
  let guard : Lane.navigation_guard = {
    expected_url="https://example.org/observed";
    navigation_source={url=content.url;document_id=content.document_id} } in
  assert ((Lane.accept_follow ~generation:42 ~guard (Ok followed_scene) followed).scene=Some followed_scene);
  let guarded_failure = Lane.accept_follow ~generation:42 ~guard (Error "destination not ready") followed in
  assert (guarded_failure.scene=None && guarded_failure.scene_guard=Some guard);
  let retry = {guarded_failure with load=Loading (43,Scene_follow_refresh {
      tab_id=1;guard;scene_view=Browser_lane.Content})} in
  let retry_failed = Lane.accept_scene ~generation:43 (Error "still loading") retry in
  assert (retry_failed.scene=None && retry_failed.scene_guard=Some guard);
  let regions_retry = {retry_failed with load=Loading (44,Scene_follow_refresh {
      tab_id=1;guard;scene_view=Browser_lane.Regions})} in
  let regions_scene = {followed_scene with content={followed_scene.content with
      view=Browser_lane.Regions}} in
  assert ((Lane.accept_scene ~generation:44 (Ok regions_scene) regions_retry).scene=Some regions_scene);
  let invalidated = Lane.accept_scene ~generation:42 (Error "scene_document_changed") clicked in
  assert (invalidated.scene=None && invalidated.load=Failed "scene_document_changed");
  assert (List.length (Lane.scene_targets {view with scene=Some {scene with content={content with nodes=[node;node]}}})=1);
  let located : Masc.Browser_source_context.location = {file="dashboard/src/a.ts";line=2;column=3;
    kind=Template;digest=String.make 64 'a'} in
  let mapped = {node with heading_level=Some 2; source_context=Masc.Browser_source_context.Located located} in
  let view = {view with scene=Some {scene with content={content with nodes=[mapped]}}} in
  (match Lane.scene_context view with
   | None -> failwith "selected element context missing"
   | Some text ->
       let open Yojson.Safe.Util in
       let json=Yojson.Safe.from_string text in
       assert (json |> member "nodeId" |> to_string = mapped.node_id);
       assert (json |> member "headingLevel" = `Int 2);
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
      heading_level = None;
      ancestor_region = None;
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

let () =
  let node node_id text : Masc.Browser_scene.node =
    { node_id; kind = Text; tag = "p"; text; heading_level = None;
      ancestor_region = None;
      rects = [{ x = 0.; y = 0.; width = 10.; height = 10. }];
      color = "rgb(0, 0, 0)"; font_size = 14.; font_weight = "400";
      white_space = "normal"; source_context = Masc.Browser_source_context.Unmapped }
  in
  let content : Masc.Browser_scene.t = {
    document_id = "doc"; url = "https://example.org/feed"; title = "Feed";
    width = 800.; height = 600.; scroll_x = 0.; scroll_y = 0.; truncated = false;
    view = Content; scope = None;
    nodes = [node "a" "first"; node "a" "inline fragment"; node "b" "second"] }
  in
  let first : Lane.scene = {source = Live; client_id = None; tab_id = 2;
    content; elapsed_ms = 1.} in
  let first_view = {(Lane.create ()) with selected_tab = Some 2; scene = Some first} in
  let second_content = {content with scroll_y = 600.;
    nodes = [node "a" "first"; node "a" "inline changed"; node "c" "new"]} in
  let second = {first with content = second_content} in
  (match Lane.scene_delta first second with
   | {added = 1; removed = 1; unchanged = 0; changed = 1} -> ()
   | _ -> failwith "scene delta must deduplicate IDs and separate changed nodes");
  let published = Lane.publish_scene second first_view in
  (match published.scene_delta with
   | Some {added = 1; removed = 1; unchanged = 0; changed = 1} -> ()
   | _ -> failwith "same observed document must publish its scene delta");
  let scroll_only = Lane.publish_scene {first with content = {content with scroll_y = 600.}}
    first_view in
  (match scroll_only.scene_delta with
   | Some {added = 0; removed = 0; unchanged = 2; changed = 0} -> ()
   | _ -> failwith "scroll-only observation must retain node identities");
  let other_document = Lane.publish_scene {second with content = {second_content with document_id = "other"}}
    first_view in
  assert (other_document.scene_delta = None);
  print_endline "PASS scene delta is identity-guarded and scroll-aware"

let () =
  let region node_id role text : Masc.Browser_scene.node =
    { node_id; kind = Region (Masc.Browser_scene.region_role_of_string role); tag = role; text;
      heading_level = None;
      ancestor_region = None;
      rects = [{ x = 0.; y = 0.; width = 10.; height = 10. }];
      color = "rgb(0, 0, 0)"; font_size = 14.; font_weight = "400";
      white_space = "normal"; source_context = Masc.Browser_source_context.Unmapped }
  in
  let content : Masc.Browser_scene.t = {
    document_id = "doc"; url = "https://example.org/feed"; title = "Feed";
    width = 800.; height = 600.; scroll_x = 0.; scroll_y = 0.; truncated = false;
    view = Regions; scope = None;
    nodes = [region "nav" "navigation" "Navigation";
             region "main" "main" "Timeline";
             region "article" "article" "One post"] }
  in
  let scene : Lane.scene = {source = Live; client_id = None; tab_id = 3;
    content; elapsed_ms = 1.} in
  let view = {(Lane.create ()) with selected_tab = Some 3; scene = Some scene} in
  (match Lane.primary_region_target view with
   | Ok (index, target) ->
       assert (index = 1 && target.Browser_lane.node_id = "main")
   | Error _ -> failwith "unique main landmark was not selected");
  let article_only = {view with scene = Some {scene with content =
    {content with nodes = [region "article" "article" "One post"]}}} in
  (match Lane.primary_region_target article_only with
   | Ok (_, target) -> assert (target.Browser_lane.node_id = "article")
   | Error _ -> failwith "article fallback was not selected");
  let ambiguous = {view with scene = Some {scene with content =
    {content with nodes = [region "main-a" "main" "A"; region "main-b" "main" "B"]}}} in
  assert (Lane.primary_region_target ambiguous = Error Lane.Ambiguous_primary_region);
  assert (Masc.Browser_scene.region_role_of_string "MAIN" = Masc.Browser_scene.Main);
  assert (Masc.Browser_scene.region_role_of_string "section" = Masc.Browser_scene.Section);
  assert (Masc.Browser_scene.region_role_of_string "region" = Masc.Browser_scene.Named_region);
  assert (Masc.Browser_scene.region_role_of_string " CustomRole " = Masc.Browser_scene.Unknown "CustomRole");
  let article_node = List.nth (Lane.scene_targets view) 2 in
  assert (Lane.scene_summary scene = Some "1 article · 2 regions");
  let article_context = Lane.scene_scope_context_for_node view article_node in
  (match article_context with
   | Some context ->
       assert (context.role = Masc.Browser_scene.Article);
       assert (context.label = "One post");
       assert (context.target = {Browser_lane.document_id = content.document_id; node_id = "article"})
   | None -> failwith "article scope context was not retained from the observed region");
  let focused_target = {Browser_lane.document_id = content.document_id; node_id = "article"} in
  let focused_content = {content with view = Content; scope = Some focused_target;
    nodes = [region "title" "article" "One post body"]} in
  let focused_scene = {scene with content = focused_content} in
  let focused_view = Lane.publish_scene focused_scene
    {view with scene_scope = article_context} in
  assert (focused_view.scene_scope = article_context);
  (match Lane.scene_context focused_view with
   | None -> failwith "scoped article context missing"
   | Some text ->
       let open Yojson.Safe.Util in
       let json = Yojson.Safe.from_string text in
       assert (json |> member "scopeContext" |> member "role" = `String "article");
       assert (json |> member "scopeContext" |> member "label" = `String "One post"));
  let scrolling = {focused_view with load = Loading (42, Scene_scroll {
      tab_id = 3; document_id = content.document_id; expected_url = content.url;
      scene_view = Content; scope = Some focused_target; delta_y = 600})} in
  let scrolled_content = {focused_content with scroll_y = 600.} in
  let scrolled = Lane.accept_scene ~generation:42
    (Ok {focused_scene with content = scrolled_content}) scrolling in
  assert (scrolled.scene_scope = article_context);
  let clicking = {focused_view with load = Loading (43, Scene_click {
      tab_id = 3; document_id = content.document_id; node_id = "title";
      expected_url = content.url; scope = Some focused_target})} in
  let clicked = Lane.accept_scene ~generation:43 (Ok focused_scene) clicking in
  assert (clicked.scene_scope = article_context);
  let guard : Lane.navigation_guard = {
    expected_url = "https://example.org/feed#post";
    navigation_source = {url = content.url; document_id = content.document_id} } in
  (match Lane.primary_region_action {view with scene = None; scene_guard = Some guard} with
   | Lane.Primary_guarded_regions {tab_id; guard = actual} ->
       assert (tab_id = 3 && actual = guard)
   | _ -> failwith "primary shortcut dropped the follow navigation guard");
  print_endline "PASS primary landmark shortcut stays exact and ambiguity-safe"

let () =
  let region node_id role text : Masc.Browser_scene.node =
    { node_id; kind = Masc.Browser_scene.Region role; tag = "article"; text;
      heading_level = None;
      ancestor_region = None;
      rects = [{ x = 0.; y = 0.; width = 10.; height = 10. }];
      color = "rgb(0, 0, 0)"; font_size = 14.; font_weight = "400";
      white_space = "normal"; source_context = Masc.Browser_source_context.Unmapped }
  in
  let content : Masc.Browser_scene.t = {
    document_id = "doc"; url = "https://example.org/feed"; title = "Feed";
    width = 800.; height = 600.; scroll_x = 0.; scroll_y = 0.; truncated = false;
    view = Regions; scope = None;
    nodes = [region "nav" Masc.Browser_scene.Navigation "Navigation";
             region "post-a" Masc.Browser_scene.Article "Post A";
             region "sidebar" Masc.Browser_scene.Complementary "Suggestions";
             region "post-b" Masc.Browser_scene.Article "Post B"] }
  in
  let scene : Lane.scene = {source = Live; client_id = None; tab_id = 4;
    content; elapsed_ms = 1.} in
  let view = {(Lane.create ()) with selected_tab = Some 4; scene = Some scene} in
  let next = Lane.move_scene_article ~backwards:false {view with scene_cursor = 0} in
  assert (next.scene_cursor = 1);
  let following = Lane.move_scene_article ~backwards:false next in
  assert (following.scene_cursor = 3);
  let wrapped = Lane.move_scene_article ~backwards:false following in
  assert (wrapped.scene_cursor = 1);
  let previous = Lane.move_scene_article ~backwards:true following in
  assert (previous.scene_cursor = 1);
  let previous_wrapped = Lane.move_scene_article ~backwards:true next in
  assert (previous_wrapped.scene_cursor = 3);
  let no_articles = {view with scene = Some {scene with content =
    {content with nodes = [region "main" Masc.Browser_scene.Main "Timeline"]}}} in
  assert ((Lane.move_scene_article ~backwards:false no_articles).scene_cursor = no_articles.scene_cursor);
  let article_a : Masc.Browser_scene.region_ref =
    {node_id = "post-a"; role = Masc.Browser_scene.Article; label = "Post A"} in
  let article_b : Masc.Browser_scene.region_ref =
    {node_id = "post-b"; role = Masc.Browser_scene.Article; label = "Post B"} in
  let content_node node_id text ancestor_region : Masc.Browser_scene.node =
    {node_id; kind = Text; tag = "p"; text; heading_level = None;
     ancestor_region;
     rects = [{x = 0.; y = 0.; width = 10.; height = 10.}];
     color = "rgb(0,0,0)"; font_size = 14.; font_weight = "400";
     white_space = "normal"; source_context = Masc.Browser_source_context.Unmapped}
  in
  let content_scene = {view with scene = Some {scene with content =
    {content with view = Content; nodes = [
      content_node "a-title" "Post A" (Some article_a);
      content_node "a-body" "A body" (Some article_a);
      content_node "navigation" "Suggestions" None;
      content_node "b-title" "Post B" (Some article_b)]}}} in
  assert (Lane.scene_has_articles content_scene);
  let content_next = Lane.move_scene_article ~backwards:false
    {content_scene with scene_cursor = 0} in
  assert (content_next.scene_cursor = 3);
  let content_previous = Lane.move_scene_article ~backwards:true content_next in
  assert (content_previous.scene_cursor = 0);
  let content_without_articles = {view with scene = Some {scene with content =
    {content with view = Content; nodes = [content_node "plain" "Plain" None]}}} in
  assert (not (Lane.scene_has_articles content_without_articles));
  assert ((Lane.move_scene_article ~backwards:false content_without_articles).scene_cursor =
    content_without_articles.scene_cursor);
  print_endline "PASS article navigation uses typed regions and article ancestors"
