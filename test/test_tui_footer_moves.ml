(* Zone 5 names the keys that act on this screen and none of the keys that
   move (RFC tui-one-screen-grammar sections 2 and 3.1). The moving keys --
   j/k, the page and edge keys, Enter, Esc, [ ], v, / n, f o, r, Tab and q --
   were read from the same lists as the actions, so they took most of each
   row, and on an empty list the row was too wide to keep a refused key in
   its place.

   This file pins the decisions: no zone 5 key set holds a binding of role
   [Moves]; every table marks the keys that only ever move as [Moves]; the
   first [?] page of a screen whose zone 5 lost them names them, quit
   included; the help door ([?] or the cut marker that ends in it) is on
   every row; and with the moving keys gone, the converted list rows with no
   notice fit whole at 100 and 160 cells, so a refused key stays in its place
   there. *)

open Alcotest
module Keys = Masc_tui_keys
module Footer = Masc_tui_footer
module T = Masc_tui_types

(* The surfaces whose list renderer draws [Keys.footer_row_of_surface]. *)
let typed_surfaces =
  [ ("Schedules", T.Schedules)
  ; ("Harness", T.Harness)
  ; ("Task Review", T.Verification)
  ; ("Fusion", T.Fusion)
  ; ("Clients", T.Clients)
  ; ("Workspace", T.Repositories)
  ; ("Changes", T.Changes)
  ; ("Logs", T.System_logs)
  ; ("Activity", T.Acting)
  ]

let languages = [ ("en", T.Lang_en); ("ko", T.Lang_ko) ]

let surface_actions ~has_rows surface =
  Keys.footer_actions ~detail_open:false ~has_rows ~has_reading:has_rows surface

(* Every typed row of zone 5: each converted surface empty and full, and the
   Goal list empty and full. *)
let typed_action_sets =
  List.concat_map
    (fun (name, surface) ->
      List.map
        (fun has_rows ->
          ( Printf.sprintf "%s %s" name (if has_rows then "full" else "empty"),
            surface_actions ~has_rows surface ))
        [ false; true ])
    typed_surfaces
  @ List.map
      (fun has_rows ->
        ( Printf.sprintf "Goals %s" (if has_rows then "full" else "empty"),
          Keys.planning_goal_list_actions ~has_rows ))
      [ false; true ]

let is_move (binding : Keys.binding) =
  match binding.role with Keys.Moves -> true | Keys.Acts -> false

let test_no_typed_row_holds_a_move () =
  List.iter
    (fun (name, actions) ->
      List.iter
        (fun (action : Keys.action) ->
          check bool
            (Printf.sprintf "%s: %s acts" name action.binding.key)
            false (is_move action.binding))
        actions)
    typed_action_sets

(* The role is written by hand beside each binding, so a binding added without
   it reaches zone 5. The keys below have no meaning but their section 3.1 one
   on any of these list screens, so a row that names one of them holds a key
   whose role was left out. *)
let moving_atoms =
  [ "j"; "k"; "PgUp"; "PgDn"; "Home"; "End"; "Enter"; "Esc"; "Left"; "Right";
    "Up"; "Down"; "Tab"; "q"; "?" ]

let moving_keys = [ "/"; "[ / ]"; "< / >"; ", / ." ]

(* Every table, not only the screens whose zone 5 is built from one yet: a
   screen moved to [Keys.footer_row_of_surface] later draws whatever its table
   marks [Acts]. These keys do nothing but move on every table (RFC
   tui-one-screen-grammar section 10), so a binding that spells only them and
   is marked [Acts] is a wrong mark, whichever screen holds it. *)
let only_moving_atoms = [ "j"; "k"; "PgUp"; "PgDn"; "Home"; "End"; "q" ]

