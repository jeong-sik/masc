open Alcotest

let result = result string string

let test_unavailable_switch_clears_before_delivery () =
  let events = ref [] in
  Masc_tui_async_read.launch
    ~source:Standalone_lanes
    ~switch:None
    ~on_sync_failure:(fun () -> events := "clear" :: !events)
    ~deliver:(fun answer ->
      check result "attributed failure"
        (Error "standalone lanes load failed: Eio switch is unavailable") answer;
      events := "deliver" :: !events)
    ~read:(fun () -> fail "read ran without a switch")
    ();
  check (list string) "clear before delivery" [ "clear"; "deliver" ]
    (List.rev !events)

let test_finished_switch_keeps_guarded_failure () =
  Eio_main.run (fun _ ->
      let finished = ref None in
      Eio.Switch.run (fun sw -> finished := Some sw);
      match !finished with
      | None -> fail "could not capture a finished switch"
      | Some sw ->
        let events = ref [] in
        Masc_tui_async_read.launch
          ~source:Connectors
          ~switch:(Some sw)
          ~on_sync_failure:(fun () -> events := "clear" :: !events)
          ~deliver:(fun answer ->
            check result "attributed launch failure"
              (Error
                 "connector load failed: Invalid_argument(\"Switch finished!\")")
              answer;
            events := "deliver" :: !events)
          ~read:(fun () -> fail "read ran on a finished switch")
          ();
        check (list string) "guard ran before delivery"
          [ "clear"; "deliver" ] (List.rev !events))

let test_read_exception_is_attributed_once () =
  Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
          let answer, resolver = Eio.Promise.create () in
          Masc_tui_async_read.launch
            ~source:Connectors
            ~switch:(Some sw)
            ~on_sync_failure:(fun () -> fail "open switch refused launch")
            ~deliver:(Eio.Promise.resolve resolver)
            ~read:(fun () -> raise (Failure "decode boom"))
            ();
          check result "caught read exception"
            (Error "connector load failed: Failure(\"decode boom\")")
            (Eio.Promise.await answer)))

let () =
  run "TUI async read"
    [ ( "read boundary"
      , [ test_case "unavailable switch clears before delivery" `Quick
            test_unavailable_switch_clears_before_delivery
        ; test_case "finished switch keeps guarded failure" `Quick
            test_finished_switch_keeps_guarded_failure
        ; test_case "read exception is attributed once" `Quick
            test_read_exception_is_attributed_once
        ] )
    ]
