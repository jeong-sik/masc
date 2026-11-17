(** A context-inspector read replaces the one before it.

    Page refresh, tab detail and selected-part reads retain their own source.
    Replacing a read withdraws it before the next one starts. *)

module Tui_types = Masc_tui_types

let state () =
  Tui_types.create_state ~workspace:"test" ~port:8935 ()
;;

let test_a_launch_stops_the_read_it_replaced () =
  let state = state () in
  let stopped = ref 0 in
  let stop () = incr stopped in
  Tui_types.supersede_context_inspector_load state (Some stop);
  Alcotest.(check int) "a first read stops nothing" 0 !stopped;
  Tui_types.supersede_context_inspector_load state (Some stop);
  Alcotest.(check int) "the next read stops the one it replaced" 1 !stopped;
  Tui_types.supersede_context_inspector_load state None;
  Alcotest.(check int) "closing the pane stops the read in flight" 2 !stopped;
  Tui_types.supersede_context_inspector_load state None;
  Alcotest.(check int) "a closed pane has nothing left to stop" 2 !stopped
;;

let test_response_reader_returns_to_the_open_input () =
  let module Inspector = Masc_tui_context_inspector in
  List.iter (fun tab ->
      let state = state () in
      state.context_inspector_open <- true;
      state.context_inspector_tab <- tab;
      state.context_inspector_cursor <- 8;
      state.context_inspector_exact <- Some 8;
      state.context_inspector_scroll <- 23;
      state.context_inspector_detail_scroll <- 17;
      state.context_inspector_focus <- Tui_types.Right_pane;
      Tui_types.enter_context_inspector_tab state Inspector.Response;
      state.context_inspector_response_scroll <- 71;
      (* Repeating the response command must not replace its return target. *)
      Tui_types.enter_context_inspector_tab state Inspector.Response;
      Tui_types.enter_context_inspector_tab state state.context_inspector_response_return;
      Alcotest.(check bool) "return to original input/proof tab" true
        (state.context_inspector_tab = tab);
      Alcotest.(check (option int)) "opened original item remains selected" (Some 8)
        state.context_inspector_exact;
      Alcotest.(check int) "input cursor retained" 8 state.context_inspector_cursor;
      Alcotest.(check int) "opened input position retained" 23 state.context_inspector_scroll;
      Alcotest.(check int) "split detail position retained" 17 state.context_inspector_detail_scroll;
      Alcotest.(check bool) "split focus retained" true
        (state.context_inspector_focus = Tui_types.Right_pane);
      Alcotest.(check int) "response position independent" 71 state.context_inspector_response_scroll)
    [ Inspector.Exact_input; Inspector.Input_map ]
;;

let test_fresh_page_cannot_be_reused_while_refresh_is_pending () =
  let module Inspector = Masc_tui_context_inspector in
  let state = state () in
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some "omega";
  state.context_inspector_target <- Inspector.Recent 0;
  state.context_inspector_tab <- Inspector.Input_map;
  let old = Inspector.Turn_read_failed
      { detail = "previous page failed"; forecast = Not_requested } in
  state.context_inspector_reading <- Some ("omega", old);
  state.context_inspector_read_at <- Some 42.;
  let cancelled = ref false in
  Tui_types.supersede_context_inspector_load state (Some (fun () -> cancelled := true));
  let generation = state.context_inspector_generation in
  let previous = Tui_types.begin_context_inspector_read ~reuse:false state ~keeper_name:"omega" in
  Alcotest.(check bool) "the old request is withdrawn" true !cancelled;
  Alcotest.(check int) "fresh page has a new generation" (generation + 1)
    state.context_inspector_generation;
  Alcotest.(check bool) "the reader cannot reuse the old page" true (Option.is_none previous);
  Alcotest.(check bool) "old page is not available to tab reconciliation" true
    (Option.is_none state.context_inspector_reading);
  Alcotest.(check (option (float 0.))) "old page is not stamped freshly read" None
    state.context_inspector_read_at;
  Tui_types.enter_context_inspector_tab state Inspector.Composition;
  Alcotest.(check bool) "tab switch waits for the requested fresh page" false
    (Option.exists (fun (_, reading) ->
       Inspector.needs_tab_read ~tab:state.context_inspector_tab reading)
       state.context_inspector_reading);
  Alcotest.(check bool) "the requested page is still loading" true state.context_inspector_loading
;;

let test_response_switch_and_close_release_the_previous_input () =
  let module Inspector = Masc_tui_context_inspector in
  let state = state () in
  state.context_inspector_open <- true;
  state.context_inspector_tab <- Inspector.Exact_input;
  state.context_inspector_exact <- Some 8;
  state.context_inspector_cursor <- 8;
  state.context_inspector_scroll <- 23;
  state.context_inspector_detail_scroll <- 17;
  state.context_inspector_focus <- Tui_types.Right_pane;
  Tui_types.enter_context_inspector_tab state Inspector.Response;
  Tui_types.enter_context_inspector_tab state Inspector.Input_map;
  Alcotest.(check (option int)) "different tab releases old opened item" None state.context_inspector_exact;
  Alcotest.(check int) "different tab starts its own selection" 0 state.context_inspector_cursor;
  Alcotest.(check int) "different tab resets input scroll" 0 state.context_inspector_scroll;
  Alcotest.(check int) "different tab resets detail scroll" 0 state.context_inspector_detail_scroll;
  Alcotest.(check bool) "different tab returns focus to its list" true
    (state.context_inspector_focus = Tui_types.Left_pane);
  let stopped = ref 0 in
  Tui_types.supersede_context_inspector_load state (Some (fun () -> incr stopped));
  Tui_types.supersede_context_inspector_part_load state (Some (fun () -> incr stopped));
  Tui_types.enter_context_inspector_tab state Inspector.Response;
  state.context_inspector_response_scroll <- 71;
  Tui_types.close_context_inspector state;
  Alcotest.(check int) "closing cancels both observations" 2 !stopped;
  Alcotest.(check bool) "inspector closed" false state.context_inspector_open;
  Alcotest.(check int) "response position released" 0 state.context_inspector_response_scroll;
  Alcotest.(check bool) "return target released" true
    (state.context_inspector_response_return = Inspector.Composition)
;;

let () =
  Alcotest.run
    "tui context inspector supersede"
    [ ( "load"
      , [ Alcotest.test_case
            "a launch stops the read it replaced"
            `Quick
            test_a_launch_stops_the_read_it_replaced
        ; Alcotest.test_case "response returns to opened input or proof" `Quick
            test_response_reader_returns_to_the_open_input
        ; Alcotest.test_case "response switch and close release original navigation" `Quick
            test_response_switch_and_close_release_the_previous_input
        ; Alcotest.test_case "fresh page is not reused by a tab switch" `Quick
            test_fresh_page_cannot_be_reused_while_refresh_is_pending
        ] )
    ]
;;
