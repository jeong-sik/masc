(* Unit tests for Masc_tui_server_lifecycle (RFC tui-server-lifecycle).
   The pure discovery/argv/health-wait logic is exercised deterministically
   with injected effects; start/stop spawns a real sleeper and reaps it so
   the alive/dead assertions do not race a zombie. *)

module L = Masc_tui_server_lifecycle

let discovery_testable =
  Alcotest.testable
    (fun ppf (d : L.discovery) ->
      match d with
      | L.Sibling p -> Format.fprintf ppf "Sibling %s" p
      | L.On_path p -> Format.fprintf ppf "On_path %s" p
      | L.Not_found { manual_command } ->
          Format.fprintf ppf "Not_found %s" manual_command)
    ( = )

let test_discover_prefers_sibling () =
  let d =
    L.discover_server_binary ~tui_exe:"/opt/masc/bin/masc-tui"
      ~file_exists:(fun p -> String.equal p "/opt/masc/bin/masc")
      ~path_lookup:(fun _ -> Some "/usr/local/bin/masc")
      ~base_path:"/ws" ~host:"127.0.0.1" ~port:8935
  in
  Alcotest.check discovery_testable "sibling wins over PATH"
    (L.Sibling "/opt/masc/bin/masc") d

let test_discover_falls_back_to_path () =
  let d =
    L.discover_server_binary ~tui_exe:"/opt/masc/bin/masc-tui"
      ~file_exists:(fun _ -> false)
      ~path_lookup:(fun name ->
        if String.equal name "masc" then Some "/usr/local/bin/masc" else None)
      ~base_path:"/ws" ~host:"127.0.0.1" ~port:8935
  in
  Alcotest.check discovery_testable "PATH used when no sibling"
    (L.On_path "/usr/local/bin/masc") d

let test_discover_not_found_carries_command () =
  let d =
    L.discover_server_binary ~tui_exe:"/opt/masc/bin/masc-tui"
      ~file_exists:(fun _ -> false)
      ~path_lookup:(fun _ -> None)
      ~base_path:"/ws" ~host:"0.0.0.0" ~port:9001
  in
  Alcotest.check discovery_testable "not found returns the manual command"
    (L.Not_found
       { manual_command = "masc start --base-path /ws --host 0.0.0.0 --port 9001" })
    d

let test_server_argv () =
  Alcotest.(check (list string))
    "argv has no shell interpolation"
    [ "/bin/masc"; "start"; "--base-path"; "/ws"; "--host"; "127.0.0.1"; "--port"; "8935" ]
    (L.server_argv ~masc_bin:"/bin/masc" ~base_path:"/ws" ~host:"127.0.0.1"
       ~port:8935)

let outcome_str = function
  | L.Ready -> "Ready"
  | L.Server_exited -> "Server_exited"
  | L.Timed_out n -> Printf.sprintf "Timed_out %d" n

let outcome_testable =
  Alcotest.testable
    (fun ppf o -> Format.pp_print_string ppf (outcome_str o))
    ( = )

let test_wait_ready_immediately () =
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> true)
      ~child_alive:(fun () -> true)
      ~attempts:5
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "ready without sleeping" L.Ready o;
  Alcotest.(check int) "never slept" 0 !slept

let test_wait_ready_on_third () =
  let n = ref 0 in
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () ->
        incr n;
        !n >= 3)
      ~child_alive:(fun () -> true)
      ~attempts:10
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "ready on third poll" L.Ready o;
  Alcotest.(check int) "slept between the three polls" 2 !slept

let test_wait_server_exited () =
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> false)
      ~child_alive:(fun () -> false)
      ~attempts:5
      ~sleep:(fun () -> ())
  in
  Alcotest.check outcome_testable "child death stops the wait" L.Server_exited o

let test_wait_times_out () =
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> false)
      ~child_alive:(fun () -> true)
      ~attempts:3
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "exhausts attempts" (L.Timed_out 3) o;
  Alcotest.(check int) "slept between attempts only" 2 !slept

let test_wait_zero_attempts () =
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> false)
      ~child_alive:(fun () -> true)
      ~attempts:0
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "no attempts times out at zero" (L.Timed_out 0)
    o;
  Alcotest.(check int) "never slept" 0 !slept

