(* The move keys of the lists RFC tui-one-screen-grammar §3.1 names, as
   decisions over the TUI state: which list a move key walks on the surface
   on screen, which place each key selects, that no move key folds or
   unfolds a group, that the Tools lists move their selection rather than
   scroll the page, and that a detail beside or above a list keeps one
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

(* A list the last frame drew [height] rows tall, as the frame reports it and
   the dispatcher hands it over. The tag is one list for every surface here:
   which list a surface names is the dispatcher's arm, not the move. *)
let drawn state ~height rows () =
  state.lists_drawn <- [ { dl_list = Board_post_rows; dl_height = height } ];
  Some { Moves.os_list = Board_post_rows; os_rows = rows }

(* The rows the dispatcher hands over on the Keeper list: every Keeper,
   placed by choosing it, which opens its group (what a search does). The
   move keys must not use them; if they did, Home would open the first
   group again. *)
let keeper_rows state =
  Some
    { Moves.rl_count = List.length state.keepers
    ; rl_cursor = state.keeper_cursor
    ; rl_place = choose_keeper_row state }

(* Overview has no row cursor, and a Tools reading or an empty Tools list is
   not a list the keys walk, so the dispatcher hands over no list. *)
let nothing_on_screen () = None

(* Only the Tools lists ask the frame to follow their selection; anywhere
   else a call means a surface walked the wrong list. *)
let no_follow _ = Alcotest.fail "only a Tools list asks to follow its selection"

let press ?(follow = no_follow) ~on_screen state key =
  match Moves.moves state ~on_screen ~follow with
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
  press ~on_screen:(drawn state ~height (keeper_rows state)) state key

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
  let press_home ~height key = press ~on_screen:(drawn state ~height None) state key in
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
  press ~on_screen:(drawn state ~height rows) state key;
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
    ; System_logs; Board; Fusion; Schedules; Planning; Lanes; Code; Resources; Config; Acting ]

(* QA N01: Keeper > Memory drew three rows at 80x24 and PgDn moved thirteen,
   so nine Keepers never reached the screen. A page is the list's drawn
   height less one (RFC §3.1): from any cursor in any window, after PgDn the
   row that was last on screen is still on it, and after PgUp the row that
   was first. The window follows the landing the way the dispatcher's lists
   with a scroll follow it. *)
let test_a_page_keeps_the_row_read_last () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Memory;
  List.iter
    (fun (count, height) ->
      for cursor = 0 to count - 1 do
        for scroll = max 0 (cursor - height + 1) to min cursor (max 0 (count - height)) do
          List.iter
            (fun (key, kept, name) ->
              let window = ref scroll in
              let rows =
                Some
                  { Moves.rl_count = count
                  ; rl_cursor = cursor
                  ; rl_place =
                      (fun index ->
                        window := Masc_tui_scroll.ensure_visible ~cursor:index ~height scroll) }
              in
              press ~on_screen:(drawn state ~height rows) state key;
              Alcotest.(check bool)
                (Printf.sprintf "%d rows drawn %d tall, cursor %d, window %d: %s keeps row %d"
                   count height cursor scroll name kept)
                true
                (kept >= !window && kept < !window + height))
            [ Key.Page_down, min (count - 1) (scroll + height - 1), "PgDn"
            ; Key.Page_up, scroll, "PgUp" ]
        done
      done)
    [ 34, 3; 34, 13; 34, 2; 5, 8 ]

(* The height a page moves by is the one the last frame reported for the
   list the key walks. A frame that drew another list, or none, leaves no
   page to move by, and the key moves one row: it cannot pass a row nobody
   saw. *)
let test_a_page_is_the_height_the_frame_reported () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Board;
  let landing ~reported ~page key =
    state.lists_drawn <- reported;
    let placed = ref None in
    let rows =
      Some { Moves.rl_count = 40; rl_cursor = 10; rl_place = (fun index -> placed := Some index) }
    in
    press ~on_screen:(fun () -> Some { Moves.os_list = page; os_rows = rows }) state key;
    !placed
  in
  List.iter
    (fun (name, reported, page, key, expected) ->
      Alcotest.(check (option int)) name (Some expected) (landing ~reported ~page key))
    [ ( "PgDn moves the reported height less one", [ { dl_list = Board_post_rows; dl_height = 7 } ]
      , Board_post_rows, Key.Page_down, 16 )
    ; ( "PgUp moves the reported height less one", [ { dl_list = Board_post_rows; dl_height = 7 } ]
      , Board_post_rows, Key.Page_up, 4 )
    ; ( "the height of the list the key walks, not another one drawn beside it"
      , [ { dl_list = Approval_items; dl_height = 20 }; { dl_list = Board_post_rows; dl_height = 4 } ]
      , Board_post_rows, Key.Page_down, 13 )
    ; ( "a list the frame did not draw pages by one row"
      , [ { dl_list = Approval_items; dl_height = 20 } ], Board_post_rows, Key.Page_down, 11 )
    ; ( "no list drawn at all pages by one row", [], Board_post_rows, Key.Page_up, 9 )
    ; ( "a line key is a line whatever was drawn", [], Board_post_rows, Key.Line_down, 11 )
    ; ( "End is the last row whatever was drawn", [], Board_post_rows, Key.To_end, 39 ) ]

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
       [ "only" ]);
  (* A single unusually tall outlier row is bounded by [default_max_rows] so
     shorter selections never carry dozens of blank rows (RFC §8). *)
  let with_outlier = [ 2; 30; 3 ] in
  List.iter
    (fun selected ->
      Alcotest.(check int)
        (Printf.sprintf "outlier capped to default_max_rows when %d-line detail selected" selected)
        Masc_tui_detail_height.default_max_rows
        (List.length
           (Masc_tui_detail_height.fit ~budget:25 ~rows:with_outlier ~detail:detail_of
              ~too_tall:cut ~blank:"-" (detail_of selected))))
    with_outlier;
  Alcotest.(check int) "Fold without explicit cap respects full budget above default_max_rows" 15
    (List.length
       (Masc_tui_detail_height.fit ~budget:20 ~rows:[ 2; 15 ] ~detail:detail_of
          ~too_tall:Masc_tui_detail_height.Fold ~blank:"-" (detail_of 2)))