let test_every_table_marks_the_keys_that_only_move () =
  check bool "the sheet lists surfaces" true (Keys.help_surfaces <> []);
  List.iter
    (fun (name, surface) ->
      List.iter
        (fun (binding : Keys.binding) ->
          let atoms = Keys.key_atoms binding.key in
          if atoms <> [] && List.for_all (fun atom -> List.mem atom only_moving_atoms) atoms
          then
            check bool (Printf.sprintf "%s: %s moves" name binding.key) true (is_move binding))
        (Keys.for_surface surface))
    Keys.help_surfaces

let check_no_moving_key name key =
  check bool (Printf.sprintf "%s does not name %s" name key) false
    (List.mem key moving_keys
     || List.exists (fun atom -> List.mem atom moving_atoms) (Keys.key_atoms key))

let test_no_typed_row_spells_a_moving_key () =
  List.iter
    (fun (name, actions) ->
      List.iter
        (fun (action : Keys.action) -> check_no_moving_key name action.binding.key)
        actions)
    typed_action_sets;
  List.iter
    (fun (language, lang) ->
      List.iter
        (fun cols ->
          let name = Printf.sprintf "Memory facts %s at %d" language cols in
          List.iter
            (fun (item : Footer.key_item) ->
              match Footer.item_key item.item with
              | Some key -> check_no_moving_key name key
              | None -> fail (name ^ ": an item without a key"))
            (Footer.row_items (Keys.footer_row_memory_facts ~lang ~cols)))
        [ 80; 200 ])
    languages

(* An item is "key:label" and items are joined by two spaces, so a key names
   an item only right after a separator. *)
let names_item hints key =
  let haystack = "  " ^ hints and needle = "  " ^ key ^ ":" in
  let needle_length = String.length needle in
  let rec scan index =
    index + needle_length <= String.length haystack
    && (String.equal (String.sub haystack index needle_length) needle || scan (index + 1))
  in
  scan 0

