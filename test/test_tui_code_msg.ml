(* The Code pane's answers are [Masc_tui_code_results.msg] and travel in
   [async_msg] as [Code_msg] (#48617). The classifiers sort each answer as they
   did when the answers were constructors of [async_msg] themselves: a draft
   save is a write and every other answer is a read, and no answer waits for
   input. An answer to a request the pane never sent asks the loop for
   nothing, and a save that commits while its file is on screen asks the loop
   to read that file again. *)

module Protocol = Masc_tui_async_protocol
module Code = Masc_tui_code_results
module Fetched = Masc_tui_fetched
module Types = Masc_tui_types
module Draft = Masc_tui_code_draft

(* A fresh source has no key yet, so the equality is never consulted. *)
let request key =
  match Fetched.start ~equal:(fun _ _ -> true) Fetched.initial ~key with
  | Fetched.Started (_, request) -> request
  | Fetched.Already_loading -> Alcotest.fail "a fresh source reported a read in flight"

let unread = Error "not read"

let save_request () : Types.code_save_request =
  let address =
    { Draft.base_path = "/base"
    ; masc_root = "/base/.masc"
    ; scope = Draft.Code_scope_project
    ; path = "src/a.ml" }
  in
  let draft = Draft.create ~address ~source:{ Draft.text = "a\n"; revision = "r1" } in
  match Draft.begin_save draft with
  | Ok (_, ticket) -> { Types.csr_address = address; csr_ticket = ticket; csr_file = None }
  | Error detail -> Alcotest.failf "the draft did not start saving: %s" detail

let lsp_query () : Types.code_lsp_query =
  { Types.clq_workspace = Types.Workspace_authority 1
  ; clq_reading = ref ()
  ; clq_scope = Types.Code_scope_project
  ; clq_dir = "src"
  ; clq_file = request "src/a.ml"
  ; clq_question = "hover"
  ; clq_symbol = "f"
  ; clq_line = 1 }

(* Which answers write, with every constructor named: a new answer has to be
   placed here before this test compiles. *)
let is_write : Code.msg -> bool = function
  | Code.Code_draft_saved _ -> true
  | Code.Code_catalog_loaded _ | Code.Code_branches_loaded _
  | Code.Code_worktrees_loaded _ | Code.Code_search_loaded _
  | Code.Code_finder_file_loaded _
  | Code.Code_entries_loaded _ | Code.Code_file_loaded _
  | Code.Code_history_loaded _ | Code.Code_diff_loaded _
  | Code.Code_blame_loaded _ | Code.Code_lsp_answered _ -> false

let answers () =
  let scoped () = request (Types.Code_scope_project, "src") in
  [ "catalog", Code.Code_catalog_loaded (scoped (), unread)
  ; "branches", Code.Code_branches_loaded (scoped (), unread)
  ; "worktrees", Code.Code_worktrees_loaded (scoped (), unread)
  ; ( "search"
    , Code.Code_search_loaded
        ( request
            { Types.css_scope = Types.Code_scope_project
            ; css_dir = "src"
            ; css_query = "needle"
            ; css_ignore_case = false }
        , unread ) )
  ; "finder file", Code.Code_finder_file_loaded (scoped (), unread)
  ; "entries", Code.Code_entries_loaded (scoped (), unread)
  ; "draft saved", Code.Code_draft_saved (save_request (), Draft.Save_uncertain "no reply")
  ; "file", Code.Code_file_loaded (Types.Open_code_file, request "src/a.ml", unread)
  ; "history", Code.Code_history_loaded (scoped (), unread)
  ; ( "diff"
    , Code.Code_diff_loaded
        (request (Types.Diff_worktree { path = "src/a.ml"; base_ref = "main" }), unread) )
  ; "blame", Code.Code_blame_loaded (request "src/a.ml", unread)
  ; "lsp", Code.Code_lsp_answered (request (lsp_query ()), unread) ]

let test_a_draft_save_is_the_only_write () =
  List.iter
    (fun (name, answer) ->
      Alcotest.(check bool)
        (name ^ " is a read unless it saves")
        (not (is_write answer))
        (Protocol.workspace_message_is_read (Protocol.Code_msg answer)))
    (answers ())

let test_no_answer_waits_for_input () =
  List.iter
    (fun (name, answer) ->
      Alcotest.(check bool)
        (name ^ " does not wait for input")
        false
        (Protocol.message_waits_for_input
           ~resource_read:(fun _ -> true)
           ~recovery_loaded:(fun _ -> true)
           (Protocol.Code_msg answer)))
    (answers ())

(* The state never sent these requests and holds no draft, so every answer is
   dropped and the save has no file of its own to read again. *)
let test_an_unasked_answer_asks_for_nothing () =
  List.iter
    (fun (name, answer) ->
      let state = Types.create_state ~workspace:"test" ~port:0 () in
      Alcotest.(check bool)
        (name ^ " asks the loop for nothing")
        true
        (match Code.apply state answer with
         | Code.No_answer_followup -> true
         | Code.Reload_saved_file _ -> false))
    (answers ())

(* The server the save's address names, confirmed as the workspace on screen. *)
let confirm_workspace (state : Types.state) =
  state.server_identity <- Some
    { Masc.Tui_decode.sid_version = "test"; sid_binary_commit = "test";
      sid_binary_commit_age_s = None; sid_runtime_instance_id = None;
      sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/workspace";
      sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/.masc";
      sid_executable_in_worktree = None; sid_state_ready = Some true; sid_uptime = None;
      sid_sse_clients = None; sid_gc = None; sid_scheduler = None; sid_operator_action = None };
  state.workspace_identity <- Types.Workspace_identity_match;
  state.view <- Types.Code

let test_a_committed_save_rereads_its_file () =
  let state = Types.create_state ~workspace:"" ~port:0 () in
  confirm_workspace state;
  let reading, read =
    match Fetched.start ~equal:String.equal state.code_file ~key:"src/a.ml" with
    | Fetched.Started (next, request) -> next, request
    | Fetched.Already_loading -> Alcotest.fail "a fresh file reported a read in flight"
  in
  state.code_file <- reading;
  let source = { Masc.Tui_decode.wfs_content = "a\n"; wfs_revision = String.make 64 'a' } in
  Alcotest.(check bool) "the file read asks the loop for nothing" true
    (match Code.apply state (Code.Code_file_loaded (Types.Refresh_code_file, read,
      Ok (Code.prepare_file ~path:(Fetched.request_key read) source))) with
     | Code.No_answer_followup -> true
     | Code.Reload_saved_file _ -> false);
  state.code_focus_file <- Types.Right_pane;
  let must = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let draft = must (Code.prepare_draft state) in
  must (Code.edit_draft state draft "b\n");
  let saving, _ = must (Code.begin_draft_save state) in
  Alcotest.(check (option string)) "the committed save asks to read its file again"
    (Some "src/a.ml")
    (match Code.apply state (Code.Code_draft_saved (saving, Draft.Save_succeeded (String.make 64 'b'))) with
     | Code.Reload_saved_file path -> Some path
     | Code.No_answer_followup -> None)

(* A file with a NUL among its first 8000 bytes is binary, the rule git
   applies. It opens with no rows and no text, so copying and editing it are
   refused instead of drawing its bytes as lines of escapes or handing them to
   an editor; the next text file opens as before. *)
let test_a_binary_file_has_no_text_to_edit_or_copy () =
  let state = Types.create_state ~workspace:"" ~port:0 () in
  confirm_workspace state;
  let open_file path content =
    let reading, read =
      match Fetched.start ~equal:String.equal state.code_file ~key:path with
      | Fetched.Started (next, request) -> next, request
      | Fetched.Already_loading -> Alcotest.fail "a fresh file reported a read in flight"
    in
    state.code_file <- reading;
    let source = { Masc.Tui_decode.wfs_content = content; wfs_revision = String.make 64 'a' } in
    ignore (Code.apply state (Code.Code_file_loaded (Types.Open_code_file, read,
      Ok (Code.prepare_file ~path source))));
    state.code_focus_file <- Types.Right_pane
  in
  let document () =
    match Fetched.current state.code_file with
    | Some (_, Fetched.Ready document) -> document
    | Some (_, (Fetched.Absent | Fetched.Loading | Fetched.Stale _ | Fetched.Failed _)) | None ->
      Alcotest.fail "the opened file is not ready"
  in
  let png = "\x89PNG\r\n\x1a\n\000\000\000\rIHDR" in
  open_file "docs/a.png" png;
  Alcotest.(check bool) "a binary file keeps its size and no text" true
    ((document ()).Types.cfd_body = Types.Code_binary { bytes = String.length png });
  Alcotest.(check int) "and has no rows to draw or search" 0
    (Array.length (document ()).Types.cfd_rows);
  Alcotest.(check bool) "copying it is refused" true
    (Result.is_error (Code.copy_file_source state));
  Alcotest.(check bool) "editing it is refused" true
    (Result.is_error (Code.prepare_draft state));
  let nul_at index = String.init 9000 (fun i -> if i = index then '\000' else 'a') in
  open_file "src/early.dat" (nul_at 7999);
  Alcotest.(check bool) "a NUL as the 8000th byte makes it binary" true
    (match (document ()).Types.cfd_body with
     | Types.Code_binary _ -> true
     | Types.Code_text _ -> false);
  open_file "src/late.dat" (nul_at 8000);
  Alcotest.(check bool) "a NUL as the 8001st byte leaves it text" true
    (match (document ()).Types.cfd_body with
     | Types.Code_text _ -> true
     | Types.Code_binary _ -> false);
  open_file "src/main.ml" "let x = 1\n";
  Alcotest.(check bool) "a text file after a binary one copies" true
    (Code.copy_file_source state = Ok ("src/main.ml", "let x = 1\n"));
  Alcotest.(check bool) "and is editable" true
    (Result.is_ok (Code.prepare_draft state))

let test_revalidation_reuses_only_its_original_document () =
  let text = Bytes.to_string (Bytes.of_string "let value = 42\r\n") in
  let source : Masc.Tui_decode.workspace_file_source =
    { wfs_content = text; wfs_revision = String.make 64 'a' } in
  let prepared = Code.prepare_file ~path:"src/a.ml" source in
  let retained = "src/a.ml", prepared.Types.cpf_document in
  let fresh_source : Masc.Tui_decode.workspace_file_source =
    { wfs_content = text; wfs_revision = source.wfs_revision } in
  let reused = match Code.reuse_file ~path:"src/a.ml" retained fresh_source with
    | Some reading -> reading
    | None -> Alcotest.fail "validated original content was not reused" in
  Alcotest.(check bool) "the retained immutable document is shared" true
    (reused.cpf_document == prepared.cpf_document);
  Alcotest.(check bool) "the fresh source still owns draft observation" true
    (reused.cpf_source == fresh_source);
  let refused label path source =
    Alcotest.(check bool) label true (Option.is_none (Code.reuse_file ~path retained source)) in
  refused "another path cannot borrow preparation" "src/b.ml" fresh_source;
  refused "another revision cannot borrow preparation" "src/a.ml"
    { fresh_source with wfs_revision = String.make 64 'b' };
  refused "fresh decoded bytes require preparation" "src/a.ml"
    { fresh_source with wfs_content = Bytes.to_string (Bytes.of_string text) };
  refused "changed bytes require preparation" "src/a.ml"
    { fresh_source with wfs_content = "different" };
  let binary = Code.prepare_file ~path:"image.png"
    { wfs_content = "\000PNG"; wfs_revision = String.make 64 'a' } in
  Alcotest.(check bool) "binary size alone cannot stand for original content" true
    (Option.is_none (Code.reuse_file ~path:"image.png"
      ("image.png", binary.cpf_document) binary.cpf_source))

let () =
  Alcotest.run "tui code msg"
    [ ( "classifiers"
      , [ Alcotest.test_case "a draft save is the only Code write" `Quick
            test_a_draft_save_is_the_only_write
        ; Alcotest.test_case "no Code answer waits for input" `Quick
            test_no_answer_waits_for_input ] )
    ; ( "apply"
      , [ Alcotest.test_case "an unasked Code answer asks the loop for nothing" `Quick
            test_an_unasked_answer_asks_for_nothing
        ; Alcotest.test_case "a committed save asks to read its file again" `Quick
            test_a_committed_save_rereads_its_file
        ; Alcotest.test_case "a binary file has no text to edit or copy" `Quick
            test_a_binary_file_has_no_text_to_edit_or_copy
        ; Alcotest.test_case "revalidation retains the original immutable document" `Quick
            test_revalidation_reuses_only_its_original_document ] ) ]
