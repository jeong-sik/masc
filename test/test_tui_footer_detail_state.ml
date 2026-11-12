(* A surface that owns a detail draws one footer for two states. Until the key
   table carried the state, each of those surfaces advertised exactly one key
   the dispatcher refuses in the state on screen: [Right / Enter] once a detail
   is already open, [[ / ]] while it is not. The table knew -- the help said
   "while a detail is open" -- but as prose, which no footer can read.

   Two halves are pinned here because either one alone leaves the bug
   reachable: the table has to scope the keys, and both renderers of every
   scoped surface have to say which state they are drawing. The second is an
   optional argument, so a renderer that omits it still compiles and silently
   goes back to advertising both. *)

open Alcotest
module Keys = Masc_tui_keys

(* The workspace the Code tree tests read unless a test names another. *)
let project_scope = Masc_tui_types.Code_scope_project

(* Named so a failure says which surface, not just which assertion. *)
let detail_surfaces =
  [ ("Planning", Masc_tui_types.Planning)
  ; ("Schedules", Masc_tui_types.Schedules)
  ; ("Verification", Masc_tui_types.Verification)
  ; ("Harness", Masc_tui_types.Harness)
  ; ("Changes", Masc_tui_types.Changes)
  ]

let contains haystack needle =
  let needle_length = String.length needle
  and haystack_length = String.length haystack in
  let rec scan index =
    if index + needle_length > haystack_length then false
    else if String.equal (String.sub haystack index needle_length) needle then
      true
    else scan (index + 1)
  in
  scan 0

let test_each_surface_scopes_a_key () =
  List.iter
    (fun (name, surface) ->
      check bool (name ^ " scopes at least one key to a state") true
        (Keys.has_detail_scoped_keys surface))
    detail_surfaces

let list_footer_refusals =
  [ ("Board", Masc_tui_types.Board, [ "[ / ]"; "z:"; "h/l" ])
  ; ("Fusion", Masc_tui_types.Fusion, [ "[ / ]" ])
  ; ("Resources", Masc_tui_types.Resources, [ "[ / ]" ])
  ; ("System_logs", Masc_tui_types.System_logs, [ "[ / ]" ])
  ]

(* Surfaces that draw their two states from builders of their own, not from
   [Keys.footer_hints ~detail_open]. [scoped_keys] holds their rows. *)
let builder_surfaces =
  [ ("Approvals", Masc_tui_types.Approvals)
  ; ("Acting", Masc_tui_types.Acting)
  ]

let test_each_list_footer_names_no_key_it_refuses () =
  List.iter
    (fun (name, surface, keys) ->
      check bool (name ^ " scopes at least one key to a state") true
        (Keys.has_detail_scoped_keys surface);
      let list_hints = Keys.footer_hints ~detail_open:false surface in
      (* Scoping moved the keys, it did not delete them: a caller that names
         no state still reads them, which is what the cheat sheet does. *)
      let both = Keys.footer_hints surface in
      List.iter
        (fun key ->
          check bool (name ^ " list does not advertise " ^ key) false
            (contains list_hints key);
          check bool (name ^ " naming no state still reads " ^ key) true
            (contains both key))
        keys)
    list_footer_refusals

(* The footers above are read by substring, which cannot tell a one-letter key
   from the end of another: "c:" is inside "Esc:". An item is "key:label" and
   items are joined by two spaces, so a key names an item only right after a
   separator. *)
let names_item hints key = contains ("  " ^ hints) ("  " ^ key ^ ":")

(* A key and the two footers of its surface: the one drawn where the key
   answers and the one drawn where the dispatcher refuses it.
   [t], [p], [/] and [n / N] act on the Work list; in a Goal detail [p] is
   Pause and the other three have no list to act on. [c] replies to the post
   that is open, so the Board list has nothing to reply to. [/] and [n / N]
   search the list's rows, and an open Verification, Harness or System_logs
   detail has none. *)
let search_keys name surface =
  ( name,
    Keys.footer_hints ~detail_open:false surface,
    Keys.footer_hints ~detail_open:true surface,
    [ "/"; "n / N" ] )

(* Left closes an open detail and does nothing on a list (the [Some "left"]
   arm of masc_tui.ml), so with no detail open the way back is Esc alone. The
   two rows are one fact read in two states: the list footer names Esc and not
   Left / Esc, the detail footer the reverse. *)
let back_keys name ~list ~detail =
  [ (name ^ " Left / Esc", detail, list, [ "Left / Esc" ])
  ; (name ^ " Esc", list, detail, [ "Esc" ])
  ]

