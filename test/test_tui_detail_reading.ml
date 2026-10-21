open Alcotest
open Masc_tui_types
module Reading = Masc_tui_detail_reading

let state () =
  create_state ~workspace:"detail-reading-test" ~port:8935 ~refresh_interval:2. ()

let reading () = Reading.create ~title:"selected object" []

let test_selection_does_not_retarget_capture () =
  let state = state () in
  state.view <- Repositories;
  let captured = reading () in
  open_detail_reading state captured;
  state.repositories_cursor <- 7;
  check bool "capture owns keys" true (modal_owns_keys state);
  check bool "selection cannot replace captured source" true
    (match current_detail_reading state with Some held -> held == captured | None -> false);
  close_key_modals state;
  check bool "closed reader releases keys" false (modal_owns_keys state);
  check int "closing keeps underlying selection" 7 state.repositories_cursor

let test_workspace_revoke_cannot_resurrect_capture () =
  let state = state () in
  let old_authority = state.workspace_authority in
  open_detail_reading state (reading ());
  state.workspace_authority <- Workspace_authority 1;
  check bool "new workspace cannot read old capture" true
    (Option.is_none (current_detail_reading state));
  reconcile_detail_reading state;
  state.workspace_authority <- old_authority;
  check bool "returning does not reopen revoked capture" true
    (Option.is_none (current_detail_reading state))

let test_surface_change_releases_capture () =
  let state = state () in
  state.view <- Repositories;
  open_detail_reading state (reading ());
  state.view <- Config;
  reconcile_detail_reading state;
  state.view <- Repositories;
  check bool "capture cannot reopen on a later visit" true
    (Option.is_none (current_detail_reading state));
  check bool "hidden capture cannot own keys" false (modal_owns_keys state)

let test_navigation_normalizes_before_moving () =
  let held = Reading.move ~count:100 ~height:10 Reading.Last (reading ()) in
  let shrunk = Reading.move ~count:20 ~height:10 (Reading.By (-1)) held in
  check int "move from current bounds after resize" 9 (Reading.scroll ~count:20 ~height:10 shrunk);
  let last = Reading.move ~count:100 ~height:10 (Reading.By max_int) held in
  check int "large positive movement is bounded" 90 (Reading.scroll ~count:100 ~height:10 last);
  let first = Reading.move ~count:100 ~height:10 (Reading.By min_int) last in
  check int "large negative movement is bounded" 0 (Reading.scroll ~count:100 ~height:10 first)

let test_end_intent_survives_repreparation () =
  let held = Reading.move ~count:100 ~height:10 Reading.Last (reading ()) in
  check int "end stays selected when reflow expands the extent" 190
    (Reading.scroll ~count:200 ~height:10 held);
  (* Reflow can temporarily project one preparation notice. It must not
     replace the operator's last-edge intent with that notice's offset. *)
  let held = Reading.move ~count:1 ~height:10 Reading.Last held in
  let replaced = Reading.replace ~title:"same captured observation" [] held in
  check int "end follows the changed observation extent" 190
    (Reading.scroll ~count:200 ~height:10 replaced);
  let shorter = Reading.scroll ~count:20 ~height:10 replaced in
  check int "end also follows a shorter extent" 10 shorter;
  let moved = Reading.move ~count:200 ~height:10 (Reading.By (-1)) replaced in
  check int "relative navigation releases the end anchor" 189
    (Reading.scroll ~count:300 ~height:10 moved);
  let first = Reading.move ~count:300 ~height:10 Reading.First replaced in
  check int "first releases the end anchor" 0
    (Reading.scroll ~count:400 ~height:10 first);
  check int "a new capture does not inherit another capture's anchor" 0
    (Reading.scroll ~count:200 ~height:10 (reading ()))

let () = run "detail reading ownership"
  [ "capture", [test_case "selection stays read-only" `Quick test_selection_does_not_retarget_capture;
                 test_case "workspace revoke" `Quick test_workspace_revoke_cannot_resurrect_capture;
                 test_case "surface revoke" `Quick test_surface_change_releases_capture];
    "navigation", [test_case "resize and edges" `Quick test_navigation_normalizes_before_moving;
                   test_case "end intent survives re-preparation" `Quick test_end_intent_survives_repreparation] ]
