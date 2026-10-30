(* Shutdown finalization is the only place that knows a keeper is gone for
   good: the microvm lane keeps one guest per keeper across turns, so turn
   teardown deliberately leaves it running. Before this was wired, removing a
   keeper left ~400 MB of guest behind for somebody to find by hand.

   Two properties hold it. The first is that finalization calls the teardown
   at all -- deleting the call is the regression, and no other suite would
   notice. The second is that finalization carries the declared backend so a
   Local keeper never probes microVM or Docker runtimes it cannot own. *)

module Runtime = Masc.Keeper_turn_sandbox_runtime

(* Every keeper goes through finalization, and only microvm keepers have a
   guest. If an absent guest were an error the shutdown would block on it, so
   this pins that removing nothing succeeds -- run against a name that has
   never had a guest. Absence is what the runtime's listing says, so the
   [container] on PATH is a fake whose inspect and listing both report no
   guest: the host's own CLI, or a host without one, would decide the case
   instead. *)
let test_removing_an_absent_guest_succeeds () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let previous_fs = Fs_compat.get_fs_opt () in
  let context = Eio_context.snapshot_state () in
  Fs_compat.set_fs fs;
  Process_eio.init ~cwd_default:Eio.Path.(fs / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:(fun () ->
    Process_eio.reset_for_testing ();
    Eio_context.restore_state context;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
  @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.set_switch sw;
  let base_path = Filename.temp_dir "microvm_teardown_" "" in
  let cli = Filename.concat base_path "container" in
  let calls_path = Filename.concat base_path "calls" in
  let config = Masc.Workspace.default_config base_path in
  let keeper_name = "microvm-teardown-probe-never-started" in
  Out_channel.with_open_bin cli (fun channel ->
    Printf.fprintf channel {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$1" in
  stop|delete) exit 0 ;;
  inspect) exit 1 ;;
  list) printf '[]\n' ;;
  volume) if [ "$2" = list ]; then printf '[]\n'; fi; exit 0 ;;
  *) exit 99 ;;
esac
|} (Filename.quote calls_path));
  Unix.chmod cli 0o700;
  let previous_path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (base_path ^ ":" ^ previous_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" previous_path;
      Fs_compat.remove_tree base_path)
    (fun () ->
       (match Runtime.teardown_keeper_sandbox_by_name ~timeout_sec:30. ~config
           ~keeper_name ~backend:Masc.Keeper_sandbox.Micro_vm
           ~microvm_backend:Masc.Keeper_microvm_backend.Apple_container () with
        | Ok () -> ()
        | Error detail -> Alcotest.failf
            "removing a guest that was never started must succeed, got: %s" detail);
       let calls = In_channel.with_open_bin calls_path In_channel.input_all
           |> String.split_on_char '\n' |> List.filter (fun call -> call <> "") in
       Alcotest.(check bool) "actual complete inventory establishes absence" true
         (List.mem "list --all --format json" calls);
       List.iter (fun network_mode ->
         let guest = Runtime.For_testing_microvm.microvm_container_name ~config ~keeper_name ~network_mode in
         Alcotest.(check bool) ("actual inspect reached " ^ guest) true
           (List.mem ("inspect " ^ guest) calls))
         Keeper_types_profile_sandbox.all_network_modes;
       let rec unanswered_inspects_have_inventory = function
         | inspect :: inventory :: rest when String.starts_with ~prefix:"inspect " inspect ->
           String.equal inventory "list --all --format json"
           && unanswered_inspects_have_inventory (inventory :: rest)
         | [inspect] when String.starts_with ~prefix:"inspect " inspect -> false
         | _ :: rest -> unanswered_inspects_have_inventory rest
         | [] -> true in
       Alcotest.(check bool) "a complete inventory immediately follows each unanswered inspect" true
         (unanswered_inspects_have_inventory calls);
       Alcotest.(check bool) "confirmed absent guests are not stopped or deleted" false
         (List.exists (fun call -> String.starts_with ~prefix:"stop " call
           || String.starts_with ~prefix:"delete " call) calls);
       Out_channel.with_open_bin calls_path (fun _ -> ());
       let remove_volumes () = Runtime.remove_keeper_volumes_by_name ~timeout_sec:30.
           ~keeper_name ~backend:Masc.Keeper_sandbox.Micro_vm
           ~microvm_backend:Masc.Keeper_microvm_backend.Apple_container () in
       (match remove_volumes () with
        | Ok () -> Alcotest.fail "an unowned shared volume was reported removed"
        | Error detail -> Alcotest.(check bool) "unverified ownership is named" true
            (Astring.String.is_infix ~affix:"microvm_volume_removal_owner_unverified" detail));
       let calls = In_channel.with_open_bin calls_path In_channel.input_all in
       Alcotest.(check string) "no CLI calls for unverified ownership" "" calls)
