(* The move keys of the lists RFC tui-one-screen-grammar §3.1 names, as
   decisions over the TUI state: which list a move key walks on the surface
   on screen, which place each key selects, that no move key folds or
   unfolds a group, and that a detail beside or above a list keeps one
   height for every selection (§8). Nothing here reads drawn text.

   Every move goes through [Masc_tui_list_moves.moves], the choice the
   dispatcher makes, and never calls a list's own walk directly: a test that
   called the walk could not see the dispatcher send the key to the wrong
   list. *)

open Masc_tui_types
module Model = Masc_tui_keeper_list_model
module Moves = Masc_tui_list_moves
module Key = Masc_tui_scroll

let every_key = Key.[ Line_down; Line_up; Page_down; Page_up; To_top; To_end ]

(* A list drawn [height] rows tall, as the dispatcher hands it over. *)
let drawn ~height rows () = Some { Moves.os_height = height; os_rows = rows }

(* The rows the dispatcher hands over on the Keeper list: every Keeper,
   placed by choosing it, which opens its group (what a search does). The
   move keys must not use them; if they did, Home would open the first
   group again. *)
let keeper_rows state =
  Some
    { Moves.rl_count = List.length state.keepers
    ; rl_cursor = state.keeper_cursor
    ; rl_place = choose_keeper_row state }

let press ~on_screen state key =
  match Moves.moves state ~on_screen with
  | Some moves -> moves key
  | None -> Alcotest.fail "no list answered the move key"

let roster_keeper name : Tui_decode.keeper =
  { k_origin = Tui_decode.Persisted_keeper
  ; k_name = name
  ; k_paused = false
  ; k_identity =
      Ok { k_trace_id = "trace-" ^ name; k_created_at = "2026-01-01T00:00:00Z"
         ; k_updated_at = "2026-01-01T00:00:00Z" }
  ; k_activity = None
  }

let keeper_list ~view names =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Keepers Keeper_list;
  state.keeper_list_view <- view;
  state.keeper_list_sort <- Model.Name;
  state.keeper_list_density <- Model.One_line;
  state.keepers <- List.map roster_keeper names;
  state

(* A page of the drawn height less one: [height] 3 pages by 2. *)
let press_keeper ?(height = 3) state key =
  press ~on_screen:(drawn ~height (keeper_rows state)) state key

let stop_index state =
  Option.bind (keeper_list_stop state) (fun stop ->
    List.find_index (( = ) stop) (keeper_list_stops state))

let headings state =
  List.filter_map (function
    | Model.Stop_heading group -> Some group
    | Model.Stop_world | Model.Stop_row _ -> None)
    (keeper_list_stops state)

(* The QA sweep's case: a World view whose only group is folded. Home went to
   the first Keeper, which unfolded the group and skipped the World row and
   the heading. Every move key now lands on a stop and the fold stays. *)
let test_no_move_key_unfolds_a_group () =
  let state = keeper_list ~view:Model.By_memory [ "alpha"; "beta"; "gamma" ] in
  let group =
    match headings state with
    | [ group ] -> group
    | groups -> Alcotest.failf "expected one heading, got %d" (List.length groups)
  in
  state.keeper_list_folded <- [ group ];
  List.iter
    (fun move ->
      place_keeper_list_stop state (Model.Stop_heading group);
      press_keeper state move;
      Alcotest.(check bool) "the group stays folded" true
        (state.keeper_list_folded = [ group ]);
      Alcotest.(check bool) "the selection is World or the heading" true
        (match keeper_list_stop state with
         | Some (Model.Stop_world | Model.Stop_heading _) -> true
         | Some (Model.Stop_row _) | None -> false))
    every_key;
  place_keeper_list_stop state (Model.Stop_heading group);
  press_keeper state Key.To_top;
  Alcotest.(check bool) "Home is the World row" true
    (keeper_list_stop state = Some Model.Stop_world);
  press_keeper state Key.To_end;
  Alcotest.(check bool) "End is the folded heading" true
    (keeper_list_stop state = Some (Model.Stop_heading group))

