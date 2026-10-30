(* Which Activity pane layout a surface starts with. Home gets the same
   default as every other surface, so a wide terminal does not leave its right
   side empty, and an explicit reader choice still decides on any surface. *)

open Alcotest
module Pane = Masc_tui_acting_pane

let state_on view =
  let state =
    Masc_tui_types.create_state ~workspace:"test" ~port:8935
      ~refresh_interval:2.0 ()
  in
  state.view <- view;
  state

(* The narrowest terminal that fits the narrow pane, so the cases hold for any
   floor the pane declares. *)
let narrow_fits_cols = Pane.threshold_cols

let test_home_starts_like_every_other_surface () =
  let on_home = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Overview) in
  let on_board = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Board) in
  check bool "Home and Board start with the same layout" true (on_home = on_board)

let test_home_draws_the_pane_where_the_pane_fits () =
  let layout = Masc_tui_types.acting_pane_layout (state_on Masc_tui_types.Overview) in
  check bool "the pane takes columns beside Home at its floor" true
    (Pane.drawn_cols ~layout ~cols:narrow_fits_cols > 0);
  check int "and none below its floor" 0
    (Pane.drawn_cols ~layout ~cols:(narrow_fits_cols - 1))

let test_a_reader_choice_still_hides_the_pane_on_home () =
  let state = state_on Masc_tui_types.Overview in
  state.acting_pane_preference <- Masc_tui_types.Chosen_acting_pane Pane.Hidden;
  let layout = Masc_tui_types.acting_pane_layout state in
  check int "a hidden pane takes no column" 0
    (Pane.drawn_cols ~layout ~cols:narrow_fits_cols)

let file_change path : Masc.Tui_decode.file_change =
  { fc_at = 1.; fc_keeper = "alpha"; fc_turn = None; fc_task_id = None
  ; fc_execution_id = None; fc_line_evidence = None
  ; fc_location = Fc_in_repo { repo_id = "repo"; relative_path = path }
  ; fc_kind = Fc_written { content = "" }; fc_succeeded = true
  }

let changes path : Masc.Tui_decode.file_change_snapshot =
  { fcs_keeper = "alpha"; fcs_window_hours = 1.; fcs_calls_in_window = 1
  ; fcs_changes = [file_change path]; fcs_over_budget = 0; fcs_malformed = 0
  }