(* The Tools surface: the Available pane's Skill list and the async request
   list. The QA sweep's case (F06): j and k scrolled the whole page a row
   while the selected Skill stayed put, and only J and K moved it, which a
   Hangul keyboard cannot send. *)
module Tools = Masc.Tui_decode_tools

let skill name : Tools.effective_skill_profile =
  let reference =
    match
      Skill_reference.of_yojson
        (`Assoc
           [ ( "identity"
             , `Assoc
                 [ "source_id", `String "workspace"; "package_id", `String name
                 ; "name", `String name ] )
           ; "content_revision", `String (String.make 64 'a') ])
    with
    | Ok reference -> reference
    | Error _ -> Alcotest.failf "the reference of %s does not decode" name
  in
  { esp_reference = reference; esp_name = name
  ; esp_surface = Masc.Keeper_skill_observability.Instruction_skill
  ; esp_body_bytes = 0; esp_discovery_bytes = 0
  ; esp_load_reasons = []; esp_node_count = 0; esp_batch_count = 0
  ; esp_max_parallelism = 0; esp_flow = None; esp_io = Model_orchestrated }

let tools_surface count =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Tools;
  state.tools_pane <- Tools_surface;
  let inventory : Tools.tool_snapshot =
    { ts_tools = []; ts_count = 0; ts_freshness = Settled
    ; ts_effective =
        Some
          (Effective_surface_available
             { ets_keeper_name = "keeper"; ets_runtime_id = "runtime"
             ; ets_official_client_kind = "client"
             ; ets_tool_delivery = Effective_tools_delivered; ets_native_posture = None
             ; ets_skill_snapshot_revision = "snapshot"
             ; ets_skill_resource_read_max_bytes = None; ets_skills_left_out = []
             ; ets_unavailable_skill_names = []
             ; ets_skill_profiles = List.init count (fun index -> skill (Printf.sprintf "skill-%d" index))
             ; ets_tool_surface_bytes = None; ets_skill_tool_surface_bytes = None
             ; ets_skill_discovery_bytes = 0; ets_skill_body_bytes = None; ets_tools = []
             ; ets_tool_surface_sha256 = None })
    ; ts_usage = None; ts_volume_gc_report = None
    ; ts_storage = { st_host_disk = Host_disk_absent; st_keeper_cleanup = Keeper_cleanup_absent } }
  in
  state.tools_inventory <- Some inventory;
  state

