open Alcotest

let settle_fixture registry ~keeper_name ~tool_call_id decision =
  let approval_id =
    match List.find_opt (fun (row : Masc.Keeper_tool_approval_registry.pending) ->
      String.equal row.keeper_name keeper_name && String.equal row.tool_call_id tool_call_id)
      (Masc.Keeper_tool_approval_registry.pending registry) with
    | Some row -> row.approval_id
    | None -> Masc.Keeper_tool_approval_id.fresh ()
  in
  Masc.Keeper_tool_approval_registry.settle registry ~keeper_name ~approval_id decision


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
            Registry.await ~approval_id:(Masc.Keeper_tool_approval_id.fresh ()) registry ~clock ~tool_name:"Execute" ~args:"{}"
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
              (settle_fixture registry ~keeper_name:keeper
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
        Registry.await ~approval_id:(Masc.Keeper_tool_approval_id.fresh ()) registry ~clock ~tool_name:"Execute" ~args:"{}"
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
                Registry.await ~approval_id:(Masc.Keeper_tool_approval_id.fresh ()) registry ~clock ~tool_name:"Execute" ~args:"{}"
                  ~question:"run?" ~because:"policy: ask" ~keeper_name:keeper
                  ~tool_call_id:"call-3" ~timeout_sec:1.0)
          in
          Eio_mock.Clock.set_time clock 1.0;
          check bool "the late answer applies" true
            (settle_fixture registry ~keeper_name:keeper
               ~tool_call_id:"call-3" Registry.Approve);
          check bool "successful receipt matches the wait outcome" true
            (Eio.Promise.await_exn waited = Registry.Answered Registry.Approve);
          (* The operator's decision reached the call even though the timer
             fired first: the answered count is where this lands, never
             timed_out (the gate's own rule for this race). *)
          check outcome_totals "the race counts as answered"
            { Registry.answered_total = 1; timed_out_total = 0 } (totals registry)))

let test_timeout_claim_rejects_a_later_answer () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let registry = Registry.create () in
    Eio.Switch.run (fun sw ->
      let waited = Eio.Fiber.fork_promise ~sw (fun () ->
        Registry.await ~approval_id:(Masc.Keeper_tool_approval_id.fresh ())
          registry ~clock ~keeper_name:keeper ~tool_call_id:"timeout-claimed"
          ~tool_name:"Execute" ~args:"{}" ~question:"run?" ~because:"policy"
          ~timeout_sec:1.0) in
      Eio_mock.Clock.set_time clock 1.0;
      check bool "timer publishes timeout" true
        (Eio.Promise.await_exn waited = Registry.Timed_out);
      check bool "later answer is not applied" false
        (settle_fixture registry ~keeper_name:keeper
          ~tool_call_id:"timeout-claimed" Registry.Approve);
      check outcome_totals "one terminal outcome is counted"
        { Registry.answered_total = 0; timed_out_total = 1 } (totals registry)))

let test_old_admission_cannot_answer_reused_provider_call () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let registry = Registry.create () in
    let first_id = Masc.Keeper_tool_approval_id.fresh () in
    let second_id = Masc.Keeper_tool_approval_id.fresh () in
    let wait approval_id = Registry.await registry ~approval_id ~clock
      ~keeper_name:keeper ~tool_call_id:"provider-reused" ~tool_name:"Execute"
      ~args:"{}" ~question:"run?" ~because:"policy" ~timeout_sec:10.0 in
    Eio.Switch.run (fun sw ->
      let first = Eio.Fiber.fork_promise ~sw (fun () -> wait first_id) in
      let second = Eio.Fiber.fork_promise ~sw (fun () -> wait second_id) in
      check bool "older admission is displaced" true
        (Eio.Promise.await_exn first = Registry.Displaced);
      check bool "older answer cannot approve replacement" false
        (Registry.settle registry ~keeper_name:keeper ~approval_id:first_id Registry.Approve);
      check int "replacement remains pending" 1 (List.length (Registry.pending registry));
      check bool "current admission is approved" true
        (Registry.settle registry ~keeper_name:keeper ~approval_id:second_id Registry.Approve);
      check bool "replacement receives its own decision" true
        (Eio.Promise.await_exn second = Registry.Answered Registry.Approve)))