(* With the group open the stops are World, the heading and three rows. The
   first reading folds a group it has not seen before (RFC-0515 E26), so the
   test opens it after that reading, as a reader's Enter would. *)
let test_every_move_key_walks_the_stops () =
  let state = keeper_list ~view:Model.By_memory [ "alpha"; "beta"; "gamma" ] in
  ignore (keeper_list_stops state);
  state.keeper_list_folded <- [];
  Alcotest.(check int) "World, one heading and three rows" 5
    (List.length (keeper_list_stops state));
  let from_index index height key =
    Option.iter (place_keeper_list_stop state) (List.nth_opt (keeper_list_stops state) index);
    press_keeper ~height state key;
    stop_index state
  in
  List.iter
    (fun (from, height, key, expected) ->
      Alcotest.(check (option int)) (Printf.sprintf "from stop %d" from) (Some expected)
        (from_index from height key))
    Key.
      [ 0, 3, Line_down, 1; 1, 3, Line_down, 2; 0, 3, Line_up, 0; 4, 3, Line_down, 4
      ; 3, 3, Line_up, 2; 0, 3, Page_down, 2; 1, 10, Page_down, 4; 4, 3, Page_up, 2
      ; 2, 10, Page_up, 0; 3, 3, To_top, 0; 1, 3, To_end, 4 ]

(* Every view the Keeper list has, every move key, from every stop, with every
   group folded and then with none: the key lands on a stop of that list,
   leaves the folds as they were, and Home and End are the first and last
   stop. The By_memory case above is one view; the rule is the list's. *)
let every_view =
  Model.[ Plain; By_state; By_cause; By_time; By_memory; By_age; By_runtime; Day_wall ]

let test_every_view_moves_over_its_stops () =
  List.iter
    (fun view ->
      let state = keeper_list ~view [ "alpha"; "beta"; "gamma"; "delta" ] in
      ignore (keeper_list_stops state);
      let all_groups = headings state in
      List.iter
        (fun folded ->
          state.keeper_list_folded <- folded;
          let stops = keeper_list_stops state in
          let last = List.length stops - 1 in
          List.iteri
            (fun from stop ->
              List.iter
                (fun key ->
                  place_keeper_list_stop state stop;
                  press_keeper state key;
                  let label = Printf.sprintf "view %d folded %d from %d"
                      (Option.value ~default:(-1)
                         (List.find_index (( = ) view) every_view))
                      (List.length folded) from in
                  Alcotest.(check bool) (label ^ ": folds kept") true
                    (state.keeper_list_folded = folded);
                  Alcotest.(check bool) (label ^ ": lands on a stop") true
                    (Option.is_some (stop_index state));
                  match key with
                  | Key.To_top ->
                      Alcotest.(check (option int)) (label ^ ": Home") (Some 0) (stop_index state)
                  | Key.To_end ->
                      Alcotest.(check (option int)) (label ^ ": End") (Some last) (stop_index state)
                  | Key.Line_down | Key.Line_up | Key.Page_down | Key.Page_up -> ())
                every_key)
            stops)
        [ all_groups; [] ])
    every_view

(* A plain list has only rows, and an empty one has nothing to move. *)
let test_plain_and_empty_lists () =
  let state = keeper_list ~view:Model.Plain [ "alpha"; "beta" ] in
  Alcotest.(check int) "one stop per row" 2 (List.length (keeper_list_stops state));
  press_keeper state Key.To_end;
  Alcotest.(check (option int)) "End is the last row" (Some 1) (stop_index state);
  press_keeper state Key.To_top;
  Alcotest.(check (option int)) "Home is the first row" (Some 0) (stop_index state);
  let empty = keeper_list ~view:Model.Plain [] in
  List.iter (fun key ->
    press_keeper empty key;
    Alcotest.(check int) "an empty list keeps its cursor" 0 empty.keeper_cursor)
    every_key;
  let world = keeper_list ~view:Model.By_memory [] in
  List.iter (fun key ->
    press_keeper world key;
    Alcotest.(check bool) "an empty World view stays on World" true
      (keeper_list_stop world = Some Model.Stop_world))
    every_key

(* Overview's destinations, in the order the plain list draws them. *)
let destinations state =
  let prepared = Masc_tui_home.prepare state in
  List.map fst
    (Masc_tui_home.home_decision_rows prepared
     @ Masc_tui_home.home_operator_rows prepared
     @ Masc_tui_home.home_continue_rows prepared)

let home_index state =
  Option.bind (Masc_tui_home.home_selected_action (Masc_tui_home.prepare state)) (fun action ->
    List.find_index (equal_home_action action) (destinations state))

let overview_with_goals count =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Overview;
  state.goals_to_confirm <-
    Masc_tui_agenda.Read
      (List.init count (fun index ->
         { Masc_tui_agenda.goal_id = Printf.sprintf "goal-%d" index
         ; title = Printf.sprintf "Goal %d" index
         ; since_iso = "2026-11-19T00:00:00Z" }));
  state

(* PgDn, PgUp, Home and End did nothing here: only j and k had a handler.
   Overview has no row list, so a choice that sent it to one answers no key. *)
let test_overview_answers_every_move_key () =
  let state = overview_with_goals 4 in
  let count = List.length (destinations state) in
  Alcotest.(check bool) "the list has more than a page of two" true (count > 4);
  let last = count - 1 in
  (* Overview has no row cursor, so the dispatcher hands over only the rows
     it drew. *)
  let press_home ~height key = press ~on_screen:(drawn ~height None) state key in
  let from_index index height key =
    state.home_selected <- List.nth_opt (destinations state) index;
    press_home ~height key;
    home_index state
  in
  List.iter
    (fun (from, height, key, expected) ->
      Alcotest.(check (option int)) (Printf.sprintf "from destination %d" from) (Some expected)
        (from_index from height key))
    Key.
      [ 0, 3, Line_down, 1; 0, 3, Line_up, 0; 0, 3, Page_down, 2; 3, 3, Page_up, 1
      ; 1, 10, Page_up, 0; 1, 100, Page_down, last; 2, 3, To_top, 0; 0, 3, To_end, last
      ; last, 3, Line_down, last ];
  (* A selection the list no longer holds starts again at an edge. *)
  state.home_selected <- Some (Home_request (Home_goal_confirmation "gone"));
  press_home ~height:3 Key.Line_down;
  Alcotest.(check (option int)) "a lost selection steps to the first row" (Some 0)
    (home_index state);
  state.home_selected <- Some (Home_request (Home_goal_confirmation "gone"));
  press_home ~height:3 Key.To_end;
  Alcotest.(check (option int)) "a lost selection's End is the last row" (Some last)
    (home_index state)

(* A list that moves its row cursor: the landing for every move key, over an
   empty list, one row and six, from the first row, a middle row and the
   last. [None] when the key placed nothing. *)
let landing ?(height = 4) state ~count ~cursor key =
  let placed = ref None in
  let rows =
    Some { Moves.rl_count = count; rl_cursor = cursor; rl_place = (fun index -> placed := Some index) }
  in
  press ~on_screen:(drawn ~height rows) state key;
  !placed

let test_row_lists_move_their_cursor () =
  let state = create_state ~workspace:"" ~port:0 () in
  List.iter
    (fun view ->
      state.view <- view;
      List.iter
        (fun (count, cursor, height, key, expected) ->
          Alcotest.(check (option int))
            (Printf.sprintf "%d rows from %d" count cursor) expected
            (landing ~height state ~count ~cursor key))
        Key.
          [ 0, 0, 4, Line_down, None; 0, 0, 4, To_end, None; 0, 0, 4, Page_down, None
          ; 1, 0, 4, Line_down, Some 0; 1, 0, 4, Line_up, Some 0; 1, 0, 4, Page_down, Some 0
          ; 1, 0, 4, To_top, Some 0; 1, 0, 4, To_end, Some 0
          ; 6, 0, 4, Line_down, Some 1; 6, 0, 4, Line_up, Some 0; 6, 0, 4, Page_down, Some 3
          ; 6, 0, 4, Page_up, Some 0; 6, 0, 4, To_top, Some 0; 6, 0, 4, To_end, Some 5
          ; 6, 3, 4, Line_down, Some 4; 6, 3, 4, Line_up, Some 2; 6, 3, 4, Page_down, Some 5
          ; 6, 3, 4, Page_up, Some 0; 6, 3, 4, To_top, Some 0; 6, 3, 4, To_end, Some 5
          ; 6, 5, 4, Line_down, Some 5; 6, 5, 10, Page_down, Some 5; 6, 5, 10, Page_up, Some 0 ])
    [ Repositories; Verification; Harness; Clients; Memory; Changes; Connectors; Runtime
    ; System_logs; Board; Fusion; Schedules; Planning; Lanes; Code; Resources ]

(* An overlay drawn over a surface moves its own list, even over the two
   surfaces that walk something else: the Git changes list over the Keeper
   list moved the roster before its keys were gathered here. *)
let test_an_overlay_moves_its_own_rows () =
  let state = keeper_list ~view:Model.By_memory [ "alpha"; "beta" ] in
  state.repository_changes_open <- true;
  let before = keeper_list_stop state in
  Alcotest.(check (option int)) "the overlay's End is its last row" (Some 3)
    (landing state ~count:4 ~cursor:1 Key.To_end);
  Alcotest.(check bool) "the roster under it does not move" true
    (keeper_list_stop state = before);
  state.repository_changes_open <- false;
  state.view <- Overview;
  state.context_inspector_open <- true;
  Alcotest.(check (option int)) "the inspector's Home is its first row" (Some 0)
    (landing state ~count:4 ~cursor:2 Key.To_top)

let repository ?(status = Repo_manager_types.Active) ?(keepers = []) name path :
    Tui_decode.repository =
  { rp_id = name; rp_name = name; rp_codebase = None; rp_url = ""
  ; rp_local_path = path; rp_resolved_local_path = path
  ; rp_default_branch = "main"
  ; rp_status = Tui_decode.Repository_status status
  ; rp_keepers = keepers
  ; rp_auto_sync = false }

(* Three repositories whose details differ in length: a short one, one whose
   Keepers wrap, one with a failure row. The card is as tall for each. *)
let test_workspace_detail_keeps_one_height () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Repositories;
  let repos =
    [ repository "short" "/tmp/short"
    ; repository "wrapped"
        ~keepers:(List.init 8 (fun index -> Printf.sprintf "keeper-with-a-long-name-%d" index))
        "/Users/example/me/.masc/repos/a-repository-with-a-long-hyphenated-name"
    ; repository "failed" ~status:(Repo_manager_types.Error "clone failed: remote hung up")
        "/tmp/failed" ]
  in
  state.repositories <- Some { Tui_decode.rs_repositories = repos; rs_total = 3 };
  List.iter
    (fun (cols, budget) ->
      let rows cursor =
        Masc_tui_render_repositories.repository_detail_rows state ~cols ~budget ~cursor in
      let first = rows 0 in
      Alcotest.(check bool) (Printf.sprintf "%dx%d draws a card" cols budget) true (first > 0);
      List.iter (fun cursor ->
        Alcotest.(check int) (Printf.sprintf "%dx%d cursor %d" cols budget cursor) first
          (rows cursor))
        [ 1; 2 ])
    [ 80, 18; 120, 34; 200, 54; 60, 40 ]

(* The shared rule every detail beside or above a list takes its height
   from: details of three, one and five lines. *)
let details = [ 3; 1; 5 ]
let detail_of length = List.init length (fun index -> Printf.sprintf "line %d" index)

let fitted ~budget ~too_tall length =
  Masc_tui_detail_height.fit ~budget ~rows:details ~detail:detail_of ~too_tall ~blank:"-"
    (detail_of length)

let test_a_detail_keeps_the_tallest_height () =
  let cut = Masc_tui_detail_height.Cut_with "more" in
  List.iter
    (fun (budget, too_tall, expected) ->
      List.iter
        (fun selected ->
          Alcotest.(check int)
            (Printf.sprintf "budget %d, the %d-line detail selected" budget selected)
            expected (List.length (fitted ~budget ~too_tall selected)))
        details)
    [ 9, cut, 5; 5, cut, 5; 4, cut, 4; 1, cut, 1; 0, cut, 0
    ; 9, Masc_tui_detail_height.Fold, 5; 5, Masc_tui_detail_height.Fold, 5
    ; 4, Masc_tui_detail_height.Fold, 0 ];
  Alcotest.(check (list string)) "a short detail ends in blank lines"
    [ "line 0"; "-"; "-"; "-"; "-" ] (fitted ~budget:9 ~too_tall:cut 1);
  Alcotest.(check (list string)) "a cut detail ends with the overflow line"
    [ "line 0"; "line 1"; "line 2"; "more" ] (fitted ~budget:4 ~too_tall:cut 5);
  Alcotest.(check (list string)) "one row keeps the first line, not the overflow line"
    [ "line 0" ] (fitted ~budget:1 ~too_tall:cut 5);
  Alcotest.(check (list string)) "a list with nothing loaded keeps the shown detail"
    [ "only" ]
    (Masc_tui_detail_height.fit ~budget:9 ~rows:[] ~detail:detail_of ~too_tall:cut ~blank:"-"
       [ "only" ])

let () =
  Alcotest.run "tui list moves"
    [ ( "keeper list"
      , [ Alcotest.test_case "no move key unfolds a group" `Quick test_no_move_key_unfolds_a_group
        ; Alcotest.test_case "every move key walks the stops" `Quick
            test_every_move_key_walks_the_stops
        ; Alcotest.test_case "every view moves over its stops" `Quick
            test_every_view_moves_over_its_stops
        ; Alcotest.test_case "plain and empty lists" `Quick test_plain_and_empty_lists
        ] )
    ; ( "overview"
      , [ Alcotest.test_case "every move key moves the selection" `Quick
            test_overview_answers_every_move_key
        ] )
    ; ( "row lists"
      , [ Alcotest.test_case "every move key moves the cursor" `Quick
            test_row_lists_move_their_cursor
        ; Alcotest.test_case "an overlay moves its own rows" `Quick
            test_an_overlay_moves_its_own_rows
        ] )
    ; ( "detail height"
      , [ Alcotest.test_case "a detail keeps the tallest height" `Quick
            test_a_detail_keeps_the_tallest_height
        ] )
    ; ( "workspace"
      , [ Alcotest.test_case "the detail card keeps one height" `Quick
            test_workspace_detail_keeps_one_height
        ] )
    ]
