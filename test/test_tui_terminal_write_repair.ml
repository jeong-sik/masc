open Alcotest

module Render_schedule = Masc_tui_render_schedule
module Repair = Masc_tui_terminal_write_repair

let check_render label = function
  | Render_schedule.Render -> ()
  | Render_schedule.Idle -> failf "%s: expected render, got idle" label
  | Render_schedule.Wait_until due ->
      failf "%s: expected render, waiting until %Ld" label due

let check_idle label = function
  | Render_schedule.Idle -> ()
  | Render_schedule.Render -> failf "%s: expected idle, got render" label
  | Render_schedule.Wait_until due ->
      failf "%s: expected idle, waiting until %Ld" label due

let test_idle_console_write_forces_invalidated_frame () =
  ignore (Repair.consume_damage () : bool);
  Console_sink.For_testing.reset ();
  Fun.protect
    ~finally:(fun () ->
      Console_sink.For_testing.reset ();
      ignore (Repair.consume_damage () : bool))
    (fun () ->
      let schedule = Render_schedule.create ~min_interval_ns:16_000_000L () in
      check_render "initial frame"
        (Render_schedule.take schedule ~now_ns:0L);
      Console_sink.For_testing.set_writer (Some (fun _ -> ()));
      Console_sink.set_after_write_observer (Some Repair.note);
      Console_sink.write "idle diagnostic";
      Repair.request_repaint schedule;
      check_render "console write preempts an otherwise idle schedule"
        (Render_schedule.take schedule ~now_ns:1L);
      check bool "the forced frame observes cache damage" true
        (Repair.consume_damage ());
      Repair.request_repaint schedule;
      check_idle "consumed damage leaves no repaint work"
        (Render_schedule.take schedule ~now_ns:2L))

let test_redirected_stderr_disables_terminal_observation () =
  let saved_stderr = Unix.dup Unix.stderr in
  let (read_end, write_end) = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      Unix.dup2 saved_stderr Unix.stderr;
      Unix.close saved_stderr;
      Unix.close read_end;
      Unix.close write_end)
    (fun () ->
      Unix.dup2 write_end Unix.stderr;
      check bool "pipe-backed stderr is not the frame terminal" false
        (Repair.console_sink_writes_to_terminal ()))

let () =
  run "tui_terminal_write_repair"
    [ ( "console boundary"
      , [ test_case "idle console write forces an invalidated frame" `Quick
            test_idle_console_write_forces_invalidated_frame
        ; test_case "redirected stderr disables terminal observation" `Quick
            test_redirected_stderr_disables_terminal_observation
        ] )
    ]