let test_answer_waits_for_timeout_publication () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let registry = Registry.create () in
    let approval_id = Masc.Keeper_tool_approval_id.fresh () in
    let publishing, announce = Eio.Promise.create () in
    let release, finish = Eio.Promise.create () in
    let published = ref false in
    let answer_finished = ref false in
    Eio.Switch.run (fun sw ->
      let waited = Eio.Fiber.fork_promise ~sw (fun () ->
        Registry.await ~on_timed_out:(fun () ->
          Eio.Promise.resolve announce ();
          Eio.Promise.await release;
          published := true)
          registry ~approval_id ~clock ~keeper_name:keeper ~tool_call_id:"handoff-call"
          ~tool_name:"Execute" ~args:"{}" ~question:"run?" ~because:"policy"
          ~timeout_sec:1.0) in
      Eio_mock.Clock.set_time clock 1.0;
      Eio.Promise.await publishing;
      check int "timed-out ask is no longer actionable" 0 (List.length (Registry.pending registry));
      let answer = Eio.Fiber.fork_promise ~sw (fun () ->
        let settled = Registry.settle registry ~keeper_name:keeper ~approval_id Registry.Approve in
        answer_finished := true;
        check bool "fallback sees completed publication" true !published;
        settled) in
      Eio.Fiber.yield ();
      check bool "concurrent answer waits for publication" false !answer_finished;
      Eio.Promise.resolve finish ();
      check bool "timeout cannot report an immediate approval" false (Eio.Promise.await_exn answer);
      check bool "wait completes after publication" true
        (Eio.Promise.await_exn waited = Registry.Timed_out)))

let test_a_failed_settle_counts_nothing () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      check bool "nothing was waiting" false
        (settle_fixture registry ~keeper_name:keeper ~tool_call_id:"nope"
           Registry.Approve);
      check outcome_totals "an answer to nobody counts nothing"
        { Registry.answered_total = 0; timed_out_total = 0 } (totals registry))

let test_failed_registration_publication_removes_the_wait () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      check_raises "publication failure propagates" Exit (fun () ->
        ignore (Registry.await ~approval_id:(Masc.Keeper_tool_approval_id.fresh ()) ~on_registered:(fun () -> raise Exit) registry
          ~clock ~tool_name:"Execute" ~args:"{}" ~question:"run?"
          ~because:"policy" ~keeper_name:keeper ~tool_call_id:"publish-failed"
          ~timeout_sec:5.0));
      check int "failed publication leaves no held wait" 0
        (List.length (Registry.pending registry)))

let test_reused_provider_call_has_a_new_admission_identity () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let admit () =
        let observed = ref None in
        let outcome = Registry.await ~approval_id:(Masc.Keeper_tool_approval_id.fresh ()) registry ~clock ~keeper_name:keeper
          ~tool_call_id:"provider-reused-call" ~tool_name:"Execute" ~args:"{}"
          ~question:"run?" ~because:"policy" ~timeout_sec:5.0
          ~on_registered:(fun () ->
            match Registry.pending registry with
            | [pending] ->
                observed := Some pending.Registry.approval_id;
                check bool "answer reaches registered wait" true
                  (settle_fixture registry ~keeper_name:keeper
                    ~tool_call_id:"provider-reused-call" Registry.Approve)
            | _ -> fail "expected the current admission") in
        check bool "admission was answered" true
          (outcome = Registry.Answered Registry.Approve);
        match !observed with
        | Some id -> id
        | None -> fail "registration callback did not observe admission"
      in
      let first = admit () in
      let second = admit () in
      check bool "same provider call ID has distinct registry admissions" false
        (Masc.Keeper_tool_approval_id.equal first second))

let () =
  run
    "keeper_tool_approval_registry_outcomes"
    [ ( "outcome totals"
      , [ test_case "answer waits for timeout publication" `Quick
            test_answer_waits_for_timeout_publication
        ; test_case "old admission cannot answer reused provider call" `Quick
            test_old_admission_cannot_answer_reused_provider_call
        ; test_case "timeout claim rejects a later answer" `Quick
            test_timeout_claim_rejects_a_later_answer
        ; test_case "provider call reuse has a new admission identity" `Quick
            test_reused_provider_call_has_a_new_admission_identity
        ; test_case "failed registration publication removes the wait" `Quick
            test_failed_registration_publication_removes_the_wait
        ; test_case "a fresh registry counts nothing" `Quick
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
