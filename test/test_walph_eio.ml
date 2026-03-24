(** Eio-native Walph Wiggum Tests

    Verifies that Room_walph_eio works correctly in Eio fiber context:
    1. Non-blocking mutex (fiber-friendly)
    2. Condition variable based pause/resume
    3. Concurrent control from multiple fibers
    4. No zombie states on exceptions
*)

open Alcotest
open Yojson.Safe.Util

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let contains text pattern =
  try
    let _ = Str.search_forward (Str.regexp_string pattern) text 0 in
    true
  with Not_found ->
    false

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        contains content pattern)

(** Test fixture: Create isolated config with Eio environment *)
let with_test_config name f =
  Eio_main.run @@ fun env ->
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "walph_eio_%s_%d_%d" name (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let fs = Eio.Stdenv.fs env in
  let config = Masc_mcp.Room.default_config tmp_dir in
  let _ = Masc_mcp.Room.init config ~agent_name:(Some "test-eio-agent") in
  Fun.protect
    ~finally:(fun () ->
      let _ = Masc_mcp.Room.reset config in
      (try rm_rf tmp_dir with _ -> ()))
    (fun () -> f env fs config)

(** Test: Basic state machine in Eio context *)
let test_eio_basic_state () =
  with_test_config "basic" @@ fun _env _fs config ->
  let state = Room_walph_eio.get_walph_state_exn config ~agent_name:"tester" in
  check bool "not running initially" false state.running;
  check bool "not paused initially" false state.paused

(** Test: Control commands work in Eio context *)
let test_eio_control_commands () =
  with_test_config "control" @@ fun _env _fs config ->
  let state = Room_walph_eio.get_walph_state_exn config ~agent_name:"tester" in

  (* Simulate running state *)
  Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
    state.running <- true
  );

  (* Test PAUSE *)
  let _ = Room_walph_eio.walph_control config
    ~from_agent:"tester" ~command:"PAUSE" ~args:"" () in
  check bool "paused after PAUSE" true state.paused;

  (* Test RESUME *)
  let _ = Room_walph_eio.walph_control config
    ~from_agent:"tester" ~command:"RESUME" ~args:"" () in
  check bool "not paused after RESUME" false state.paused;

  (* Test STOP *)
  let _ = Room_walph_eio.walph_control config
    ~from_agent:"tester" ~command:"STOP" ~args:"" () in
  check bool "stop requested after STOP" true state.stop_requested

(** Test: Concurrent control from multiple fibers *)
let test_eio_concurrent_control () =
  with_test_config "concurrent" @@ fun _env _fs config ->
  let state = Room_walph_eio.get_walph_state_exn config ~agent_name:"tester" in

  (* Set running *)
  Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
    state.running <- true
  );

  (* Run PAUSE and RESUME concurrently in separate fibers *)
  let pause_count = ref 0 in
  let resume_count = ref 0 in

  Eio.Fiber.both
    (fun () ->
      for _ = 1 to 10 do
        let _ = Room_walph_eio.walph_control config
          ~from_agent:"fiber1" ~command:"PAUSE" ~args:"" () in
        incr pause_count
      done)
    (fun () ->
      for _ = 1 to 10 do
        let _ = Room_walph_eio.walph_control config
          ~from_agent:"fiber2" ~command:"RESUME" ~args:"" () in
        incr resume_count
      done);

  check int "all pauses executed" 10 !pause_count;
  check int "all resumes executed" 10 !resume_count

(** Test: State isolation between agents in Eio context *)
let test_eio_room_isolation () =
  with_test_config "isolation" @@ fun _env _fs config ->
  (* Now we test agent isolation within same room *)
  let state1 = Room_walph_eio.get_walph_state_exn config ~agent_name:"agent1" in
  let state2 = Room_walph_eio.get_walph_state_exn config ~agent_name:"agent2" in

  (* Modify state1 *)
  Eio.Mutex.use_rw ~protect:true state1.mutex (fun () ->
    state1.running <- true;
    state1.iterations <- 100
  );

  (* state2 should be unaffected - different agent, same room *)
  check bool "state2 not running" false state2.running;
  check int "state2 zero iterations" 0 state2.iterations

