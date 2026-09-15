(* An execution dashboard render that finished as its window closed is the
   render.

   [Dashboard_execution.json] bounds the render so a stalled store read cannot
   hold a request for hours, and the bound used to be
   [Eio.Time.with_timeout], which keeps whichever arm finished first. A render
   that completed in the pass the window expired was replaced with the
   "render timed out" page. The mock clock puts the window's wake-up ahead of
   the render's on purpose. *)
open Alcotest
module Execution = Dashboard_execution

let window_s = 1.0

let with_clock f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run @@ fun sw -> f ~sw ~clock
;;

let rendered = `Assoc [ "rendered", `Bool true ]

let test_a_render_that_finished_as_the_window_closed_is_the_render () =
  with_clock
  @@ fun ~sw ~clock ->
  let render_done, finish = Eio.Promise.create () in
  let running =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Execution.For_test.render_under_timeout ~clock ~timeout_s:window_s (fun () ->
        Eio.Promise.await render_done))
  in
  (* The window closes first: its wake-up is queued. The render then
     finishes, queuing its wake-up behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve finish rendered;
  match Eio.Promise.await_exn running with
  | Ok payload ->
    check bool "the render that finished is the answer" true (Yojson.Safe.equal rendered payload)
  | Error `Timeout -> fail "a render that finished as the window closed became the timeout page"
;;

let test_a_render_that_never_finishes_is_a_timeout () =
  with_clock
  @@ fun ~sw ~clock ->
  let never, _ = Eio.Promise.create () in
  let running =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Execution.For_test.render_under_timeout ~clock ~timeout_s:window_s (fun () ->
        Eio.Promise.await never))
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await_exn running with
  | Error `Timeout -> ()
  | Ok _ -> fail "nothing was rendered, yet the window did not end the render"
;;

let () =
  run
    "dashboard_execution_render_window"
    [ ( "render window"
      , [ test_case
            "a render that finished as the window closed is the render"
            `Quick
            test_a_render_that_finished_as_the_window_closed_is_the_render
        ; test_case
            "a render that never finishes is a timeout"
            `Quick
            test_a_render_that_never_finishes_is_a_timeout
        ] )
    ]
;;