(* The keys that move the approval queue, written here rather than read from
   the table: a binding marked [Acts] by mistake would drop out of a list read
   from the roles, and the row would name it unseen. [Enter] reads the whole
   ask while browsing, so the browsing row leaves it out as well. In the
   answer form [Enter] sends the answer: there it acts. [Left/Right] step the
   open ask's questions, as j/k do: a line. *)
let approvals_moving_keys = [ "j/k"; "[ / ]"; "Left/Right"; "PgUp/PgDn"; "Esc"; "r"; "Tab"; "q" ]

let flags = [ false; true ]

let test_the_approvals_rows_name_no_moving_key () =
  let check_row ?(also = []) name hints =
    List.iter
      (fun key ->
        check bool (Printf.sprintf "%s does not name %s" name key) false (names_item hints key))
      (also @ approvals_moving_keys)
  in
  List.iter
    (fun (language, lang) ->
      List.iter
        (fun approvals ->
          List.iter
            (fun ask_selected ->
              List.iter
                (fun source ->
                  List.iter
                    (fun last_answer ->
                      check_row ~also:[ "Enter" ]
                        (Printf.sprintf "Approvals %s browsing" language)
                        (Keys.footer_hints_approvals ~lang
                           (Keys.Approval_browsing { approvals; ask_selected; source; last_answer })))
                    flags)
                flags)
            flags)
        flags;
      check_row ("Approvals armed " ^ language) (Keys.footer_hints_approvals ~lang Keys.Approval_armed);
      List.iter
        (fun has_choices ->
          List.iter
            (fun takes_text ->
              check_row
                (Printf.sprintf "Approvals %s answering" language)
                (Keys.footer_hints_approvals ~lang
                   (Keys.Approval_answering { has_choices; takes_text })))
            flags)
        flags)
    languages

(* The answer editor takes letters, so its Enter and Esc are its save and
   cancel (the section 3.1 exception): they act and the row names them. *)
let test_the_answer_editor_names_its_save_and_cancel () =
  let hints = Keys.footer_hints_approvals ~lang:T.Lang_en Keys.Approval_writing in
  check bool "the editor names Enter" true (names_item hints "Enter");
  check bool "the editor names Esc" true (names_item hints "Esc")

(* The Board read row is built from bindings of its own. The keys it named
   before that move: the reading's line, post and page keys, the pane and
   diagram pairs, the way back, r and Tab. *)
let board_read_moving_keys =
  [ "j/k"; "[/]"; "PgUp/PgDn"; "h/l"; ",/."; "Left / Esc"; "r"; "Tab"; "q" ]

let test_the_board_read_row_names_no_moving_key () =
  List.iter
    (fun layout ->
      List.iter
        (fun focus_posts ->
          List.iter
            (fun focus_comments ->
              List.iter
                (fun has_attachments ->
                  let hints =
                    Keys.footer_hints_board_read ~lang:T.Lang_en ~focus_posts ~focus_comments
                      ~full_history:false ~layout ~has_attachments ~has_successor:true
                  in
                  List.iter
                    (fun key ->
                      check bool ("Board read does not name " ^ key) false (names_item hints key))
                    board_read_moving_keys;
                  check bool "Board read names the copy key" true (names_item hints "Y"))
                flags)
            flags)
        flags)
    [ T.Board_read_split; T.Board_read_wide; T.Board_read_one_pane ]

(* The keys that leave zone 5 stay on the first [?] page. That page draws the
   reader's own section and nothing behind it, so Global, which comes after,
   does not count: every key of every moving binding of the surface's table,
   quit among them, is named in the surface's own section. The keys are read
   from the table, not from the sheet, so a sheet that dropped the moves would
   fail here rather than pass empty. The surfaces are the ones whose zone 5
   named q before it left: the converted lists, the Goal list, the Approvals
   queue and the Keeper roster. *)
let surfaces_whose_zone_five_lost_quit =
  typed_surfaces
  @ [ ("Goals", T.Planning); ("Approvals", T.Approvals); ("Keepers", T.Keepers T.Keeper_list) ]

let first_page_atoms sections =
  match sections with
  | (_, rows) :: _ -> List.concat_map (fun (key, _) -> Keys.key_atoms key) rows
  | [] -> []

let test_the_first_help_page_names_the_moving_keys () =
  List.iter
    (fun (name, surface) ->
      let sections = Keys.help_sections ~lang:T.Lang_en ~current:surface () in
      (match sections with
       | (title, _) :: _ ->
           check bool (name ^ " opens on its own section") true
             (String.ends_with ~suffix:Keys.here_marker title)
       | [] -> fail (name ^ ": the sheet is empty"));
      let named = first_page_atoms sections in
      let moves = List.filter is_move (Keys.for_surface surface) in
      check bool (name ^ " has keys that move") true (moves <> []);
      List.iter
        (fun (binding : Keys.binding) ->
          List.iter
            (fun atom ->
              check bool (Printf.sprintf "%s first page names %s" name atom) true
                (List.mem atom named))
            (Keys.key_atoms binding.key))
        moves;
      check bool (name ^ " first page names q") true (List.mem "q" named))
    surfaces_whose_zone_five_lost_quit

let state_in lang =
  let state = T.create_state ~workspace:"" ~port:0 () in
  state.T.ui_language <- lang;
  state

(* A lane's run list has no key that acts, so its zone 5 is the help door
   alone, and its footer named r, Tab and q before. Its first page names
   them. *)
let test_the_lane_runs_first_page_names_quit () =
  let state = state_in T.Lang_en in
  state.T.view <- T.Lanes;
  state.T.lanes_mode <- T.Lanes_run_list Lane_run_identity.Librarian;
  let named = first_page_atoms (Keys.help_sections_for_state ~cols:100 state) in
  List.iter
    (fun atom ->
      check bool ("the lane runs first page names " ^ atom) true (List.mem atom named))
    [ "Esc"; "r"; "Tab"; "q" ]

(* The agenda panel owns the keys while it is open, and every key of it
   moves. [?] there opens on the agenda's own section, which names the way
   into a row and the way out. Before, the sheet had no agenda section, so
   Enter and Esc were named nowhere once they left the footer. The help door
   on the panel's zone 5 is the renderer's argument
   ([Masc_tui_render_overlays.render_agenda] passes [~help_door:true]); the
   renderer is in the executable, which a test cannot link. *)
let test_the_agenda_first_page_names_its_keys () =
  let state = state_in T.Lang_en in
  state.T.agenda_open <- true;
  let sections = Keys.help_sections_for_state ~cols:100 state in
  (match sections with
   | (title, _) :: _ ->
       check bool "the agenda opens on its own section" true
         (String.ends_with ~suffix:Keys.here_marker title)
   | [] -> fail "the sheet is empty");
  let named = first_page_atoms sections in
  List.iter
    (fun atom -> check bool ("the agenda first page names " ^ atom) true (List.mem atom named))
    [ "j"; "k"; "Enter"; "Esc" ]

(* What zone 5 draws at [max_cells], the colour marks taken off. *)
let drawn ~lang ~max_cells keys =
  Masc_tui_render_prim.footer_line_keys (state_in lang) ~max_cells ~keys
  |> Masc_tui_theme.strip_sgr
  |> String.trim

let rows_drawn ~lang =
  List.concat_map
    (fun (name, surface) ->
      List.map
        (fun has_rows ->
          ( Printf.sprintf "%s %s" name (if has_rows then "full" else "empty"),
            Keys.footer_row ~lang (surface_actions ~has_rows surface) ))
        flags)
    typed_surfaces
  @ [ ("Goals empty", Keys.footer_row_planning_goal_list ~lang ~has_rows:false)
    ; ("Memory facts", Keys.footer_row_memory_facts ~lang ~cols:200)
    (* A lane's run list and a Board post still loading have no key that
       acts. The agenda panel has none either; it is a modal, and its door is
       its renderer's argument (see the agenda test above). *)
    ; ("no key that acts", Footer.Written "")
    ]

(* A new reader finds quit, and every key that moves, through [?]: every row
   names it, or ends in the cut marker that names it. *)
let test_every_row_keeps_the_help_door () =
  let cut_marker = Footer.cut_marker Footer.more_key in
  List.iter
    (fun (language, lang) ->
      List.iter
        (fun (name, keys) ->
          List.iter
            (fun max_cells ->
              let line = drawn ~lang ~max_cells keys in
              check bool
                (Printf.sprintf "%s %s at %d keeps ?" name language max_cells)
                true
                (List.mem Footer.more_key (Footer.advertised_key_atoms line)
                 || String.ends_with ~suffix:cut_marker line))
            [ 24; 40; 60; 80; 100; 120; 160; 200 ])
        (rows_drawn ~lang))
    languages

(* With the moving keys gone, the empty list rows that refuse a key fit whole
   at 100 and 160 cells of zone 5 when no notice leads the row: the fitter
   draws each refused key in its place, the row the full list draws, rather
   than the row of the answering keys alone. A notice takes the row's head
   until zone 4 has a row of its own (RFC tui-one-screen-grammar section 10),
   and then the refused keys go first, which test_tui_footer_row_need pins. *)
let refusing_rows ~lang =
  List.filter_map
    (fun (name, surface) ->
      let empty = surface_actions ~has_rows:false surface in
      if List.exists (fun (action : Keys.action) -> action.availability <> Keys.Available) empty
      then Some (name, empty)
      else None)
    typed_surfaces
  @ [ ("Goals", Keys.planning_goal_list_actions ~has_rows:false) ]
  |> List.map (fun (name, actions) -> (name, Keys.footer_row ~lang actions, actions))

let test_refused_keys_stay_in_place_at_common_widths () =
  List.iter
    (fun (language, lang) ->
      let rows = refusing_rows ~lang in
      check bool ("some rows refuse a key " ^ language) true (List.length rows >= 6);
      List.iter
        (fun (name, row, actions) ->
          let every_key_answering =
            Keys.footer_row ~lang
              (List.map
                 (fun (action : Keys.action) -> { action with availability = Keys.Available })
                 actions)
          in
          List.iter
            (fun max_cells ->
              check string
                (Printf.sprintf "%s %s at %d draws every key in place" name language max_cells)
                (drawn ~lang ~max_cells every_key_answering)
                (drawn ~lang ~max_cells row))
            [ 100; 160 ])
        rows)
    languages

(* The Keeper roster spells its row by hand from strings, so no role keeps a
   moving key off it: a key put back on the roster's list reaches zone 5 with
   nothing else to stop it. The keys below move on the roster -- the cursor,
   the view and order cycles, the way into a Keeper, the folds and the way
   out, the Story window's next page, reload and quit. [l] reads logs there,
   so it is not among them. Enter is not either: it opens and closes the Story
   window, which is not a move, so it acts until the roster's keys move --
   except on the Story's Memory page, where it goes into the memory browser. *)
let roster_moving_atoms = [ "j"; "k"; "v"; "o"; "Right"; "Left"; "Esc"; "Tab"; "r"; "q" ]

let roster_atoms ~lang story =
  let state = state_in lang in
  state.T.view <- T.Keepers T.Keeper_list;
  state.T.keeper_story <- story;
  Footer.advertised_key_atoms
    (Masc_tui_render_prim.keeper_control_hints ~keys:Masc_tui_render_prim.Roster_keys state None)

let test_the_keeper_roster_names_no_moving_key () =
  List.iter
    (fun (language, lang) ->
      List.iter
        (fun story ->
          let atoms = roster_atoms ~lang story in
          check bool ("the roster " ^ language ^ " names a key that acts") true (atoms <> []);
          List.iter
            (fun atom ->
              check bool
                (Printf.sprintf "the roster %s does not name %s" language atom)
                false (List.mem atom atoms))
            roster_moving_atoms)
        [ None; Some Masc_tui_keeper_story.Story; Some Masc_tui_keeper_story.Memory ];
      check bool ("the roster " ^ language ^ " names the Enter that opens Story") true
        (List.mem "Enter" (roster_atoms ~lang None));
      check bool ("the roster " ^ language ^ " names the Enter that closes Story") true
        (List.mem "Enter" (roster_atoms ~lang (Some Masc_tui_keeper_story.Story)));
      check bool
        ("the roster " ^ language ^ " does not name the Enter that goes into memory")
        false
        (List.mem "Enter" (roster_atoms ~lang (Some Masc_tui_keeper_story.Memory))))
    languages

let () =
  run "tui footer moves"
    [ ( "zone 5",
        [ test_case "no typed row holds a move" `Quick test_no_typed_row_holds_a_move
        ; test_case "no typed row spells a moving key" `Quick
            test_no_typed_row_spells_a_moving_key
        ; test_case "the approvals rows name no moving key" `Quick
            test_the_approvals_rows_name_no_moving_key
        ; test_case "the answer editor names its save and cancel" `Quick
            test_the_answer_editor_names_its_save_and_cancel
        ; test_case "the board read row names no moving key" `Quick
            test_the_board_read_row_names_no_moving_key
        ; test_case "the keeper roster names no moving key" `Quick
            test_the_keeper_roster_names_no_moving_key
        ; test_case "every table marks the keys that only move" `Quick
            test_every_table_marks_the_keys_that_only_move
        ; test_case "the first help page names the moving keys" `Quick
            test_the_first_help_page_names_the_moving_keys
        ; test_case "the lane runs first page names quit" `Quick
            test_the_lane_runs_first_page_names_quit
        ; test_case "the agenda first page names its keys" `Quick
            test_the_agenda_first_page_names_its_keys
        ; test_case "every row keeps the help door" `Quick test_every_row_keeps_the_help_door
        ; test_case "refused keys stay in place at common widths" `Quick
            test_refused_keys_stay_in_place_at_common_widths
        ] )
    ]