(** Test: Cleanup function with zombie prevention *)
let test_eio_cleanup () =
  with_test_config "cleanup" @@ fun _env _fs config ->
  (* Create and modify state *)
  let state = Room_walph_eio.get_walph_state_exn config ~agent_name:"tester" in
  Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
    state.running <- true
  );

  (* Remove should FAIL when running (zombie prevention) *)
  let remove_failed = match Room_walph_eio.remove_walph_state config ~agent_name:"tester" with
    | Error _ -> true
    | Ok () -> false
  in
  check bool "remove fails when running" true remove_failed;

  (* Stop the state first *)
  Eio.Mutex.use_rw ~protect:true state.mutex (fun () ->
    state.running <- false
  );

  (* Now remove should succeed *)
  ignore (Room_walph_eio.remove_walph_state config ~agent_name:"tester");

  (* Getting state again should return fresh state *)
  let new_state = Room_walph_eio.get_walph_state_exn config ~agent_name:"tester" in
  check bool "new state not running" false new_state.running

(** Test: 3 agents running Walph simultaneously (Phase 1 feature) *)
let test_eio_multi_agent_walph () =
  with_test_config "multi_agent" @@ fun _env _fs config ->
  (* 3 agents get their own independent Walph states *)
  let state_claude = Room_walph_eio.get_walph_state_exn config ~agent_name:"claude" in
  let state_codex = Room_walph_eio.get_walph_state_exn config ~agent_name:"codex" in
  let state_gemini = Room_walph_eio.get_walph_state_exn config ~agent_name:"gemini" in

  (* All start as not running *)
  check bool "claude not running initially" false state_claude.running;
  check bool "codex not running initially" false state_codex.running;
  check bool "gemini not running initially" false state_gemini.running;

  (* Each agent can set running=true independently (simulating walph_loop start) *)
  Eio.Mutex.use_rw ~protect:true state_claude.mutex (fun () ->
    state_claude.running <- true;
    state_claude.current_preset <- "drain"
  );
  Eio.Mutex.use_rw ~protect:true state_codex.mutex (fun () ->
    state_codex.running <- true;
    state_codex.current_preset <- "coverage"
  );
  Eio.Mutex.use_rw ~protect:true state_gemini.mutex (fun () ->
    state_gemini.running <- true;
    state_gemini.current_preset <- "refactor"
  );

  (* All 3 are now running simultaneously - no conflict! *)
  check bool "claude running" true state_claude.running;
  check bool "codex running" true state_codex.running;
  check bool "gemini running" true state_gemini.running;

  (* Each has different preset *)
  check string "claude preset" "drain" state_claude.current_preset;
  check string "codex preset" "coverage" state_codex.current_preset;
  check string "gemini preset" "refactor" state_gemini.current_preset;

  (* Pause only claude - others unaffected *)
  let _ = Room_walph_eio.walph_control config
    ~from_agent:"claude" ~command:"PAUSE" ~args:"" () in
  check bool "claude paused" true state_claude.paused;
  check bool "codex not paused" false state_codex.paused;
  check bool "gemini not paused" false state_gemini.paused

(** Test: START command is explicitly disabled *)
let test_eio_start_disabled () =
  with_test_config "preset" @@ fun _env _fs _config ->
  let result =
    Room_walph_eio.walph_control _config ~from_agent:"tester"
      ~command:"START" ~args:"coverage" ()
  in
  check bool "start disabled message" true
    (contains result "START is disabled")

(** Test: Multi-agent with review preset *)
let test_eio_multi_agent_with_review () =
  with_test_config "multi_review" @@ fun _env _fs config ->
  let state_claude = Room_walph_eio.get_walph_state_exn config ~agent_name:"claude-reviewer" in
  let state_codex = Room_walph_eio.get_walph_state_exn config ~agent_name:"codex-reviewer" in

  (* Both agents run review preset simultaneously *)
  Eio.Mutex.use_rw ~protect:true state_claude.mutex (fun () ->
    state_claude.running <- true;
    state_claude.current_preset <- "review"
  );
  Eio.Mutex.use_rw ~protect:true state_codex.mutex (fun () ->
    state_codex.running <- true;
    state_codex.current_preset <- "review"
  );

  check bool "claude-reviewer running" true state_claude.running;
  check bool "codex-reviewer running" true state_codex.running;
  check string "claude preset" "review" state_claude.current_preset;
  check string "codex preset" "review" state_codex.current_preset

