(* test/test_supervisor_isolation.ml *)

open Alcotest

let eio_test name fn =
  test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    fn (Eio.Stdenv.clock env) ())

let test_isolation clock () =
  let child1_run = ref false in
  let child2_run = ref false in
  let child2_cancelled = ref false in

  let start_child1 () =
    child1_run := true;
    while true do
      Eio.Time.sleep clock 0.05
    done
  in

  let start_child2 () =
    child2_run := true;
    child2_cancelled := true;
    (* Raise Cancelled to simulate child scope cancellation *)
    raise (Eio.Cancel.Cancelled Exit)
  in

  let spec1 = Masc.Supervisor.child ~name:"child1" ~start:start_child1 () in
  let spec2 = Masc.Supervisor.child ~name:"child2" ~start:start_child2 ~strategy:Temporary () in
  let t = Masc.Supervisor.create [spec1; spec2] in

  try
    Eio.Switch.run (fun sw ->
      Masc.Supervisor.start ~sw ~clock t;
      (* Give child1 some time to yield and run *)
      Eio.Time.sleep clock 0.15;

      (* Verify child1 ran *)
      Alcotest.(check bool) "child1 is running" true !child1_run;
      Alcotest.(check bool) "child2 ran" true !child2_run;
      Alcotest.(check bool) "child2 cancelled" true !child2_cancelled;

      (* Check status in supervisor: child1 should still be running!
         If the cancellation propagated and cancelled the parent switch,
         we wouldn't even reach this assertion because Eio.Switch.run would throw. *)
      let status = Masc.Supervisor.status t in
      let child1_status = List.find (fun (s : Masc.Supervisor.child_status) -> String.equal s.name "child1") status in
      Alcotest.(check bool) "child1 is still running status" true child1_status.running;

      (* Explicitly fail the switch so the test block terminates *)
      Eio.Switch.fail sw Exit
    )
  with Exit -> ()

let () =
  Alcotest.run "supervisor_isolation" [
    "isolation", [
      eio_test "child_cancel_isolation" test_isolation;
    ]
  ]