(* A Tools list the last frame drew [entries] whole entries tall, as the
   frame reports it. A Tools list reads its page there and not from the list
   the dispatcher hands over, which is none. *)
let tools_drawn state list ~entries =
  state.lists_drawn <- [ { dl_list = list; dl_height = entries } ]

(* A press that records which list asked to follow, on a list the frame drew
   four entries tall, so a page moves three entries. *)
let press_tools ~list state move =
  let followed = ref [] in
  tools_drawn state list ~entries:4;
  press ~on_screen:nothing_on_screen ~follow:(fun list -> followed := list :: !followed) state
    move;
  !followed

let test_tools_skill_list_walks_the_selection () =
  let state = tools_surface 5 in
  state.tools_scroll <- 7;
  Alcotest.(check bool) "the Skill list answers the move keys" true
    (Moves.tools_list state = Some Moves.Tools_skills);
  let followed = press_tools ~list:Skill_entries state Key.Line_down in
  Alcotest.(check int) "j selects the next Skill" 1 state.tools_skill_cursor;
  Alcotest.(check int) "j does not scroll the page by itself" 7 state.tools_scroll;
  Alcotest.(check bool) "the frame is asked to follow the Skill list" true
    (followed = [ Moves.Tools_skills ]);
  List.iter
    (fun (from, move, expected) ->
      state.tools_skill_cursor <- from;
      ignore (press_tools ~list:Skill_entries state move);
      Alcotest.(check int) (Printf.sprintf "from Skill %d" from) expected state.tools_skill_cursor)
    Key.
      [ 0, Line_up, 0; 4, Line_down, 4; 1, Line_up, 0; 0, To_end, 4; 3, To_top, 0
      ; 0, Page_down, 3; 3, Page_down, 4; 4, Page_up, 1; 1, Page_up, 0 ];
  (* With no Skill there is nothing to walk, and the page under the empty
     list still has its tool table to scroll. *)
  Alcotest.(check bool) "an empty Skill list leaves the keys to the page" true
    (Option.is_none (Moves.moves (tools_surface 0) ~on_screen:nothing_on_screen ~follow:no_follow))

(* Enter on Available turns the keys from the Skill list to the page under
   it. The tool table and the evidence are drawn below the Skills, and while
   the keys only walked the list, nothing past the last Skill was reachable. *)
let test_tools_enter_reads_the_page_and_esc_returns () =
  let state = tools_surface 5 in
  state.tools_skill_cursor <- 2;
  Moves.read_skill_page state;
  Alcotest.(check bool) "after Enter the move keys scroll the page" true
    (Option.is_none (Moves.moves state ~on_screen:nothing_on_screen ~follow:no_follow));
  Alcotest.(check int) "reading the page keeps the selected Skill" 2 state.tools_skill_cursor;
  Moves.read_skill_page state;
  Alcotest.(check bool) "Enter while reading stays on the page" true
    (Option.is_none (Moves.tools_list state));
  Alcotest.(check bool) "Esc is spent giving the keys back to the list" true
    (Moves.choose_skill_again state);
  ignore (press_tools ~list:Skill_entries state Key.Line_down);
  Alcotest.(check int) "j walks on from the Skill that was read" 3 state.tools_skill_cursor;
  Alcotest.(check bool) "the next Esc goes further out" false (Moves.choose_skill_again state);
  (* Leaving the pane ends the reading: Available comes back on its list. *)
  Moves.read_skill_page state;
  Moves.show_tools_pane state Tools_async;
  Moves.show_tools_pane state Tools_surface;
  Alcotest.(check bool) "switching pane gives the keys back to the list" true
    (Moves.tools_list state = Some Moves.Tools_skills);
  (* No Skill, nothing to read; other panes keep their own Enter and Esc. *)
  let empty = tools_surface 0 in
  Moves.read_skill_page empty;
  Alcotest.(check bool) "Enter with no Skill reads no page" false (Moves.choose_skill_again empty);
  state.tools_pane <- Tools_usage;
  Moves.read_skill_page state;
  state.tools_pane <- Tools_surface;
  Alcotest.(check bool) "Enter on another pane reads no Skill page" true
    (Moves.tools_list state = Some Moves.Tools_skills)