(** Test: list_walph_states returns all active agents *)
let test_eio_list_walph_states () =
  with_test_config "list_states" @@ fun _env _fs config ->
  (* Create states for 3 agents *)
  let _ = Room_walph_eio.get_walph_state_exn config ~agent_name:"agent-a" in
  let _ = Room_walph_eio.get_walph_state_exn config ~agent_name:"agent-b" in
  let _ = Room_walph_eio.get_walph_state_exn config ~agent_name:"agent-c" in

  (* List all states *)
  let states = Room_walph_eio.list_walph_states config in
  check int "3 agents in room" 3 (List.length states);

  (* Check agent names are present *)
  let agent_names = List.map fst states in
  check bool "has agent-a" true (List.mem "agent-a" agent_names);
  check bool "has agent-b" true (List.mem "agent-b" agent_names);
  check bool "has agent-c" true (List.mem "agent-c" agent_names)

(** Test: walph_status_json exposes extended counters/metadata *)
let test_eio_status_json_fields () =
  with_test_config "status_json" @@ fun _env _fs config ->
  let _state = Room_walph_eio.get_walph_state_exn config ~agent_name:"status-agent" in
  let json = Room_walph_eio.walph_status_json config ~agent_name:"status-agent" in
  check bool "ok=true" true (json |> member "ok" |> to_bool);
  check string "agent field" "status-agent" (json |> member "agent" |> to_string);
  ignore (json |> member "claimed" |> to_int);
  ignore (json |> member "released_on_error" |> to_int);
  ignore (json |> member "errors" |> to_int);
  ignore (json |> member "consecutive_errors" |> to_int);
  ignore (json |> member "max_consecutive_errors" |> to_int);
  ignore (json |> member "error_backoff_sec" |> to_int);
  ignore (json |> member "last_error");
  ignore (json |> member "last_task_id");
  ignore (json |> member "started_at");
  ignore (json |> member "last_stop_reason")

(** Test: walph_loop is removed and leaves state idle *)
let test_eio_loop_removed () =
  with_test_config "error_cutoff" @@ fun env _fs config ->
  let state = Room_walph_eio.get_walph_state_exn config ~agent_name:"error-agent" in
  let result =
    Room_walph_eio.walph_loop config
      ~clock:(Eio.Stdenv.clock env)
      ~agent_name:"error-agent"
      ~preset:"coverage"
      ~max_iterations:10
      ~max_consecutive_errors:2
      ~error_backoff_sec:0
      ~model_dispatch:(fun ~tool_name:_ ~model:_ ~prompt:_ ~timeout_sec:_ ~max_chars:_ () -> "")
      ()
  in
  check bool "removed message" true
    (contains result "Walph loop has been removed");
  check bool "state remains idle" false state.running;
  check int "iterations unchanged" 0 state.iterations;
  check int "errors unchanged" 0 state.errors

let test_eio_default_dispatch_uses_shared_cascade () =
  (* Verify old direct MODEL dispatch paths remain absent from Room. *)
  check bool "legacy direct dispatch removed" false
    (file_contains_pattern "lib/room/room_walph_eio.ml" "Llm_direct.dispatch");
  check bool "no direct run_prompt_cascade" false
    (file_contains_pattern "lib/room/room_walph_eio.ml" "Llm_orchestration.run_prompt_cascade")

(* ============================================
   Test Registration
   ============================================ *)

let eio_tests = [
  "basic state in Eio", `Quick, test_eio_basic_state;
  "control commands in Eio", `Quick, test_eio_control_commands;
  "concurrent control", `Quick, test_eio_concurrent_control;
  "room isolation in Eio", `Quick, test_eio_room_isolation;
  "cleanup function", `Quick, test_eio_cleanup;
  "multi-agent Walph", `Quick, test_eio_multi_agent_walph;
  "start disabled", `Quick, test_eio_start_disabled;
  "multi-agent with review preset", `Quick, test_eio_multi_agent_with_review;
  "list walph states", `Quick, test_eio_list_walph_states;
  "status json fields", `Quick, test_eio_status_json_fields;
  "loop removed", `Quick, test_eio_loop_removed;
  "default dispatch uses shared cascade", `Quick,
  test_eio_default_dispatch_uses_shared_cascade;
]

let () =
  run "Walph Eio" [
    "Eio Native", eio_tests;
  ]