;;

(* A caller that forgets the runtime gets a refusal, not a guess. Shutdown
   finalization treats a teardown failure as a warning and finishes, so an
   assumed runtime would report a removal it did not perform and the guest
   would stay running with nothing able to reap it. The refusal is what makes
   that mistake visible in the log instead. *)
let test_an_unnamed_runtime_is_refused () =
  let base_path = Filename.temp_file "microvm_teardown_unnamed_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir base_path with _ -> ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       match
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:0.01
           ~config
           ~keeper_name:"microvm-teardown-runtime-not-named"
           ~backend:Masc.Keeper_sandbox.Micro_vm
           ()
       with
       | Ok () ->
         Alcotest.fail "an unnamed microVM runtime reported a removal"
       | Error detail ->
         Alcotest.(check bool)
           "the refusal names the unresolved runtime"
           true
           (Astring.String.is_infix
              ~affix:"microvm_teardown_backend_unresolved"
              detail))

let test_local_teardown_skips_container_runtimes () =
  let base_path = Filename.temp_file "local_teardown_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir base_path with _ -> ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       match
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:0.01
           ~config
           ~keeper_name:"local-teardown-never-probes-container-runtime"
           ~backend:Masc.Keeper_sandbox.Remote_ssh
           ()
       with
       | Ok () -> ()
       | Error detail ->
         Alcotest.failf "Local teardown called a container runtime: %s" detail)

let test_failed_teardown_preserves_volumes () =
  let remove_calls = ref 0 in
  let remove () = incr remove_calls; Ok () in
  let cleanup = Masc.Keeper_shutdown_finalize.For_testing.remove_volumes_after_teardown in
  (match cleanup ~teardown:(Error "guest state unknown") ~remove with
   | Ok () -> Alcotest.fail "unknown teardown state permitted volume removal"
   | Error detail ->
     Alcotest.(check bool) "original teardown error remains visible" true
       (Astring.String.is_infix ~affix:"guest state unknown" detail));
  Alcotest.(check int) "failed teardown never invokes removal" 0 !remove_calls;
  (match cleanup ~teardown:(Ok ()) ~remove with
   | Error detail -> Alcotest.fail detail
   | Ok () -> ());
  Alcotest.(check int) "confirmed teardown permits removal" 1 !remove_calls
;;

let () =
  Alcotest.run
    "keeper_microvm_teardown_on_shutdown"
    [ ( "teardown"
      , [ Alcotest.test_case "removing an absent guest succeeds" `Quick
            test_removing_an_absent_guest_succeeds
        ; Alcotest.test_case "an unnamed microVM runtime is refused" `Quick
            test_an_unnamed_runtime_is_refused
        ; Alcotest.test_case "Local teardown skips container runtimes" `Quick
            test_local_teardown_skips_container_runtimes
        ; Alcotest.test_case "failed teardown preserves volumes" `Quick
            test_failed_teardown_preserves_volumes
        ] )
    ]
