open Alcotest

(* The shared TUI read launch. A read answers exactly once, and its failure
   carries the subject label exactly once -- whichever of the four ways it
   failed. The switch is bound with [Eio_context.with_turn_switch], the same
   lookup the TUI's launch sites go through. *)

let collect () =
  let answers = ref [] in
  (answers, fun result -> answers := result :: !answers)

let result_t = result string string

let test_a_finished_switch_releases_and_answers_once () =
  Eio_main.run (fun _ ->
      let finished = ref None in
      Eio.Switch.run (fun sw -> finished := Some sw);
      match !finished with
      | None -> fail "could not capture a finished switch"
      | Some sw ->
          let released = ref 0 in
          let read_ran = ref false in
          let answers, deliver = collect () in
          Eio_context.with_turn_switch sw (fun () ->
              Masc_tui_async_read.launch
                ~on_not_run:(fun () -> incr released)
                ~subject:"keeper turns" ~deliver
                (fun () ->
                  read_ran := true;
                  Ok "never"));
          check int "the armed flag is released once" 1 !released;
          check bool "the read never ran" false !read_ran;
          check (list result_t) "one answer, labelled once"
            [ Error
                "keeper turns load failed: Invalid_argument(\"Switch finished!\")"
            ]
            !answers)

let run_open read ~subject =
  Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
          let released = ref 0 in
          let answers, deliver = collect () in
          Eio_context.with_turn_switch sw (fun () ->
              Masc_tui_async_read.launch
                ~on_not_run:(fun () -> incr released)
                ?subject ~deliver read);
          Eio.Fiber.yield ();
          check int "a read that ran is not released here" 0 !released;
          !answers))

let test_the_reads_own_error_is_labelled_once () =
  check (list result_t) "labelled once"
    [ Error "connectors load failed: HTTP 503" ]
    (run_open ~subject:(Some "connectors") (fun () -> Error "HTTP 503"))

let test_a_raised_read_is_labelled_once () =
  check (list result_t) "labelled once"
    [ Error "skills catalog load failed: Failure(\"broken body\")" ]
    (run_open ~subject:(Some "skills catalog") (fun () ->
         failwith "broken body"))

let test_no_subject_keeps_the_cause_as_is () =
  check (list result_t) "unlabelled" [ Error "already labelled" ]
    (run_open ~subject:None (fun () -> Error "already labelled"))

let test_a_loaded_read_answers_once () =
  check (list result_t) "loaded" [ Ok "rows" ]
    (run_open ~subject:(Some "schedules") (fun () -> Ok "rows"))

let suite =
  [
    ( "not run",
      [ test_case "finished switch releases and answers once" `Quick
          test_a_finished_switch_releases_and_answers_once ] );
    ( "ran",
      [
        test_case "read error labelled once" `Quick
          test_the_reads_own_error_is_labelled_once;
        test_case "raised read labelled once" `Quick
          test_a_raised_read_is_labelled_once;
        test_case "no subject keeps the cause" `Quick
          test_no_subject_keeps_the_cause_as_is;
        test_case "loaded answers once" `Quick test_a_loaded_read_answers_once;
      ] );
  ]

let () = run "test_tui_async_read" suite
