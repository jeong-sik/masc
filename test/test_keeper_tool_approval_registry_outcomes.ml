open Alcotest

module Registry = Masc.Keeper_tool_approval_registry

let outcome_totals = Alcotest.testable (fun fmt t ->
    Fmt.pf fmt "{ answered_total = %d; timed_out_total = %d }" t.Registry.answered_total
      t.Registry.timed_out_total)
    ( = )

let with_env f = Eio_main.run (fun env -> f ~clock:(Eio.Stdenv.clock env))

let keeper = "keeper.one"

let totals registry = Registry.outcome_totals registry

let test_new_registry_counts_nothing () =
  let registry = Registry.create () in
  check outcome_totals "a fresh registry has no outcomes"
    { Registry.answered_total = 0; timed_out_total = 0 } (totals registry)

let test_an_answer_counted_once () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let result =
        Eio.Fiber.pair
          (fun () ->
            Registry.await registry ~clock ~tool_name:"Execute" ~args:"{}"
                ~question:"run?" ~because:"policy: ask" ~keeper_name:keeper
              ~tool_call_id:"call-1" ~timeout_sec:5.0)
          (fun () ->
            let rec wait_for_registration attempts =
              if Registry.pending registry = [] && attempts > 0 then begin
                Eio.Time.sleep clock 0.005;
                wait_for_registration (attempts - 1)
              end
            in
            wait_for_registration 100;
            ignore
              (Registry.settle registry ~keeper_name:keeper
                 ~tool_call_id:"call-1" Registry.Approve))
        |> fst
      in
      check (option string) "the wait was answered" (Some "approved")
        (match result with
         | Registry.Answered Registry.Approve -> Some "approved"
         | _ -> None);
      check outcome_totals "the answer is the answered count"
        { Registry.answered_total = 1; timed_out_total = 0 } (totals registry))

let test_a_timeout_counted_as_a_timeout () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let result =
        Registry.await registry ~clock ~tool_name:"Execute" ~args:"{}"
                ~question:"run?" ~because:"policy: ask" ~keeper_name:keeper
          ~tool_call_id:"call-2" ~timeout_sec:0.05
      in
      check bool "the wait ended on the timer" true (result = Registry.Timed_out);
      check outcome_totals "the timer is the timed_out count"
        { Registry.answered_total = 0; timed_out_total = 1 } (totals registry))

let test_a_settle_racing_the_timeout_is_the_answer_it_counts () =
  Eio_mock.Backend.run (fun () ->
      let clock = Eio_mock.Clock.make () in
      Eio_mock.Clock.set_time clock 0.0;
      let registry = Registry.create () in
      Eio.Switch.run (fun sw ->
          let waited =
            Eio.Fiber.fork_promise ~sw (fun () ->
                Registry.await registry ~clock ~tool_name:"Execute" ~args:"{}"
                  ~question:"run?" ~because:"policy: ask" ~keeper_name:keeper
                  ~tool_call_id:"call-3" ~timeout_sec:1.0)
          in
          Eio_mock.Clock.set_time clock 1.0;
          check bool "the late answer applies" true
            (Registry.settle registry ~keeper_name:keeper
               ~tool_call_id:"call-3" Registry.Approve);
          ignore (Eio.Promise.await_exn waited);
          (* The operator's decision reached the call even though the timer
             fired first: the answered count is where this lands, never
             timed_out (the gate's own rule for this race). *)
          check outcome_totals "the race counts as answered"
            { Registry.answered_total = 1; timed_out_total = 0 } (totals registry)))

let test_a_failed_settle_counts_nothing () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      check bool "nothing was waiting" false
        (Registry.settle registry ~keeper_name:keeper ~tool_call_id:"nope"
           Registry.Approve);
      check outcome_totals "an answer to nobody counts nothing"
        { Registry.answered_total = 0; timed_out_total = 0 } (totals registry))

let () =
  run
    "keeper_tool_approval_registry_outcomes"
    [ ( "outcome totals"
      , [ test_case "a fresh registry counts nothing" `Quick
            test_new_registry_counts_nothing
        ; test_case "an answer is counted once" `Quick
            test_an_answer_counted_once
        ; test_case "a timeout is counted as a timeout" `Quick
            test_a_timeout_counted_as_a_timeout
        ; test_case
            "a settle racing the timeout is the answer it counts" `Quick
            test_a_settle_racing_the_timeout_is_the_answer_it_counts
        ; test_case "a failed settle counts nothing" `Quick
            test_a_failed_settle_counts_nothing
        ] )
    ]