let test_start_stop_reaped () =
  let dir = Filename.temp_file "tui-lifecycle" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let script = Filename.concat dir "fake-masc" in
  let oc = open_out script in
  (* Ignores the server argv and just stays alive; exec keeps the pid the
     process-group leader so tree-kill and waitpid target it directly. *)
  output_string oc "#!/bin/sh\nexec sleep 30\n";
  close_out oc;
  Unix.chmod script 0o755;
  match
    L.start ~masc_bin:script ~base_path:dir ~host:"127.0.0.1" ~port:18999
      ~env:(Unix.environment ())
  with
  | Error e -> Alcotest.failf "start failed: %s" e
  | Ok owned ->
      let pgid = L.owned_pgid owned in
      (* The child sets its own process group after fork, so [-pgid] can lag
         the parent's return by a scheduler tick; poll briefly rather than
         race it. *)
      let rec await_alive tries =
        if Process_eio_detached.is_pgid_alive ~pgid then true
        else if tries <= 0 then false
        else (
          Unix.sleepf 0.05;
          await_alive (tries - 1))
      in
      Alcotest.(check bool)
        "owned server comes up after start" true (await_alive 40);
      L.stop owned ~grace_sec:0.3;
      let rec await_exit tries =
        if not (L.is_running owned) then true
        else if tries <= 0 then false
        else (
          Unix.sleepf 0.05;
          await_exit (tries - 1))
      in
      Alcotest.(check bool)
        "lifecycle observes and reaps the exited child" true (await_exit 40);
      Alcotest.(check bool)
        "reaped startup handle stays exited" false (L.is_running owned);
      Alcotest.(check bool)
        "owned server is gone after stop and reap" false
        (Process_eio_detached.is_pgid_alive ~pgid);
      (try Sys.remove script with Sys_error _ -> ());
      (try Unix.rmdir dir with Unix.Unix_error _ -> ())


(* Nothing answering is the only reading that calls for a server, and one
   spawn is the whole session's budget: a refresh also fails for reasons a new
   server would not fix, and a second masc on this port would only fail to
   bind.

   The reading, not the message, is what decides. A port with nothing on it
   refuses each request separately, so the refresh completes with every
   surface in error rather than throwing -- which is the shape a first install
   produces, and the shape that reached no server start while this was keyed
   on a thrown refresh instead. *)
let test_start_is_due_only_when_nothing_answered () =
  Alcotest.(check bool)
    "nothing answered starts one" true
    (L.start_due ~contact:L.Nothing_answered ~already_attempted:false);
  Alcotest.(check bool)
    "a second failed poll does not start another" false
    (L.start_due ~contact:L.Nothing_answered ~already_attempted:true);
  Alcotest.(check bool)
    "a server that answered needs none" false
    (L.start_due ~contact:L.Server_reached ~already_attempted:false);
  Alcotest.(check bool)
    "no reading yet starts nothing" false
    (L.start_due ~contact:L.Undecided ~already_attempted:false)

(* The command handed to an operator whose TUI could not find the binary has
   to start a server. Bare [masc] on a terminal is the front door and opens
   the TUI, so without [start] the advice loops the operator back to the
   screen they are already looking at. *)
let test_manual_command_starts_a_server () =
  match
    L.discover_server_binary ~tui_exe:"/nowhere/masc-tui"
      ~file_exists:(fun _ -> false)
      ~path_lookup:(fun _ -> None)
      ~base_path:"/ws" ~host:"127.0.0.1" ~port:8935
  with
  | L.Sibling _ | L.On_path _ -> Alcotest.fail "nothing should have been found"
  | L.Not_found { manual_command } ->
      Alcotest.(check string)
        "the manual command serves rather than opening the TUI"
        "masc start --base-path /ws --host 127.0.0.1 --port 8935"
        manual_command

let () =
  Alcotest.run "tui_server_lifecycle"
    [
      ( "discovery",
        [
          Alcotest.test_case "prefers sibling" `Quick test_discover_prefers_sibling;
          Alcotest.test_case "falls back to PATH" `Quick
            test_discover_falls_back_to_path;
          Alcotest.test_case "not found carries command" `Quick
            test_discover_not_found_carries_command;
        ] );
      ( "argv",
        [ Alcotest.test_case "exact argv" `Quick test_server_argv ] );
      ( "wait_healthy",
        [
          Alcotest.test_case "ready immediately" `Quick test_wait_ready_immediately;
          Alcotest.test_case "ready on third" `Quick test_wait_ready_on_third;
          Alcotest.test_case "server exited" `Quick test_wait_server_exited;
          Alcotest.test_case "times out" `Quick test_wait_times_out;
          Alcotest.test_case "zero attempts" `Quick test_wait_zero_attempts;
        ] );
      ( "start_due",
        [
          Alcotest.test_case "only when nothing answered" `Quick
            test_start_is_due_only_when_nothing_answered;
          Alcotest.test_case "the manual command starts a server" `Quick
            test_manual_command_starts_a_server;
        ] );
      ( "start_stop",
        [ Alcotest.test_case "start then stop is reaped" `Quick test_start_stop_reaped ]
      );
    ]
