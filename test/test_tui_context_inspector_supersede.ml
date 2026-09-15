(** A context-inspector read replaces the one before it.

    One read asks the server to resolve a whole provider input: hundreds of
    blob artifacts for a live keeper turn. Stepping through turns starts a
    read per step, and the reads a step replaced used to keep running with
    their answers thrown away, so holding the key queued that work several
    times over. *)

module Tui_types = Masc_tui_types

let state () =
  Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
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

let () =
  Alcotest.run
    "tui context inspector supersede"
    [ ( "load"
      , [ Alcotest.test_case
            "a launch stops the read it replaced"
            `Quick
            test_a_launch_stops_the_read_it_replaced
        ] )
    ]
;;
