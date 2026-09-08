open Masc_tui_types
module Layout = Masc_tui_board_read_layout
module Detail = Masc_tui_board_detail

let post =
  { bp_id = "post"; bp_author = "author"; bp_title = "Thread";
    bp_body = "Body"; bp_votes = 0; bp_comment_count = 128;
    bp_created_at = "2026-09-08"; bp_updated_at = 0.;
    bp_hearth = None; bp_kind = None }

let comments = List.init 128 (fun index ->
  { bc_id = string_of_int index; bc_parent_id = None; bc_author = "keeper";
    bc_content = Printf.sprintf "comment-%03d 한글 **Markdown**" index;
    bc_created_at = "2026-09-08" })

let source : Layout.source =
  { post; detail = Detail.Ready (post, comments); related_posts = [post];
    keeper_names = ["keeper"]; columns = 100; styles = ["cyan"];
    table_frame = false }

let render source () =
  let body = [source.Layout.post.bp_body] in
  let rows = match source.detail with
    | Detail.Ready (_, comments) -> List.map (fun c -> c.bc_content) comments
    | Detail.Absent -> ["absent"]
    | Detail.Loading -> ["loading"]
    | Detail.Failed error -> [error]
  in
  body, rows

let test_long_thread_scroll_reuses_rows () =
  let cache = Layout.create () in
  let renders = ref 0 in
  let get source = Layout.get cache ~source ~render:(fun () ->
    incr renders; render source ()) in
  let first = get source in
  for index = 0 to 127 do
    let rows = get {source with keeper_names = List.map Fun.id source.keeper_names} in
    Alcotest.(check string) "all comments remain reachable"
      (List.nth comments index).bc_content (Layout.comment_line rows index)
  done;
  Alcotest.(check int) "one layout across scrolling" 1 !renders;
  Alcotest.(check int) "entire thread retained" 128 (Layout.comment_count first);
  (* A JSON refresh creates fresh records even when the document is unchanged. *)
  let copied = List.map (fun c -> {c with bc_content = String.concat "" [c.bc_content; ""]}) comments in
  ignore (get {source with detail = Detail.Ready (post, copied)});
  Alcotest.(check int) "equal refresh reuses wrapping" 1 !renders

let test_live_inputs_replace_rows () =
  let cases =
    [ "body", {source with post = {post with bp_body = "edited body"}};
      "post author", {source with post = {post with bp_author = "new-author"}};
      "comment edit", {source with detail = Detail.Ready (post,
        List.map (fun c -> if c.bc_id = "127" then {c with bc_content = "edited tail"} else c) comments)};
      "append", {source with detail = Detail.Ready (post,
        comments @ [{(List.hd comments) with bc_id = "128"; bc_content = "new reply"}])};
      "reply parent", {source with detail = Detail.Ready (post,
        List.map (fun c -> if c.bc_id = "127" then {c with bc_parent_id = Some "0"} else c) comments)};
      "related posts", {source with related_posts = [{post with bp_body = "new reference"}]};
      "keeper roles", {source with keeper_names = []};
      "width", {source with columns = 60};
      "style", {source with styles = ["dark cyan"]};
      "tables", {source with table_frame = true};
      "loading", {source with detail = Detail.Loading};
      "error", {source with detail = Detail.Failed "offline"};
      "absent", {source with detail = Detail.Absent} ] in
  List.iter (fun (label, changed) ->
    let cache = Layout.create () in
    ignore (Layout.get cache ~source ~render:(render source));
    let renders = ref 0 in
    let rows = Layout.get cache ~source:changed ~render:(fun () ->
      incr renders; render changed ()) in
    Alcotest.(check int) label 1 !renders;
    let expected_body, expected_comments = render changed () in
    Alcotest.(check string) (label ^ " body") (List.hd expected_body) (Layout.body_line rows 0);
    List.iteri (fun index expected ->
      Alcotest.(check string) (label ^ " comment") expected (Layout.comment_line rows index)) expected_comments
  ) cases

let test_failed_render_and_single_document () =
  let cache = Layout.create () in
  let initial = Layout.get cache ~source ~render:(render source) in
  let changed = {source with columns = 80} in
  (try ignore (Layout.get cache ~source:changed ~render:(fun () -> raise Exit)) with Exit -> ());
  let recovered = Layout.get cache ~source ~render:(fun () -> Alcotest.fail "lost good rows") in
  Alcotest.(check bool) "failed render keeps previous complete rows" true (initial == recovered);
  ignore (Layout.get cache ~source:changed ~render:(render changed));
  let renders = ref 0 in
  ignore (Layout.get cache ~source ~render:(fun () -> incr renders; render source ()));
  Alcotest.(check int) "only one document retained" 1 !renders

let () = Alcotest.run "Board document layout"
  ["scroll and refresh", [
    Alcotest.test_case "128 comments scroll without re-layout" `Quick test_long_thread_scroll_reuses_rows;
    Alcotest.test_case "every live layout input invalidates" `Quick test_live_inputs_replace_rows;
    Alcotest.test_case "failed rendering and one document ownership" `Quick test_failed_render_and_single_document]]
