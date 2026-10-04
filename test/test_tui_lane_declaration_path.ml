module D = Masc_tui_lane_declaration
open Alcotest
let document path : D.document =
  {file_name=Filename.basename path;source_path=path;source_text="id = \"original\"";
   source_revision="read-revision";desired_revision=None;valid=false;messages=["incomplete"]}
let get = function Ok value -> value | Error detail -> fail detail
let retained_draft_uses_full_path () =
  let base = document "/current/foo.toml" in
  let draft = {(D.from_document base) with text="operator draft"} in
  let reopened = get (D.find_for_path ~path:base.source_path [draft]) |> Option.get in
  check string "same file keeps edited text" "operator draft" reopened.text;
  check bool "retained old file cannot reuse current file draft" true
    (Result.is_error (D.find_for_path ~path:"/old/foo.toml" [draft]));
  check string "rejected navigation leaves draft intact" "operator draft" draft.text
let conflict_read_keeps_source () =
  let base = document "/current/foo.toml" in
  let draft = {(D.from_document base) with text="operator draft"} in
  let current = {base with source_revision="changed";source_text="server text"} in
  let compared = D.after_response draft (D.Rejected
    {code=D.Revision_conflict;message="changed";current=Some current}) in
  let reopened = get (D.find_for_path ~path:base.source_path [compared]) |> Option.get in
  check string "comparison keeps draft" "operator draft" reopened.text;
  check string "explicit adoption keeps target" base.source_path
    (Option.get (get (D.use_current_revision reopened)).base).source_path
let create_draft_is_not_an_existing_file () =
  let draft = get (D.create "foo.toml") in
  check bool "create-only draft cannot accept another existing file" true
    (Result.is_error (D.find_for_path ~path:"/current/foo.toml" [draft]));
  check bool "another filename can start a read" true
    (get (D.find_for_path ~path:"/current/bar.toml" [draft]) = None)
let () = run "Lane declaration path identity" ["draft navigation",[
  test_case "same basename does not alias paths" `Quick retained_draft_uses_full_path;
  test_case "conflict comparison retains exact target" `Quick conflict_read_keeps_source;
  test_case "create-only draft is preserved" `Quick create_draft_is_not_an_existing_file]]