let request id : Tui_decode.async_request_row =
  { ar_request_id = id; ar_submitted_by = "operator"; ar_keeper_name = "keeper"
  ; ar_phase = Async_running; ar_submitted_at = 0.; ar_ownership = Async_runtime_owned }

let target id : Masc.Tui_decode_async_request.target =
  { submitted_by = "operator"; request_id = id; keeper_name = "keeper" }

let tools_async ids =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Tools;
  state.tools_pane <- Tools_async;
  state.tools_async_observation <-
    Some
      (Async_ready
         { summary =
             { ars_active = List.length ids; ars_runtime_owned = List.length ids
             ; ars_ownership_unknown = 0; ars_record_errors = 0 }
         ; requests = List.map request ids; recovery = None });
  state

let selected_request state =
  Option.map (fun (selected : Masc.Tui_decode_async_request.target) -> selected.request_id)
    state.tools_async_selection

let test_tools_async_list_walks_the_selection () =
  let state = tools_async [ "a"; "b"; "c" ] in
  Alcotest.(check bool) "the request list answers the move keys" true
    (Moves.tools_list state = Some Moves.Tools_async_requests);
  List.iter
    (fun (from, move, expected) ->
      state.tools_async_selection <- Some (target from);
      let followed = press_tools ~list:Async_request_entries state move in
      Alcotest.(check (option string)) (Printf.sprintf "from request %s" from) (Some expected)
        (selected_request state);
      Alcotest.(check bool) "the frame is asked to follow the request list" true
        (followed = [ Moves.Tools_async_requests ]))
    Key.
      [ "a", Line_down, "b"; "c", Line_down, "c"; "a", Line_up, "a"; "a", To_end, "c"
      ; "c", To_top, "a"; "a", Page_down, "c" ];
  (* A selection the list no longer holds starts again at an edge. *)
  state.tools_async_selection <- Some (target "gone");
  ignore (press_tools ~list:Async_request_entries state Key.Line_down);
  Alcotest.(check (option string)) "a lost selection steps to the first request" (Some "a")
    (selected_request state);
  state.tools_async_selection <- Some (target "gone");
  ignore (press_tools ~list:Async_request_entries state Key.To_end);
  Alcotest.(check (option string)) "a lost selection's End is the last request" (Some "c")
    (selected_request state);
  Alcotest.(check bool) "an empty request list leaves the keys to the page" true
    (Option.is_none (Moves.moves (tools_async []) ~on_screen:nothing_on_screen ~follow:no_follow));
  (* An open request is a reading: its keys scroll it, as they did. *)
  state.tools_async_detail_open <- true;
  Alcotest.(check bool) "an open request answers no list move" true
    (Option.is_none (Moves.moves state ~on_screen:nothing_on_screen ~follow:no_follow))

(* A Tools list pages by the entries the frame reported for that list, and
   for no other: a report for the request list leaves the Skill list no
   page, so its PgDn moves one Skill, and the other way round. *)
let test_tools_page_is_the_height_reported_for_that_list () =
  let skills = tools_surface 10 in
  List.iter
    (fun (reported, entries, expected) ->
      skills.tools_skill_cursor <- 0;
      tools_drawn skills reported ~entries;
      press ~on_screen:nothing_on_screen ~follow:ignore skills Key.Page_down;
      Alcotest.(check int)
        (Printf.sprintf "%d entries reported for %s" entries
           (if reported = Skill_entries then "the Skills" else "the requests"))
        expected skills.tools_skill_cursor)
    [ Skill_entries, 4, 3; Skill_entries, 7, 6; Async_request_entries, 7, 1 ];
  let requests = tools_async (List.init 10 (Printf.sprintf "r%d")) in
  List.iter
    (fun (reported, entries, expected) ->
      requests.tools_async_selection <- Some (target "r0");
      tools_drawn requests reported ~entries;
      press ~on_screen:nothing_on_screen ~follow:ignore requests Key.Page_down;
      Alcotest.(check (option string))
        (Printf.sprintf "%d entries reported for %s" entries
           (if reported = Async_request_entries then "the requests" else "the Skills"))
        (Some expected) (selected_request requests))
    [ Async_request_entries, 4, "r3"; Skill_entries, 7, "r1" ]

