(* The move keys of the lists RFC tui-one-screen-grammar §3.1 names, as
   decisions over the TUI state: which place each key selects, that no move
   key folds or unfolds a group, and that the Workspace detail card keeps
   one height for every selection (§8). Nothing here reads drawn text. *)

open Masc_tui_types
module Model = Masc_tui_keeper_list_model
module Scroll = Masc_tui_scroll

let every_move = Scroll.[ Line_down; Line_up; Page_down; Page_up; To_top; To_end ]

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
      move_keeper_list_stop state ~page:5 move;
      Alcotest.(check bool) "the group stays folded" true
        (state.keeper_list_folded = [ group ]);
      Alcotest.(check bool) "the selection is World or the heading" true
        (match keeper_list_stop state with
         | Some (Model.Stop_world | Model.Stop_heading _) -> true
         | Some (Model.Stop_row _) | None -> false))
    every_move;
  place_keeper_list_stop state (Model.Stop_heading group);
  move_keeper_list_stop state ~page:5 Scroll.To_top;
  Alcotest.(check bool) "Home is the World row" true
    (keeper_list_stop state = Some Model.Stop_world);
  move_keeper_list_stop state ~page:5 Scroll.To_end;
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
  let from_index index move ~page =
    Option.iter (place_keeper_list_stop state) (List.nth_opt (keeper_list_stops state) index);
    move_keeper_list_stop state ~page move;
    stop_index state
  in
  List.iter
    (fun (from, move, page, expected) ->
      Alcotest.(check (option int)) (Printf.sprintf "from stop %d" from) (Some expected)
        (from_index from move ~page))
    Scroll.
      [ 0, Line_down, 2, 1; 1, Line_down, 2, 2; 0, Line_up, 2, 0; 4, Line_down, 2, 4
      ; 3, Line_up, 2, 2; 0, Page_down, 2, 2; 1, Page_down, 9, 4; 4, Page_up, 2, 2
      ; 2, Page_up, 9, 0; 3, To_top, 2, 0; 1, To_end, 2, 4 ]

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
                (fun move ->
                  place_keeper_list_stop state stop;
                  move_keeper_list_stop state ~page:2 move;
                  let label = Printf.sprintf "view %d folded %d from %d"
                      (Option.value ~default:(-1)
                         (List.find_index (( = ) view) every_view))
                      (List.length folded) from in
                  Alcotest.(check bool) (label ^ ": folds kept") true
                    (state.keeper_list_folded = folded);
                  Alcotest.(check bool) (label ^ ": lands on a stop") true
                    (Option.is_some (stop_index state));
                  match move with
                  | Scroll.To_top ->
                      Alcotest.(check (option int)) (label ^ ": Home") (Some 0) (stop_index state)
                  | Scroll.To_end ->
                      Alcotest.(check (option int)) (label ^ ": End") (Some last) (stop_index state)
                  | Scroll.Line_down | Scroll.Line_up | Scroll.Page_down | Scroll.Page_up -> ())
                every_move)
            stops)
        [ all_groups; [] ])
    every_view

(* A plain list has only rows, and an empty one has nothing to move. *)
let test_plain_and_empty_lists () =
  let state = keeper_list ~view:Model.Plain [ "alpha"; "beta" ] in
  Alcotest.(check int) "one stop per row" 2 (List.length (keeper_list_stops state));
  move_keeper_list_stop state ~page:2 Scroll.To_end;
  Alcotest.(check (option int)) "End is the last row" (Some 1) (stop_index state);
  move_keeper_list_stop state ~page:2 Scroll.To_top;
  Alcotest.(check (option int)) "Home is the first row" (Some 0) (stop_index state);
  let empty = keeper_list ~view:Model.Plain [] in
  List.iter (fun move ->
    move_keeper_list_stop empty ~page:2 move;
    Alcotest.(check int) "an empty list keeps its cursor" 0 empty.keeper_cursor)
    every_move;
  let world = keeper_list ~view:Model.By_memory [] in
  List.iter (fun move ->
    move_keeper_list_stop world ~page:2 move;
    Alcotest.(check bool) "an empty World view stays on World" true
      (keeper_list_stop world = Some Model.Stop_world))
    every_move

(* Overview's destinations, in the order the list draws them. *)
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

(* PgDn, PgUp, Home and End did nothing here: only j and k had a handler. *)
let test_overview_answers_every_move_key () =
  let state = overview_with_goals 4 in
  let count = List.length (destinations state) in
  Alcotest.(check bool) "the list has more than a page of two" true (count > 4);
  let last = count - 1 in
  let from_index index move ~page =
    state.home_selected <- List.nth_opt (destinations state) index;
    Masc_tui_home.home_move state ~page move;
    home_index state
  in
  List.iter
    (fun (from, move, page, expected) ->
      Alcotest.(check (option int)) (Printf.sprintf "from destination %d" from) (Some expected)
        (from_index from move ~page))
    Scroll.
      [ 0, Line_down, 2, 1; 0, Line_up, 2, 0; 0, Page_down, 2, 2; 3, Page_up, 2, 1
      ; 1, Page_up, 9, 0; 1, Page_down, 99, last; 2, To_top, 2, 0; 0, To_end, 2, last
      ; last, Line_down, 2, last ];
  (* A selection the list no longer holds starts again at an edge. *)
  state.home_selected <- Some (Home_request (Home_goal_confirmation "gone"));
  Masc_tui_home.home_move state ~page:2 Scroll.Line_down;
  Alcotest.(check (option int)) "a lost selection steps to the first row" (Some 0)
    (home_index state);
  state.home_selected <- Some (Home_request (Home_goal_confirmation "gone"));
  Masc_tui_home.home_move state ~page:2 Scroll.To_end;
  Alcotest.(check (option int)) "a lost selection's End is the last row" (Some last)
    (home_index state)

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
    ; ( "workspace"
      , [ Alcotest.test_case "the detail card keeps one height" `Quick
            test_workspace_detail_keeps_one_height
        ] )
    ]
