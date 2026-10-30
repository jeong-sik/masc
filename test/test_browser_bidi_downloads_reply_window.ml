(* A Firefox BiDi command reply that arrived as its window closed is the reply.

   [Browser_bidi_downloads] sends each command and awaits its reply under a
   window, and interrupts the whole download session when the window ends the
   wait. The window used to keep whichever arm finished first, so a reply that
   arrived in the pass the window expired tore the session down as if Firefox
   had gone silent. The mock clock puts the window's wake-up ahead of the
   reply's on purpose. *)
open Alcotest
module Downloads = Masc.Browser_bidi_downloads

let window_s = 1.0

let with_clock f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run @@ fun sw -> f ~sw ~clock
;;

let test_a_reply_that_arrived_as_the_window_closed_is_the_reply () =
  with_clock
  @@ fun ~sw ~clock ->
  let reply, arrive = Eio.Promise.create () in
  let waiting =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Downloads.For_testing.reply_within ~clock ~timeout_s:window_s reply)
  in
  (* The window closes first: its wake-up is queued. The reply then arrives,
     queuing its wake-up behind it. *)
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve arrive (Ok "subscribed");
  match Eio.Promise.await_exn waiting with
  | Ok (Ok answer) -> check string "the reply that arrived is the answer" "subscribed" answer
  | Ok (Error detail) -> failf "the reply was replaced with an error: %s" detail
  | Error `Timeout -> fail "a reply that arrived as the window closed was reported as a timeout"
;;

let test_a_command_that_gets_no_reply_is_a_timeout () =
  with_clock
  @@ fun ~sw ~clock ->
  let never : (string, string) result Eio.Promise.t = fst (Eio.Promise.create ()) in
  let waiting =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Downloads.For_testing.reply_within ~clock ~timeout_s:window_s never)
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await_exn waiting with
  | Error `Timeout -> ()
  | Ok _ -> fail "no reply arrived, yet the window did not end the wait"
;;

let () =
  run
    "browser_bidi_downloads_reply_window"
    [ ( "reply window"
      , [ test_case
            "a reply that arrived as the window closed is the reply"
            `Quick
            test_a_reply_that_arrived_as_the_window_closed_is_the_reply
        ; test_case
            "a command that gets no reply is a timeout"
            `Quick
            test_a_command_that_gets_no_reply_is_a_timeout
        ] )
    ]
;;