let back_keys_of_surface name surface =
  back_keys name
    ~list:(Keys.footer_hints ~detail_open:false surface)
    ~detail:(Keys.footer_hints ~detail_open:true surface)

(* The queue with a row, a question under the cursor and its source: every key
   the browsing footer can name. *)
let approvals_list_footer =
  Keys.footer_hints_approvals ~lang:Masc_tui_types.Lang_en
    (Keys.Approval_browsing
       { approvals = true; asks = Keys.Ask_selected; source = true; last_answer = false })

let scoped_keys =
  [ ( "Planning",
      Keys.footer_hints_planning_goal_list ~lang:Masc_tui_types.Lang_en ~has_rows:true,
      (Keys.footer_hints_planning_goal_detail ~lang:Masc_tui_types.Lang_en),
      [ "t"; "p"; "/"; "n / N" ] )
  ; ( "Board",
      Keys.footer_hints ~detail_open:true Masc_tui_types.Board,
      Keys.footer_hints ~detail_open:false Masc_tui_types.Board,
      [ "c" ] )
  ; search_keys "Verification" Masc_tui_types.Verification
  ; search_keys "Harness" Masc_tui_types.Harness
  ; search_keys "System_logs" Masc_tui_types.System_logs
  (* Right and Enter open the entry under the cursor. An open log entry has
     nothing under them, so its footer is the list's without that key. *)
  ; ( "System_logs Right / Enter",
      Keys.footer_hints ~detail_open:false Masc_tui_types.System_logs,
      Keys.footer_hints ~detail_open:true Masc_tui_types.System_logs,
      [ "Right / Enter" ] )
  (* [l], [v] and [c] change the list's filters and put its cursor back on the
     first row. An open log entry keeps its place, so [ and ] would step from
     the wrong row; the dispatcher declines all three while one is open. *)
  ; ( "System_logs filters",
      Keys.footer_hints ~detail_open:false Masc_tui_types.System_logs,
      Keys.footer_hints ~detail_open:true Masc_tui_types.System_logs,
      [ "l"; "v"; "c" ] )
  (* The Approvals queue and an open approval draw from two builders of their
     own ([footer_hints_approvals], [footer_hints_approval_detail]), so no
     [footer_hints ~detail_open] call reaches them. [v] reads a Gate string's
     decoded values as bytes: the dispatcher answers it only once an approval
     is open, and that footer names it whenever the approval has values to
     read, as "string bytes" or, once they are shown, as "text". *)
  ; ( "Approvals string bytes",
      Keys.footer_hints_approval_detail ~lang:Masc_tui_types.Lang_en ~value_hint:Keys.Readable_values,
      approvals_list_footer,
      [ "v" ] )
  ; ( "Approvals text",
      Keys.footer_hints_approval_detail ~lang:Masc_tui_types.Lang_en ~value_hint:Keys.Byte_values,
      approvals_list_footer,
      [ "v" ] )
  ]
  @ back_keys "Planning"
      ~list:(Keys.footer_hints_planning_goal_list ~lang:Masc_tui_types.Lang_en ~has_rows:true)
      ~detail:(Keys.footer_hints_planning_goal_detail ~lang:Masc_tui_types.Lang_en)
  @ back_keys_of_surface "Board" Masc_tui_types.Board
  @ back_keys_of_surface "Schedules" Masc_tui_types.Schedules
  @ back_keys_of_surface "Verification" Masc_tui_types.Verification
  @ back_keys_of_surface "Harness" Masc_tui_types.Harness
  @ back_keys_of_surface "System_logs" Masc_tui_types.System_logs
  @ back_keys_of_surface "Changes" Masc_tui_types.Changes
  (* Runtime draws its two states from two builders, not from one table read
     twice: the readings' footer and the detail's own. *)
  @ back_keys "Runtime"
      ~list:(Keys.footer_hints_runtime ~lang:Masc_tui_types.Lang_en
         ~mode:Masc_tui_types.Runtime_lanes ~picker:None)
      ~detail:(Keys.footer_hints_runtime_detail ~ko:false ~routes:false ())
  (* Repositories draws Git changes from a footer of its own; the repository
     list under it has nothing for Left to close, so Esc alone returns to
     Dashboard. *)
  @ back_keys "Repositories"
      ~list:(Keys.footer_hints Masc_tui_types.Repositories)
      ~detail:Keys.footer_hints_git_changes
  (* Code at the project root has no step for Left ([code_back_step]); a
     directory down, Left climbs one. *)
  @ back_keys "Code tree"
      ~list:(Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_root (Keys.File_current, project_scope)))
      ~detail:(Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_tree (Keys.File_current, project_scope)))
  (* Right and Enter open a tree row. An open file has nothing under them, so
     the file pane's footer is the tree's without that key. *)
  @ [ ( "Code Right / Enter",
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_tree (Keys.File_current, project_scope)),
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:Keys.Code_file,
        [ "Right / Enter" ] )
    (* [h] and [l] move focus between the tree and a file, and only while a
       file read is current ([Keys.code_file_is_current]); with none the
       dispatcher ends in [()]. *)
    ; ( "Code h/l below the project root",
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_tree (Keys.File_current, project_scope)),
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_tree (Keys.No_file, project_scope)),
        [ "h/l" ] )
    ; ( "Code h/l at the project root",
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_root (Keys.File_current, project_scope)),
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_root (Keys.No_file, project_scope)),
        [ "h/l" ] )
    (* [d] on the list opens the project's Git changes, and only the project's
       own workspace has that arm ([Keys.code_tree_opens_changes]): a keeper's
       or a repository's tree ends in [()]. *)
    ; ( "Code d on a keeper's list",
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_tree (Keys.File_current, project_scope)),
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en
          ~pane:(Keys.Code_tree (Keys.File_current, Masc_tui_types.Code_scope_keeper "scout")),
        [ "d" ] )
    ; ( "Code d on a repository's list",
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.Code_tree (Keys.File_current, project_scope)),
        Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en
          ~pane:(Keys.Code_tree (Keys.File_current, Masc_tui_types.Code_scope_repo "masc")),
        [ "d" ] ) ]