(* The other panes have no selection on screen and stay readings. *)
let test_tools_readings_answer_no_list_move () =
  let state = tools_surface 3 in
  List.iter
    (fun pane ->
      state.tools_pane <- pane;
      Alcotest.(check bool) "a reading pane answers no list move" true
        (Option.is_none (Moves.moves state ~on_screen:nothing_on_screen ~follow:no_follow)))
    [ Tools_usage; Tools_storage; Tools_catalog Tools_catalog_list
    ; Tools_catalog (Tools_catalog_volumes { catalog_scroll = 0 }) ];
  (* The source picker walks its own list while it is open. *)
  state.tools_pane <- Tools_surface;
  state.tools_skill_source_picker <-
    Some
      { ssp_sources = [ "workspace" ]; ssp_composition = false
      ; ssp_list = Masc_tui_pick_list.closed; ssp_authority = state.workspace_authority
      ; ssp_identity = None; ssp_port = 0 };
  Alcotest.(check bool) "the source picker keeps the move keys" true
    (Option.is_none (Moves.moves state ~on_screen:nothing_on_screen ~follow:no_follow))

(* The footer's j/k and Esc words come from [tools_keys], which reads the
   state the keys read. A footer that said "move" on a reading or "features"
   on a Skill's page named a key the dispatcher does not run there. *)
let test_tools_keys_say_what_the_keys_do () =
  let module Keys = Masc_tui_keys in
  let keys =
    Alcotest.testable
      (fun ppf (value : Keys.tools_keys) ->
        Format.pp_print_string ppf
          (match value with
           | Keys.Tools_walks_list -> "walks the list"
           | Keys.Tools_reads_skill_page -> "reads the Skill's page"
           | Keys.Tools_reads_request -> "reads the open request"
           | Keys.Tools_reads_original_task -> "reads the original Task"
           | Keys.Tools_reads_page -> "reads the page"))
      ( = )
  in
  let state = tools_surface 3 in
  Alcotest.check keys "the Skill list" Keys.Tools_walks_list (Moves.tools_keys state);
  Moves.read_skill_page state;
  Alcotest.check keys "after Enter, the Skill's page" Keys.Tools_reads_skill_page
    (Moves.tools_keys state);
  ignore (Moves.choose_skill_again state);
  Alcotest.check keys "after Esc, the list again" Keys.Tools_walks_list (Moves.tools_keys state);
  Alcotest.check keys "an empty Skill list scrolls" Keys.Tools_reads_page
    (Moves.tools_keys (tools_surface 0));
  List.iter
    (fun pane ->
      state.tools_pane <- pane;
      Alcotest.check keys "a pane with no list scrolls" Keys.Tools_reads_page (Moves.tools_keys state))
    [ Tools_usage; Tools_storage; Tools_catalog Tools_catalog_list ];
  let async = tools_async [ "a"; "b" ] in
  Alcotest.check keys "the request list" Keys.Tools_walks_list (Moves.tools_keys async);
  (* Esc steps out one layer at a time -- original Task, request, list -- and
     the footer names the layer Esc goes to. *)
  async.tools_async_detail_open <- true;
  Alcotest.check keys "an open request scrolls and Esc returns to the list"
    Keys.Tools_reads_request (Moves.tools_keys async);
  let target : Masc.Tui_decode_async_request.target =
    { submitted_by = "operator"; request_id = "a"; keeper_name = "keeper" }
  in
  let source : tools_async_task_source =
    { ats_request = { target; request_context = `Assoc [ "composition_run_id", `String "run-1" ] }
    ; ats_run_id = "run-1"; ats_task_id = "task-1"; ats_observed_at = 1.; ats_retained = false }
  in
  async.tools_async_task_source <- Some source;
  Alcotest.check keys "the original Task scrolls and Esc returns to the request"
    Keys.Tools_reads_original_task (Moves.tools_keys async);
  async.tools_async_task_source <- None;
  Alcotest.check keys "closing the Task leaves the request open" Keys.Tools_reads_request
    (Moves.tools_keys async);
  async.tools_async_detail_open <- false;
  Alcotest.check keys "closing the request gives the keys back to the list" Keys.Tools_walks_list
    (Moves.tools_keys async)

