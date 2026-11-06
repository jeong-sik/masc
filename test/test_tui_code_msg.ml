(* The Code pane's answers travel in [async_msg] as [Code_msg] (#48617). The
   classifiers sort each answer as they did when the answers were constructors
   of [async_msg] themselves: a draft save is a write and every other answer is
   a read, and no answer waits for input. *)

module Protocol = Masc_tui_async_protocol
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
let is_write : Protocol.code_msg -> bool = function
  | Protocol.Code_draft_saved _ -> true
  | Protocol.Code_catalog_loaded _ | Protocol.Code_branches_loaded _
  | Protocol.Code_worktrees_loaded _ | Protocol.Code_finder_file_loaded _
  | Protocol.Code_entries_loaded _ | Protocol.Code_file_loaded _
  | Protocol.Code_history_loaded _ | Protocol.Code_diff_loaded _
  | Protocol.Code_blame_loaded _ | Protocol.Code_lsp_answered _ -> false

let answers () =
  let scoped () = request (Types.Code_scope_project, "src") in
  [ "catalog", Protocol.Code_catalog_loaded (scoped (), unread)
  ; "branches", Protocol.Code_branches_loaded (scoped (), unread)
  ; "worktrees", Protocol.Code_worktrees_loaded (scoped (), unread)
  ; "finder file", Protocol.Code_finder_file_loaded (scoped (), unread)
  ; "entries", Protocol.Code_entries_loaded (scoped (), unread)
  ; "draft saved", Protocol.Code_draft_saved (save_request (), Draft.Save_uncertain "no reply")
  ; "file", Protocol.Code_file_loaded (Types.Open_code_file, request "src/a.ml", unread)
  ; "history", Protocol.Code_history_loaded (scoped (), unread)
  ; ( "diff"
    , Protocol.Code_diff_loaded
        (request (Types.Diff_worktree { path = "src/a.ml"; base_ref = "main" }), unread) )
  ; "blame", Protocol.Code_blame_loaded (request "src/a.ml", unread)
  ; "lsp", Protocol.Code_lsp_answered (request (lsp_query ()), unread) ]

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

let () =
  Alcotest.run "tui code msg"
    [ ( "classifiers"
      , [ Alcotest.test_case "a draft save is the only Code write" `Quick
            test_a_draft_save_is_the_only_write
        ; Alcotest.test_case "no Code answer waits for input" `Quick
            test_no_answer_waits_for_input ] ) ]
