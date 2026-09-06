(* Browser lane state (docs/design/browser-lane.md): the issue → poll →
   deliver round trip on a real Eio scheduler, and the refusals. *)

open Alcotest
module Lane = Browser_lane

let with_eio f =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    f ())
;;

let test_issue_poll_deliver_roundtrip () =
  with_eio (fun () ->
    (* A lane exists once a poll names it, and counts as connected from that
       poll — the same order the HTTP route pair produces. *)
    ignore (Lane.take_command ~lane_name:"live" ~window_sec:0.01);
    Eio.Switch.run (fun sw ->
      (* The tool side runs concurrently, as the HTTP route pair would: it
         issues and blocks; this fiber plays the host — take the command,
         post the answer — and then reads the issuer's outcome. *)
      let answered =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Lane.issue ~lane_name:"live" ~verb:Lane.Tabs_list ~timeout_sec:2.0)
      in
      (match Lane.take_command ~lane_name:"live" ~window_sec:2.0 with
      | Ok (Some issued) ->
        Lane.deliver_result ~lane_name:"live" ~id:issued.Lane.id
          ~payload:(`Assoc [ ("tabs", `List []) ])
        |> ignore
      | Ok None -> fail "no command was carried within the window"
      | Error message -> fail ("take refused: " ^ message));
      match Eio.Promise.await answered with
      | Error exn -> fail ("the issuer fiber raised: " ^ Printexc.to_string exn)
      | Ok (Lane.Answered (`Assoc (("tabs", `List []) :: _))) -> ()
      | Ok (Lane.Answered _) -> fail "answered with an unexpected payload"
      | Ok Lane.Timed_out -> fail "the round trip timed out"
      | Ok Lane.Lane_absent -> fail "the lane was absent inside the same scheduler"
      | Ok (Lane.Refused _) -> fail "a read verb was refused"))
;;

let test_unknown_lane_is_refused () =
  with_eio (fun () ->
    check bool "an unlisted lane never materializes" true
      (Option.is_none (Lane.lane_named ~name:"evil")))
;;

let test_absent_lane_answers_absent () =
  with_eio (fun () ->
    (* "automation" is allowed but has never polled: a tool call says so
       instead of timing out into silence. *)
    (match Lane.issue ~lane_name:"automation" ~verb:Lane.Tabs_list ~timeout_sec:0.1 with
    | Lane.Lane_absent -> ()
    | _ -> fail "expected Lane_absent for a never-polled lane"))
;;

let test_live_lane_refuses_act_verbs () =
  with_eio (fun () ->
    ignore (Lane.take_command ~lane_name:"live" ~window_sec:0.01);
    (match Lane.issue ~lane_name:"live" ~verb:(Lane.Page_goto { url = "https://x" }) ~timeout_sec:0.1 with
    | Lane.Refused _ -> ()
    | _ -> fail "expected Refused for a navigation on the live lane");
    (match Lane.issue ~lane_name:"live" ~verb:(Lane.Session_open { headless = None }) ~timeout_sec:0.1 with
    | Lane.Refused _ -> ()
    | _ -> fail "expected Refused for a session verb on the live lane"))
;;

let () =
  run "browser lane"
    [ "state", [ test_case "issue → poll → deliver round trip" `Quick
                   test_issue_poll_deliver_roundtrip
               ; test_case "unknown lane is refused" `Quick
                   test_unknown_lane_is_refused
               ; test_case "never-polled lane answers absent" `Quick
                   test_absent_lane_answers_absent
               ; test_case "the live lane refuses session and navigation verbs" `Quick
                   test_live_lane_refuses_act_verbs ] ]
;;