let test_a_scoped_key_is_named_only_where_it_answers () =
  List.iter
    (fun (name, answering, refusing, keys) ->
      List.iter
        (fun key ->
          check bool (name ^ " names " ^ key ^ " where it answers") true
            (names_item answering key);
          check bool (name ^ " does not name " ^ key ^ " where it is refused")
            false (names_item refusing key))
        keys)
    scoped_keys

(* The draft keys act on an open file only: the dispatcher needs the file pane
   focused with no diff, history or notes drawn over it. The tree and diff
   footers used to name them anyway. *)
let draft_keys = [ "e"; "S"; "V"; "X"; "A (draft)" ]

let test_code_draft_keys_are_named_only_on_the_file_pane () =
  let file = Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:Keys.Code_file in
  List.iter
    (fun key ->
      check bool ("the file pane names " ^ key) true (names_item file key);
      List.iter
        (fun (pane_name, pane) ->
          check bool
            (pane_name ^ " pane does not name " ^ key)
            false
            (names_item (Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane) key))
        [ ("tree", Keys.Code_tree (Keys.File_current, project_scope)); ("diff", Keys.Code_diff) ])
    draft_keys

(* The ladder Esc and Left walk on Code, and the footer pane drawn at each
   rung. The tree footer names Left only where the ladder has a step for it,
   and the project root is the one tree state where it has none, so the state
   has to reach [Code_root] and no other. The names come from exhaustive
   matches: a new rung or pane stops this file compiling until it is named. *)
module T = Masc_tui_types

let step_name = function
  | Keys.Close_code_notes -> "close notes"
  | Keys.Close_code_diff -> "close diff"
  | Keys.Close_code_history -> "close history"
  | Keys.Return_to_code_tree -> "return to tree"
  | Keys.Climb_code_directory -> "climb directory"
  | Keys.Climb_to_code_project -> "climb to project"
  | Keys.Leave_code_for_workspace -> "leave for workspace"

let pane_name = function
  | Keys.Code_tree _ -> "tree"
  | Keys.Code_root _ -> "root"
  | Keys.Code_file -> "file"
  | Keys.Code_diff -> "diff"
  | Keys.Code_notes -> "notes"
  | Keys.Code_history -> "history"

let open_file (state : T.state) = state.T.code_focus_file <- T.Right_pane

(* Opening a diff closes the history and closing a commit diff reopens it, and
   the memo key is dead over a diff, so no state has two overlays open. *)