(* The frame finds the selection where it is drawn now, so the follow runs
   after the key moved it. A follow that ran first would hold the window on
   the row the key left, and j on the window's last row would walk the
   selection off screen. *)
let test_tools_follow_sees_where_the_key_landed () =
  let state = tools_surface 5 in
  tools_drawn state Skill_entries ~entries:3;
  let seen = ref [] in
  let note_skill _ = seen := state.tools_skill_cursor :: !seen in
  press ~on_screen:nothing_on_screen ~follow:note_skill state Key.Line_down;
  press ~on_screen:nothing_on_screen ~follow:note_skill state Key.To_end;
  press ~on_screen:nothing_on_screen ~follow:note_skill state Key.Page_up;
  Alcotest.(check (list int)) "each follow sees the Skill its key selected" [ 2; 4; 1 ]
    !seen;
  let state = tools_async [ "a"; "b"; "c" ] in
  state.tools_async_selection <- Some (target "a");
  let seen = ref [] in
  let note_request _ = seen := selected_request state :: !seen in
  tools_drawn state Async_request_entries ~entries:3;
  press ~on_screen:nothing_on_screen ~follow:note_request state Key.Line_down;
  press ~on_screen:nothing_on_screen ~follow:note_request state Key.To_end;
  Alcotest.(check (list (option string))) "each follow sees the request its key selected"
    [ Some "c"; Some "b" ] !seen