let test_file_action_uses_the_presented_source () =
  let state = state_on Masc_tui_types.Overview in
  let original = changes "original.ml" in
  let identical = changes "original.ml" in
  let later = changes "later.ml" in
  let scope = state.workspace_authority, state.workspace_read_authority in
  let reading : Masc_tui_types.acting_pane_read =
    { apr_scope = scope; apr_snapshot = original }
  in
  check bool "identical decoded values retain their source" true
    (Masc_tui_types.retain_unchanged_acting_pane_changes
       ~scope ~previous:(Masc_tui_fetched.Ready reading) identical == original);
  check bool "a changed decoded value keeps its own source" true
    (Masc_tui_types.retain_unchanged_acting_pane_changes
       ~scope ~previous:(Masc_tui_fetched.Ready reading) later == later);
  check bool "a different workspace cannot reuse the previous source" true
    (Masc_tui_types.retain_unchanged_acting_pane_changes
       ~scope:(Masc_tui_types.Workspace_authority 99, state.workspace_read_authority)
       ~previous:(Masc_tui_fetched.Ready reading) identical == identical);
  let source : Masc_tui_types.acting_pane_source =
    { aps_scope = scope
    ; aps_file_source = Some { aps_keeper = "alpha"; aps_read = reading } }
  in
  state.acting_pane_presented <-
    { Pane.frame_columns = 20; frame_targets = [Pane.Target_file 0]; frame_scroll_max = 0
    ; frame_source = Some source };
  (* A newer read may land before a new frame is accepted. *)
  let next, request =
    match Masc_tui_fetched.start ~equal:Masc_tui_types.same_acting_pane_keeper
            state.acting_pane_changes ~key:{ apk_keeper = "alpha"; apk_scope = scope } with
    | Masc_tui_fetched.Started (next, request) -> next, request
    | Masc_tui_fetched.Already_loading -> fail "fixture already loading"
  in
  state.acting_pane_changes <-
    Masc_tui_fetched.complete ~equal:Masc_tui_types.same_acting_pane_key next request
      (Ok { reading with apr_snapshot = later });
  let candidate =
    { state.acting_pane_presented with
      frame_source = Some { source with aps_file_source =
        Some { aps_keeper = "alpha"; aps_read = { reading with apr_snapshot = later } } } }
  in
  check bool "a newer source needs a presentation" false
    (Masc_tui_types.same_acting_pane_authority state.acting_pane_presented candidate);
  check bool "an unchanged source keeps its authority" true
    (Masc_tui_types.same_acting_pane_authority state.acting_pane_presented state.acting_pane_presented);
  let resolve ~scope ~selected_keeper ~line =
    Masc_tui_types.presented_acting_pane_file state.acting_pane_presented
      ~scope ~selected_keeper ~line
  in
  (match resolve ~scope ~selected_keeper:(Some "alpha") ~line:0 with
   | Some (snapshot, 0) ->
       check bool "the accepted frame retains the original snapshot" true
         (snapshot == original)
   | Some _ | None -> fail "presented file was not resolved");
  check bool "a different keeper cannot use the row" true
    (Option.is_none
       (resolve ~scope ~selected_keeper:(Some "beta") ~line:0));
  check bool "a replaced workspace cannot use the row" true
    (Option.is_none
       (resolve ~scope:(Masc_tui_types.Workspace_authority 99, state.workspace_read_authority)
          ~selected_keeper:(Some "alpha") ~line:0));
  let resumed = state.workspace_authority, ref () in
  let repainted_with_old_read =
    { state.acting_pane_presented with
      frame_source = Some { source with aps_scope = resumed } }
  in
  check bool "repainting retained data cannot renew its read authority" true
    (Option.is_none
       (Masc_tui_types.presented_acting_pane_file repainted_with_old_read
          ~scope:resumed ~selected_keeper:(Some "alpha") ~line:0));
  check bool "an undrawn row cannot resolve a file" true
    (Option.is_none
       (resolve ~scope ~selected_keeper:(Some "alpha") ~line:1));
  let new_key : Masc_tui_types.acting_pane_key =
    { apk_keeper = "alpha"; apk_scope = resumed }
  in
  check bool "a reopened pane owes a read in the new scope" true
    (Masc_tui_types.acting_pane_read_needed ~key:new_key state.acting_pane_changes);
  let revalidating, request =
    match Masc_tui_fetched.start ~equal:Masc_tui_types.same_acting_pane_keeper
            state.acting_pane_changes ~key:new_key with
    | Masc_tui_fetched.Started (next, request) -> next, request
    | Masc_tui_fetched.Already_loading -> fail "revalidation did not start"
  in
  let failed = Masc_tui_fetched.complete ~equal:Masc_tui_types.same_acting_pane_key
      revalidating request (Error "read failed") in
  check bool "a failed revalidation is not retried on every input" false
    (Masc_tui_types.acting_pane_read_needed ~key:new_key failed);
  (match Masc_tui_fetched.view_for ~equal:Masc_tui_types.same_acting_pane_keeper
           failed ~key:new_key with
   | Masc_tui_fetched.Stale (held, _) ->
       check bool "failed revalidation retains the old observation" true
         (held.apr_snapshot == later)
   | Masc_tui_fetched.Absent | Loading | Ready _ | Failed _ ->
       fail "failed revalidation lost the retained observation")

let () =
  run "tui acting pane default"
    [ ( "default layout"
      , [ test_case "Home starts like every other surface" `Quick
            test_home_starts_like_every_other_surface
        ; test_case "Home draws the pane where the pane fits" `Quick
            test_home_draws_the_pane_where_the_pane_fits
        ; test_case "a reader choice still hides the pane on Home" `Quick
            test_a_reader_choice_still_hides_the_pane_on_home
        ; test_case "file action retains its presented source" `Quick
            test_file_action_uses_the_presented_source
        ] )
    ]
