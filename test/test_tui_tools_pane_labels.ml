open Masc_tui_types

let async_json_submitted_at submitted_at =
  `Assoc
    [ "schema", `String "masc.async-request-observation/v1"; "status", `String "ready"
    ; "summary", `Assoc [ "active", `Int 1; "runtime_owned", `Int 1; "ownership_unknown", `Int 0; "record_errors", `Int 0 ]
    ; "requests", `List [ `Assoc [ "request_id", `String "req-capture-0001"; "submitted_by", `String "capture-owner"; "keeper_name", `String "imp"; "status", `String "running"; "worker_ownership", `String "runtime_owned"; "submitted_at", `Float submitted_at; "elapsed_sec", `Float 12.5 ] ]
    ; "startup_recovery", `Null ]

let async_json = async_json_submitted_at 1000.0

let async_of_json ?(json = async_json) () =
  match Masc.Tui_decode.decode_async_request_observation json with
  | Ok observation -> observation
  | Error detail -> failwith ("async: " ^ detail)

let tools_state () =
  let state = create_state ~workspace:"" ~port:0 () in
  state.view <- Tools;
  state.agenda_open <- false;
  state.schedules <- None;
  state.schedules_error <- None;
  state.keeper_tool_approvals_observed <- false;
  state.keeper_tool_approvals_error <- None;
  state.observer <- Observer_off;
  state.keepers_error <- None;
  state.tools_inventory <-
    Some { Masc.Tui_decode_tools.ts_tools = []
         ; ts_count = 0
         ; ts_freshness = Masc.Tui_decode_tools.Settled
         ; ts_effective = None
         ; ts_usage = None
         ; ts_volume_gc_report = None
         ; ts_storage =
             { Masc.Tui_decode_tools.st_host_disk = Masc.Tui_decode_tools.Host_disk_absent
             ; st_keeper_cleanup = Masc.Tui_decode_tools.Keeper_cleanup_absent } };
  state.tools_async_observation <- Some (async_of_json ());
  state

let test_readings_and_failures_belong_to_their_keeper () =
  let waiting = Masc_tui_owed_read.Waiting
      { failures = 3; retry_at = Masc_tui_wake.Mono.after (Masc_tui_wake.Mono.now ()) 100. } in
  let failures = function
    | Masc_tui_owed_read.Reading { failures; _ } -> failures
    | Masc_tui_owed_read.(Settled | Owed _ | Waiting _) -> Alcotest.fail "the read did not start"
  in
  Alcotest.(check int) "another Keeper's read starts with no failures" 0
    (failures (start_owed_read ~for_another:true waiting));
  Alcotest.(check int) "the same Keeper's read keeps backing off" 3
    (failures (start_owed_read ~for_another:false waiting));
  let error = Some "inventory read failed" in
  Alcotest.(check (option string)) "the selected Keeper's error is drawn" error
    (held_tools_error ~selected:(Some "a") ~held_keeper:(Some "a") error);
  Alcotest.(check (option string)) "another Keeper's error is not" None
    (held_tools_error ~selected:(Some "b") ~held_keeper:(Some "a") error);
  Alcotest.(check (option string)) "an error read with no Keeper selected" error
    (held_tools_error ~selected:None ~held_keeper:None error)

(* The Async pane lists every request with its age and scrolls. Building
   the rows notes no redraw; each request row carries the instant its age
   reads differently, and only a window that draws the row asks for it. *)
let async_display ~cols =
  let state = tools_state () in
  let submitted_at = Unix.gettimeofday () -. 20. in
  state.tools_async_observation <-
    Some (async_of_json ~json:(async_json_submitted_at submitted_at) ());
  state.tools_pane <- Tools_async;
  Masc_tui_value.Redraw.begin_frame ();
  let display = Masc_tui_render_tools.tools_display ~cols state in
  Alcotest.(check bool) "building every row notes nothing" true
    (Option.is_none (Masc_tui_value.Redraw.next_change ()));
  (submitted_at, display)

let drawn (display : Masc_tui_render_tools.display) ~first ~height =
  Masc_tui_render_tools.drawn_change display
    (Masc_tui_rows.of_list ~first ~height display.lines)

let test_a_request_age_asks_for_a_redraw_only_when_drawn () =
  let submitted_at, display = async_display ~cols:160 in
  match display.row_changes with
  | [ (index, at) ] ->
    Alcotest.(check bool) "its age changes after it was submitted" true (at > submitted_at);
    Alcotest.(check (option (float 0.))) "a window that draws the row asks for it" (Some at)
      (drawn display ~first:index ~height:1);
    Alcotest.(check (option (float 0.))) "a window above the row asks nothing" None
      (drawn display ~first:0 ~height:index);
    Alcotest.(check (option (float 0.))) "a window below the row asks nothing" None
      (drawn display ~first:(index + 1) ~height:(List.length display.lines))
  | ([] | _ :: _ :: _) as changes ->
    Alcotest.failf "only the request row carries a change, not %d rows" (List.length changes)

(* A request row too wide for the frame wraps, and its age may land on any
   of the rows: a window that draws only the last of them still asks. *)
let test_a_wrapped_request_asks_from_each_of_its_rows () =
  let _, display = async_display ~cols:40 in
  match display.row_changes, List.rev display.row_changes with
  | (_, at) :: _ :: _, (last, _) :: _ ->
    Alcotest.(check bool) "every row of the request carries one instant" true
      (List.for_all (fun (_, other) -> Float.equal other at) display.row_changes);
    Alcotest.(check (option (float 0.))) "a window over its last row asks for it" (Some at)
      (drawn display ~first:last ~height:1)
  | ([] | [ _ ]), _ | _, [] ->
    Alcotest.failf "the request row wraps into more than one row, not %d"
      (List.length display.row_changes)

let () =
  let open Alcotest in
  run "TUI tools pane labels"
    [ ( "labels"
      , [ test_case "readings and failures belong to their Keeper" `Quick
            test_readings_and_failures_belong_to_their_keeper
        ; test_case "a request age asks for a redraw only when drawn" `Quick
            test_a_request_age_asks_for_a_redraw_only_when_drawn
        ; test_case "a wrapped request asks from each of its rows" `Quick
            test_a_wrapped_request_asks_from_each_of_its_rows
        ] )
    ]