let test_queue_panel_page_snaps_and_clears () =
  let prose text : Masc_tui_queue_inspection.item = { id = None; text } in
  let local id : Masc_tui_queue_inspection.item =
    { id = Some (Masc_tui_queue_inspection.Local_message id); text = id }
  in
  let server id : Masc_tui_queue_inspection.item =
    { id = Some (Masc_tui_queue_inspection.Server_message id); text = id }
  in
  (* Rows 0-3: prose, prose, local "a", server "b" (selecting server adds 1 fixed note row).
     Rows 4-7: four prose rows (prose-only middle window).
     Rows 8-9: local "c", local "d". *)
  let items =
    [ prose "h0"; prose "h1"; local "a"; server "b"
    ; prose "p4"; prose "p5"; prose "p6"; prose "p7"
    ; local "c"; local "d"
    ]
  in
  let panel : Masc_tui_types.queue_panel =
    { qp_keeper = "echo"
    ; qp_layout = Masc_tui_queue_layout.Adaptive
    ; qp_reading = Masc_tui_types.Queue_current
    ; qp_observation = None
    ; qp_notice = None
    ; qp_receipt = None
    ; qp_selected = Some (Masc_tui_queue_inspection.Local_message "a")
    ; qp_scroll = 0
    ; qp_detail = None
    ; qp_detail_scroll = 0
    ; qp_refresh_after_priority = false
    }
  in
  (* Budget 5 -> fixed=1 (no note) -> height=4 (rows 0..3).
     Page_down steps by page_step(4)=3 -> scroll=3 (rows 3..6), where row 3 is server "b". *)
  let p1 =
    Masc_tui_types.queue_panel_page ~items ~budget_for:(fun _ -> 5)
      ~move:Masc_tui_scroll.Page_down panel
  in
  Alcotest.(check int) "page down lands at scroll 3" 3 p1.qp_scroll;
  Alcotest.(check bool) "snaps to server b in new window" true
    (p1.qp_selected = Some (Masc_tui_queue_inspection.Server_message "b"));
  (* With server "b" selected, fixed=2 -> height=3. Next Page_down steps by 2 -> scroll=5 (rows 5..7),
     which is prose-only -> selection clears to None so Enter cannot act off-screen. *)
  let p2 =
    Masc_tui_types.queue_panel_page ~items ~budget_for:(fun _ -> 5)
      ~move:Masc_tui_scroll.Page_down p1
  in
  Alcotest.(check bool) "prose-only window clears selection" true (p2.qp_selected = None);
  Alcotest.(check int) "prose-only scroll stays at 5" 5 p2.qp_scroll;
  (* To_end jumps to bottom (rows 6..9) and selects last visible target local "d". *)
  let p3 =
    Masc_tui_types.queue_panel_page ~items ~budget_for:(fun _ -> 5)
      ~move:Masc_tui_scroll.To_end p2
  in
  Alcotest.(check bool) "To_end snaps to last target" true
    (p3.qp_selected = Some (Masc_tui_queue_inspection.Local_message "d"));
  (* To_top with budget 4 (height 3 -> rows 0..2 when no note, or 0..1 if a server note appears):
     even if row 2 were a server item, To_top keeps scroll=0 so top prose stays reachable. *)
  let top_note_items = [ prose "h0"; prose "h1"; server "s2"; prose "p3"; local "e4" ] in
  let p4 =
    Masc_tui_types.queue_panel_page ~items:top_note_items ~budget_for:(fun _ -> 4)
      ~move:Masc_tui_scroll.To_top { panel with qp_selected = None; qp_scroll = 2 }
  in
  Alcotest.(check int) "To_top stays anchored at row 0 despite note shrink" 0 p4.qp_scroll;
  Alcotest.(check bool) "To_top clears selection when shrunk window hides s2" true
    (p4.qp_selected = None);
  (* To_end onto a trailing Server_message adds 1 fixed note row (height 4 -> 3);
     re-anchoring to maximum ~height:3 keeps the last row s5 visible and selected. *)
  let trailing_server = [ local "a0"; prose "p1"; prose "p2"; server "s3"; prose "p4"; server "s5" ] in
  let p5 =
    Masc_tui_types.queue_panel_page ~items:trailing_server ~budget_for:(fun _ -> 5)
      ~move:Masc_tui_scroll.To_end panel
  in
  Alcotest.(check int) "To_end re-anchors scroll to bottom after note shrink" 3 p5.qp_scroll;
  Alcotest.(check bool) "To_end keeps trailing server s5 selected" true
    (p5.qp_selected = Some (Masc_tui_queue_inspection.Server_message "s5"));
  (* To_end with trailing prose after a Server_message reaches the trailing prose on the first press. *)
  let trailing_prose =
    [ local "a0"; prose "p1"; prose "p2"; local "a3"; prose "p4"; server "s5"; prose "p6" ]
  in
  let p6 =
    Masc_tui_types.queue_panel_page ~items:trailing_prose ~budget_for:(fun _ -> 5)
      ~move:Masc_tui_scroll.To_end panel
  in
  Alcotest.(check int) "To_end reaches trailing prose on first press" 4 p6.qp_scroll;
  Alcotest.(check bool) "To_end selects s5 inside final bottom window" true
    (p6.qp_selected = Some (Masc_tui_queue_inspection.Server_message "s5"))