let code_rungs =
  [ ("the project root", (fun (_ : T.state) -> ()), "leave for workspace", "root")
  ; ("a directory", (fun s -> s.T.code_dir <- "lib"), "climb directory", "tree")
  ; ( "a keeper's root",
      (fun s -> s.T.code_scope <- T.Code_scope_keeper "scout"),
      "climb to project",
      "tree" )
  ; ( "a repository's root",
      (fun s -> s.T.code_scope <- T.Code_scope_repo "masc"),
      "climb to project",
      "tree" )
  ; ( "a directory in a keeper's tree",
      (fun s ->
        s.T.code_scope <- T.Code_scope_keeper "scout";
        s.T.code_dir <- "lib"),
      "climb directory",
      "tree" )
  ; ("an open file", open_file, "return to tree", "file")
  ; ( "the history",
      (fun s ->
        open_file s;
        s.T.code_history_open <- true),
      "close history",
      "history" )
  ; ( "a diff",
      (fun s ->
        open_file s;
        s.T.code_diff_open <- true),
      "close diff",
      "diff" )
  ; ( "the notes",
      (fun s ->
        open_file s;
        s.T.code_notes_open <- true),
      "close notes",
      "notes" )
  ]

let test_the_footer_pane_follows_the_ladder_rung () =
  List.iter
    (fun (name, edit, step, pane) ->
      let state =
        T.create_state ~workspace:"test" ~port:8935 ()
      in
      edit state;
      check string (name ^ ": the step Esc and Left take") step
        (step_name (Keys.code_back_step state));
      check string (name ^ ": the pane the footer is drawn for") pane
        (pane_name (Keys.code_pane_of state)))
    code_rungs

(* [code_pane_of] and the dispatcher's [h] / [l] arm read one predicate, so the
   tree footer drops the pair exactly while the keys end in [()]: until a file
   read starts, and not after. *)
let test_the_tree_names_h_l_once_a_file_read_is_current () =
  let state = T.create_state ~workspace:"test" ~port:8935 () in
  let names_h_l () =
    names_item (Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.code_pane_of state)) "h/l"
  in
  check bool "no file read is current at first" false
    (Keys.code_file_is_current state);
  check bool "the tree footer drops h/l" false (names_h_l ());
  (match
     Masc_tui_fetched.start ~equal:String.equal state.T.code_file
       ~key:"src/a.ml"
   with
   | Masc_tui_fetched.Started (reading, _) -> state.T.code_file <- reading
   | Masc_tui_fetched.Already_loading ->
       fail "a fresh file reported a read in flight");
  check bool "a started read is current" true (Keys.code_file_is_current state);
  check bool "the tree footer names h/l" true (names_h_l ())

(* The dispatcher's [d] arm on the file list and the tree footer read
   [code_tree_opens_changes], so the footer names the key for exactly the
   workspaces whose list answers it. The scope reaches the footer through
   [code_pane_of], the way the renderer hands it over. *)
let test_the_tree_names_d_where_the_list_opens_the_changes () =
  List.iter
    (fun (name, scope) ->
      let state = T.create_state ~workspace:"test" ~port:8935 () in
      state.T.code_scope <- scope;
      check bool
        (name ^ ": the tree footer names d where the arm answers")
        (Keys.code_tree_opens_changes scope)
        (names_item (Keys.footer_hints_code ~lang:Masc_tui_types.Lang_en ~pane:(Keys.code_pane_of state)) "d"))
    [ ("the project", T.Code_scope_project)
    ; ("a keeper", T.Code_scope_keeper "scout")
    ; ("a repository", T.Code_scope_repo "masc") ]

let test_every_scoped_surface_is_named () =
  let named =
    List.map (fun (_, surface, _) -> surface) list_footer_refusals
    @ List.map snd detail_surfaces
    @ List.map snd builder_surfaces
  in
  List.iter
    (fun (label, surface) ->
      if Keys.has_detail_scoped_keys surface then
        check bool (label ^ " scopes a key and is named here") true
          (List.exists (fun s -> s = surface) named))
    Keys.help_surfaces

let () =
  run "tui footer detail state"
    [ ( "table",
        [ test_case "each surface scopes a key" `Quick
            test_each_surface_scopes_a_key
        ; test_case "each list footer names no key it refuses" `Quick
            test_each_list_footer_names_no_key_it_refuses
        ; test_case "a scoped key is named only where it answers" `Quick
            test_a_scoped_key_is_named_only_where_it_answers
        ; test_case "code draft keys are named only on the file pane" `Quick
            test_code_draft_keys_are_named_only_on_the_file_pane
        ; test_case "the code footer pane follows the ladder rung" `Quick
            test_the_footer_pane_follows_the_ladder_rung
        ; test_case "the tree names h/l once a file read is current" `Quick
            test_the_tree_names_h_l_once_a_file_read_is_current
        ; test_case "the tree names d where the list opens the changes" `Quick
            test_the_tree_names_d_where_the_list_opens_the_changes
        ; test_case "every scoped surface is named here" `Quick
            test_every_scoped_surface_is_named
        ] )
    ; ( "renderers",
        [] )
    ]
