open Alcotest

(* The shared TUI read launch. A read answers exactly once, and its failure
   carries its source label exactly once -- whichever of the four ways it
   failed. The switch is bound with [Eio_context.with_turn_switch], the same
   lookup the TUI's launch sites go through; outside [Eio_main.run] and any
   binding, this test executable has no switch at all. *)

let result_t = result string string

let collect () =
  let answers = ref [] in
  (answers, fun result -> answers := result :: !answers)

let with_finished_switch f =
  Eio_main.run (fun _ ->
      let finished = ref None in
      Eio.Switch.run (fun sw -> finished := Some sw);
      match !finished with
      | None -> fail "could not capture a finished switch"
      | Some sw -> f sw)

let test_unavailable_switch_clears_before_delivery () =
  let events = ref [] in
  Masc_tui_async_read.launch ~source:Standalone_lanes
    ~on_not_run:(fun () -> events := "clear" :: !events)
    ~deliver:(fun answer ->
      check result_t "attributed failure"
        (Error "standalone lanes load failed: Eio switch is unavailable") answer;
      events := "deliver" :: !events)
    (fun () -> fail "read ran without a switch");
  check (list string) "clear before delivery" [ "clear"; "deliver" ]
    (List.rev !events)

let test_a_finished_switch_releases_and_answers_once () =
  with_finished_switch (fun sw ->
      let events = ref [] in
      let answers, deliver = collect () in
      Eio_context.with_turn_switch sw (fun () ->
          Masc_tui_async_read.launch ~source:Connectors
            ~on_not_run:(fun () -> events := "clear" :: !events)
            ~deliver:(fun answer ->
              events := "deliver" :: !events;
              deliver answer)
            (fun () -> fail "read ran on a finished switch"));
      check (list string) "released once, before delivery"
        [ "clear"; "deliver" ] (List.rev !events);
      check (list result_t) "one answer, labelled once"
        [ Error "connector load failed: Invalid_argument(\"Switch finished!\")" ]
        !answers)

let run_open ?source read =
  Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
          let released = ref 0 in
          let answers, deliver = collect () in
          Eio_context.with_turn_switch sw (fun () ->
              Masc_tui_async_read.launch ?source
                ~on_not_run:(fun () -> incr released)
                ~deliver read);
          Eio.Fiber.yield ();
          check int "a read that ran is not released here" 0 !released;
          !answers))

let test_the_reads_own_error_is_labelled_once () =
  check (list result_t) "labelled once"
    [ Error "connector load failed: HTTP 503" ]
    (run_open ~source:Connectors (fun () -> Error "HTTP 503"))

let test_a_raised_read_is_labelled_once () =
  check (list result_t) "labelled once"
    [ Error "connector load failed: Failure(\"decode boom\")" ]
    (run_open ~source:Connectors (fun () -> failwith "decode boom"))

let test_no_source_keeps_the_cause_as_is () =
  check (list result_t) "unlabelled" [ Error "already labelled" ]
    (run_open (fun () -> Error "already labelled"))

let test_a_loaded_read_answers_once () =
  check (list result_t) "loaded" [ Ok "rows" ]
    (run_open ~source:Keeper_turns (fun () -> Ok "rows"))

let test_keeper_turns_uses_one_label_for_every_failure_boundary () =
  let source = Masc_tui_async_read.Keeper_turns in
  let label detail = Error ("keeper turns load failed: " ^ detail) in
  check result_t "loader error is attributed once" (label "bad response")
    (Masc_tui_async_read.attribute source (Error "bad response"));
  let cleared = ref false in
  Masc_tui_async_read.launch ~source
    ~on_not_run:(fun () -> cleared := true)
    ~deliver:(fun answer ->
      check bool "no-switch launch clears inflight before delivery" true
        !cleared;
      check result_t "no-switch failure has source"
        (label "Eio switch is unavailable") answer)
    (fun () -> fail "read ran without a switch");
  with_finished_switch (fun sw ->
      let cleared = ref false in
      Eio_context.with_turn_switch sw (fun () ->
          Masc_tui_async_read.launch ~source
            ~on_not_run:(fun () -> cleared := true)
            ~deliver:(fun answer ->
              check bool "finished-switch launch clears inflight before delivery"
                true !cleared;
              check result_t "finished-switch failure has source"
                (label "Invalid_argument(\"Switch finished!\")") answer)
            (fun () -> fail "read ran on a finished switch")));
  check (list result_t) "read exception has source"
    [ label "Failure(\"decode boom\")" ]
    (run_open ~source (fun () -> failwith "decode boom"))

let () =
  run "test_tui_async_read"
    [
      ( "not run",
        [
          test_case "unavailable switch clears before delivery" `Quick
            test_unavailable_switch_clears_before_delivery;
          test_case "finished switch releases and answers once" `Quick
            test_a_finished_switch_releases_and_answers_once;
        ] );
      ( "ran",
        [
          test_case "read error labelled once" `Quick
            test_the_reads_own_error_is_labelled_once;
          test_case "raised read labelled once" `Quick
            test_a_raised_read_is_labelled_once;
          test_case "no source keeps the cause" `Quick
            test_no_source_keeps_the_cause_as_is;
          test_case "loaded answers once" `Quick test_a_loaded_read_answers_once;
          test_case "keeper turns labels every failure boundary" `Quick
            test_keeper_turns_uses_one_label_for_every_failure_boundary;
        ] );
    ]