let test_chat_home_and_overflow_guard () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Masc_tui_types.Keepers Masc_tui_types.Keeper_message;
  state.msg_older_exist <- true;
  state.msg_older_cursor <- Some "cur-1";
  let loaded = ref [] in
  let send key =
    Masc_tui_chat_input.Message_keymap.handle_message_key
      ~terminal_size:(fun () -> (30, 100))
      ~wheel_notch_rows:3 state
      ~submit_message:(fun _ -> ())
      ~load_older:(fun ~cursor -> loaded := cursor :: !loaded)
      ~paste_image:(fun () -> ())
      ~open_named_image:(fun () -> ())
      ~inspect_context:(fun () -> ())
      ~inspect_queue:(fun () -> ())
      ~load_tool_changes:(fun () -> ())
      ~load_preparation:(fun () -> ())
      ~drain_queue:(fun () -> ())
      ~start_voice:(fun () -> ())
      ~toggle_voice_continuous:(fun () -> ())
      key
  in
  Alcotest.(check bool) "Home handled in chat" true (send "home");
  Alcotest.(check int) "Home jumps to clamped_scroll_end"
    Masc_tui_types.clamped_scroll_end state.msg_scroll;
  Alcotest.(check bool) "Home records Chat_scroll_from_oldest 0" true
    (state.msg_scroll_anchor = Masc_tui_types.Chat_scroll_from_oldest 0);
  Alcotest.(check (list (option string))) "Home requests older page"
    [ Some "cur-1" ] !loaded;
  (* PgUp immediately after Home stays anchored at oldest offset 0 without wrapping. *)
  Alcotest.(check bool) "PgUp after Home handled" true (send "pageup");
  Alcotest.(check bool) "PgUp after Home stays at Chat_scroll_from_oldest 0" true
    (state.msg_scroll_anchor = Masc_tui_types.Chat_scroll_from_oldest 0);
  (* Down / wheel-down / PgDn immediately after Home before repaint records exact
     downward offset from oldest instead of subtracting from max_int. *)
  Alcotest.(check bool) "down after Home handled" true (send "down");
  Alcotest.(check bool) "down after Home steps oldest offset to 1" true
    (state.msg_scroll_anchor = Masc_tui_types.Chat_scroll_from_oldest 1);
  Alcotest.(check bool) "wheel-down after Home handled" true (send "wheel-down");
  Alcotest.(check bool) "wheel-down after Home steps oldest offset to 4" true
    (state.msg_scroll_anchor = Masc_tui_types.Chat_scroll_from_oldest 4);
  Alcotest.(check bool) "End jumps back to live bottom" true (send "end");
  Alcotest.(check int) "End sets msg_scroll to 0" 0 state.msg_scroll;
  Alcotest.(check bool) "End resets anchor to Chat_scroll_from_bottom" true
    (state.msg_scroll_anchor = Masc_tui_types.Chat_scroll_from_bottom);
  (* Outside Keeper_message (e.g. composer row on Overview), Home must not mutate msg_scroll. *)
  state.view <- Masc_tui_types.Overview;
  state.msg_scroll <- 4;
  ignore (send "home");
  Alcotest.(check int) "Home outside chat leaves msg_scroll unchanged" 4 state.msg_scroll;
  Alcotest.(check bool) "Home outside chat leaves anchor unchanged" true
    (state.msg_scroll_anchor = Masc_tui_types.Chat_scroll_from_bottom)

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
        ; Alcotest.test_case "a page keeps the row read last" `Quick
            test_a_page_keeps_the_row_read_last
        ; Alcotest.test_case "a page is the height the frame reported" `Quick
            test_a_page_is_the_height_the_frame_reported
        ] )
    ; ( "tools"
      , [ Alcotest.test_case "the Skill list walks the selection" `Quick
            test_tools_skill_list_walks_the_selection
        ; Alcotest.test_case "Enter reads the page and Esc returns" `Quick
            test_tools_enter_reads_the_page_and_esc_returns
        ; Alcotest.test_case "the async request list walks the selection" `Quick
            test_tools_async_list_walks_the_selection
        ; Alcotest.test_case "a Tools page is the height reported for that list" `Quick
            test_tools_page_is_the_height_reported_for_that_list
        ; Alcotest.test_case "the readings answer no list move" `Quick
            test_tools_readings_answer_no_list_move
        ; Alcotest.test_case "the follow sees where the key landed" `Quick
            test_tools_follow_sees_where_the_key_landed
        ; Alcotest.test_case "the footer's keys say what the keys do" `Quick
            test_tools_keys_say_what_the_keys_do
        ] )
    ; ( "detail height"
      , [ Alcotest.test_case "a detail keeps the tallest height" `Quick
            test_a_detail_keeps_the_tallest_height
        ] )
    ; ( "workspace"
      , [ Alcotest.test_case "the detail card keeps one height" `Quick
            test_workspace_detail_keeps_one_height
        ] )
    ; ( "mixed modals and chat home"
      , [ Alcotest.test_case "queue panel paging snaps and clears selection" `Quick
            test_queue_panel_page_snaps_and_clears
        ; Alcotest.test_case "chat Home jumps to oldest and guards overflow" `Quick
            test_chat_home_and_overflow_guard
        ] )
    ]
