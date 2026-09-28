(* When the startup splash stands aside, which overlays own the keys, and how
   far the moving marks have gone -- read off the TUI state, the way the main
   loop and the renderer read them. *)

open Alcotest
module Types = Masc_tui_types

let fresh () =
  let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.Types.startup_emblem <- true;
  state.Types.connection_status <- Types.Connecting;
  state

let test_the_splash_stands_only_while_the_overview_has_nothing_to_say () =
  let state = fresh () in
  check bool "connecting, nothing read: the imp stands" true
    (Types.startup_emblem_visible state);
  state.Types.connection_status <- Types.Booting;
  check bool "booting before the backlog is read: the imp stands" true
    (Types.startup_emblem_visible state);
  state.Types.task_reading <- Masc_tui_overview_tasks.Rows_read [];
  check bool "booting with the backlog read: the Overview draws it" false
    (Types.startup_emblem_visible state);
  state.Types.task_reading <- Masc_tui_overview_tasks.Rows_unavailable "unreadable";
  check bool "booting with the backlog unreadable: the Overview says so" false
    (Types.startup_emblem_visible state);
  let failed = fresh () in
  failed.Types.connection_status <- Types.Disconnected;
  check bool "a failed refresh: the Overview's press-r line" false
    (Types.startup_emblem_visible failed);
  let answered = fresh () in
  answered.Types.overview_error <- Some "overview load failed: 503";
  check bool "an answered read, even an error" false
    (Types.startup_emblem_visible answered);
  let elsewhere = fresh () in
  elsewhere.Types.view <- Types.Keepers Types.Keeper_list;
  check bool "another surface" false (Types.startup_emblem_visible elsewhere);
  let ended = fresh () in
  ended.Types.startup_emblem <- false;
  check bool "ended once, gone for good" false (Types.startup_emblem_visible ended)

let open_each state =
  [ ("help", fun () -> state.Types.help_open <- true)
  ; ("deletions", fun () -> state.Types.keeper_deletions_open <- true)
  ; ("agenda", fun () -> state.Types.agenda_open <- true)
  ; ("context inspector", fun () -> state.Types.context_inspector_open <- true)
  ; ("about", fun () -> state.Types.about_open <- true)
  ]

let test_each_key_owning_overlay_owns_the_keys () =
  let state = fresh () in
  check bool "nothing open" false (Types.modal_owns_keys state);
  List.iter
    (fun (name, open_it) ->
      Types.close_key_modals state;
      open_it ();
      check bool (name ^ " owns the keys") true (Types.modal_owns_keys state))
    (open_each state);
  List.iter (fun (_, open_it) -> open_it ()) (open_each state);
  state.Types.help_scroll <- 4;
  state.Types.agenda_scroll <- 3;
  state.Types.context_inspector_scroll <- 2;
  Types.close_key_modals state;
  check bool "closing them all leaves none" false (Types.modal_owns_keys state);
  check int "help starts at its top next time" 0 state.Types.help_scroll;
  check int "the agenda too" 0 state.Types.agenda_scroll;
  check int "and the inspector" 0 state.Types.context_inspector_scroll

let test_the_palette_is_not_one_of_them () =
  (* The palette takes typed text, which the text-field rule already routes;
     it is not a key-swallowing overlay. *)
  let state = fresh () in
  state.Types.palette_open <- true;
  check bool "the palette" false (Types.modal_owns_keys state)

let test_moving_marks_share_one_pace () =
  check (float 1e-9) "not started" 0.0 (Types.motion_elapsed_seconds (-1));
  check (float 1e-9) "the first step" 0.0 (Types.motion_elapsed_seconds 0);
  check (float 1e-9) "ten steps"
    (10.0 *. Int64.to_float Types.motion_step_ns /. 1e9)
    (Types.motion_elapsed_seconds 10)

let () =
  run "tui_emblem_state"
    [ ( "splash"
      , [ test_case "it stands only while the Overview has nothing to say" `Quick
            test_the_splash_stands_only_while_the_overview_has_nothing_to_say
        ] )
    ; ( "overlays"
      , [ test_case "each key-owning overlay owns the keys" `Quick
            test_each_key_owning_overlay_owns_the_keys
        ; test_case "the palette is not one of them" `Quick
            test_the_palette_is_not_one_of_them
        ] )
    ; ( "motion"
      , [ test_case "moving marks share one pace" `Quick test_moving_marks_share_one_pace ] )
    ]
