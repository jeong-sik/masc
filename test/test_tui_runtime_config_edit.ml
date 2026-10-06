module Edit = Masc_tui_runtime_config_edit

let document text revision =
  { Edit.path = "/workspace/config/runtime.toml";
    source_text = text; source_revision = revision }
let initial = document "value = 1\n" "initial"
let newer = document "value = 3\n" "newer"
let draft = "value = 2\n# operator draft\n"
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let same = Alcotest.(check string)

let retry_after_failure () =
  let session = Edit.open_document initial |> Edit.edit draft
    |> Edit.failed "preview refused" |> Edit.observe newer |> ok in
  same "draft survives refusal and read" draft session.text;
  same "read never adopts revision" "initial" session.base.source_revision;
  same "read never changes base text" initial.source_text session.base.source_text;
  Alcotest.(check (option string)) "failure remains visible" (Some "preview refused") session.error;
  let retry = Edit.adopt_current session |> ok in
  same "explicit adoption keeps draft" draft retry.text;
  same "retry guards displayed revision" "newer" retry.base.source_revision;
  let changed_again = document "value = 4\n" "newest" in
  let session = Edit.failed "conflict again" retry |> Edit.observe changed_again |> ok in
  same "second conflict retains draft" draft session.text;
  same "second conflict keeps retry base" "newer" session.base.source_revision

let explicit_replacement () =
  let session = Edit.open_document initial |> Edit.edit draft
    |> Edit.failed "save outcome unknown" |> Edit.observe newer |> ok in
  let session = Edit.replace_with_current session |> ok in
  same "replace copies current text" newer.source_text session.text;
  same "replace adopts current revision" newer.source_revision session.base.source_revision;
  Alcotest.(check (option string)) "old error cleared" None session.error

let foreign_document () =
  let session = Edit.open_document initial |> Edit.edit draft in
  let foreign = { newer with path = "/other/runtime.toml" } in
  (match Edit.observe foreign session with
   | Error _ -> () | Ok _ -> Alcotest.fail "foreign path accepted");
  same "foreign observation preserves draft" draft session.text;
  List.iter (fun action -> match action session with
    | Error _ -> () | Ok _ -> Alcotest.fail "adopted without a current file")
    [Edit.adopt_current; Edit.replace_with_current]

let comparison_survives_refresh () =
  let module T = Masc_tui_types in
  let state = T.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  let workspace = ("/workspace", "/workspace/.masc") in
  let session = Edit.open_document initial |> Edit.edit draft |> Edit.observe newer |> ok in
  T.put_runtime_config_edit state ~workspace session;
  let edit = List.hd state.runtime_config_edits in
  state.runtime_config_edits <- [{ edit with rce_view = T.Config_edit_current [] }];
  let latest = document "value = 4\n# latest comparison\n" "latest" in
  let refreshed = Edit.observe latest session |> ok in
  T.put_runtime_config_edit ~preserve_view:true state ~workspace refreshed;
  let edit = List.hd state.runtime_config_edits in
  same "polling retains operator draft" draft edit.rce_session.text;
  (match edit.rce_view with
   | T.Config_edit_current rows ->
       Alcotest.(check bool) "comparison rows reflect latest snapshot" true
         (rows = T.runtime_config_source_rows ~path:latest.path latest.source_text)
   | T.Config_edit_draft -> Alcotest.fail "polling withdrew comparison view");
  T.put_runtime_config_edit state ~workspace refreshed;
  (match (List.hd state.runtime_config_edits).rce_view with
   | T.Config_edit_draft -> ()
   | T.Config_edit_current _ -> Alcotest.fail "explicit edit did not select draft")

let () = Alcotest.run "runtime config draft recovery"
  [ "operator flows", [
      Alcotest.test_case "comparison survives a refreshed observation" `Quick comparison_survives_refresh;
      Alcotest.test_case "retry after refusal and concurrent edits" `Quick retry_after_failure;
      Alcotest.test_case "replace only after explicit choice" `Quick explicit_replacement;
      Alcotest.test_case "foreign current file cannot replace draft" `Quick foreign_document;
    ] ]
