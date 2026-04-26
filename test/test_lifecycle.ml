(** Test Shutdown + Supervisor modules *)

open Masc_mcp

let passed = ref 0
let failed = ref 0

let test name fn =
  try
    fn ();
    incr passed;
    Printf.printf "  PASS  %s\n%!" name
  with
  | e ->
    incr failed;
    Printf.printf "  FAIL  %s: %s\n%!" name (Printexc.to_string e)
;;

(* ══════════════════════════════════════════════════════════════
   Shutdown tests
   ══════════════════════════════════════════════════════════════ *)

let () =
  test "shutdown phases execute in order" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let phases_seen = ref [] in
    let config =
      Shutdown.
        { notify_delay_s = 0.01
        ; drain_timeout_s = 0.05
        ; cleanup_timeout_s = 0.1
        ; force_timeout_s = 60.0
        }
    in
    let state = Shutdown.create ~config () in
    Shutdown.register ~name:"phase-tracker" ~priority:10 (fun () ->
      phases_seen := "cleanup" :: !phases_seen);
    let notify_called = ref false in
    let exit_called = ref false in
    Shutdown.initiate
      state
      ~clock
      ~reason:"test"
      ~notify_fn:(fun _reason -> notify_called := true)
      ~drain_check:(fun () -> true)
      ~exit_fn:(fun () -> exit_called := true);
    assert !notify_called;
    assert !exit_called;
    assert (List.mem "cleanup" !phases_seen);
    assert (Shutdown.current_phase state = Shutdown.Done))
;;

let () =
  test "shutdown is_shutting_down during execution" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let config =
      Shutdown.
        { notify_delay_s = 0.0
        ; drain_timeout_s = 0.0
        ; cleanup_timeout_s = 1.0
        ; force_timeout_s = 60.0
        }
    in
    let state = Shutdown.create ~config () in
    assert (not (Shutdown.is_shutting_down state));
    let saw_shutting_down = ref false in
    Shutdown.register ~name:"check-phase" ~priority:10 (fun () ->
      saw_shutting_down := Shutdown.is_shutting_down state);
    Shutdown.initiate
      state
      ~clock
      ~reason:"test2"
      ~notify_fn:(fun _ -> ())
      ~drain_check:(fun () -> true)
      ~exit_fn:(fun () -> ());
    assert !saw_shutting_down)
;;

let () =
  test "shutdown ignores duplicate initiate" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let config =
      Shutdown.
        { notify_delay_s = 0.0
        ; drain_timeout_s = 0.0
        ; cleanup_timeout_s = 1.0
        ; force_timeout_s = 60.0
        }
    in
    let state = Shutdown.create ~config () in
    let count = ref 0 in
    Shutdown.register ~name:"counter" ~priority:10 (fun () -> incr count);
    Shutdown.initiate
      state
      ~clock
      ~reason:"first"
      ~notify_fn:(fun _ -> ())
      ~drain_check:(fun () -> true)
      ~exit_fn:(fun () -> ());
    Shutdown.initiate
      state
      ~clock
      ~reason:"second"
      ~notify_fn:(fun _ -> ())
      ~drain_check:(fun () -> true)
      ~exit_fn:(fun () -> ());
    assert (!count = 1))
;;

(* ══════════════════════════════════════════════════════════════
   Supervisor tests
   ══════════════════════════════════════════════════════════════ *)

let () =
  test "supervisor starts permanent children" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let started = ref false in
    let spec =
      Supervisor.child
        ~name:"worker"
        ~start:(fun () -> started := true)
        ~strategy:Permanent
        ()
    in
    let sup = Supervisor.create [ spec ] in
    Eio.Switch.run
    @@ fun sw ->
    Supervisor.start ~sw ~clock sup;
    Eio.Time.sleep clock 0.1;
    assert !started;
    let statuses = Supervisor.status sup in
    assert (List.length statuses = 1);
    assert ((List.hd statuses).name = "worker"))
;;

let () =
  test "supervisor temporary child not restarted" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let call_count = ref 0 in
    let spec =
      Supervisor.child
        ~name:"temp"
        ~start:(fun () ->
          incr call_count;
          failwith "boom")
        ~strategy:Temporary
        ()
    in
    let sup = Supervisor.create [ spec ] in
    Eio.Switch.run
    @@ fun sw ->
    Supervisor.start ~sw ~clock sup;
    Eio.Time.sleep clock 0.5;
    (* Temporary children are not restarted *)
    assert (!call_count = 1))
;;

let () =
  test "supervisor status JSON serialization" (fun () ->
    let s : Supervisor.child_status =
      { name = "test"
      ; running = true
      ; disabled = false
      ; restart_count = 2
      ; strategy = "permanent"
      }
    in
    let json = Supervisor.status_to_json s in
    match json with
    | `Assoc fields ->
      assert (List.assoc_opt "name" fields = Some (`String "test"));
      assert (List.assoc_opt "running" fields = Some (`Bool true));
      assert (List.assoc_opt "restart_count" fields = Some (`Int 2))
    | _ -> failwith "expected Assoc")
;;

let () =
  test "supervisor permanent child restarts on failure" (fun () ->
    Eio_main.run
    @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let call_count = ref 0 in
    let spec =
      Supervisor.child
        ~name:"crasher"
        ~start:(fun () ->
          incr call_count;
          if !call_count <= 2 then failwith "crash" (* 3rd call succeeds *))
        ~strategy:Permanent
        ~max_restarts:5
        ~restart_window_s:60.0
        ()
    in
    let sup = Supervisor.create [ spec ] in
    Eio.Switch.run
    @@ fun sw ->
    Supervisor.start ~sw ~clock sup;
    (* Wait for restarts: 1s delay for 1st restart, 2s for 2nd *)
    Eio.Time.sleep clock 5.0;
    assert (!call_count >= 3))
;;

(* ── Summary ──────────────────────────────────── *)

let () =
  Printf.printf "\nLifecycle tests: %d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
;;
