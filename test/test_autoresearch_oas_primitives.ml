module Lib = Masc_mcp

open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

let contains haystack needle =
  let len_h = String.length haystack
  and len_n = String.length needle in
  let rec loop i =
    if i + len_n > len_h then false
    else if String.sub haystack i len_n = needle then true
    else loop (i + 1)
  in
  loop 0

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let with_temp_dir prefix f =
  let dir = temp_dir prefix in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () -> f dir)

let with_me_root root f =
  let previous = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" root;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv "ME_ROOT" value
      | None -> Unix.putenv "ME_ROOT" "")
    f

let run_in_dir dir cmd =
  let full = Printf.sprintf "cd %s && %s" (Filename.quote dir) cmd in
  match Sys.command full with
  | 0 -> ()
  | code -> failf "command failed (%d): %s" code full

let init_git_repo repo =
  run_in_dir repo "git init -q";
  run_in_dir repo "git config user.email 'test@example.com'";
  run_in_dir repo "git config user.name 'Test User'";
  write_file (Filename.concat repo "main.txt") "original\n";
  write_file (Filename.concat repo "notes.txt") "notes\n";
  run_in_dir repo "git add main.txt notes.txt";
  run_in_dir repo "git commit -q -m init"

let clear_autoresearch_state () =
  Lib.Autoresearch.with_loops_rw (fun () ->
      Hashtbl.reset Lib.Autoresearch.active_loops;
      Lib.Autoresearch.latest_loop_id := None);
  Hashtbl.reset Lib.Tool_autoresearch_registry.pending_hypotheses;
  Hashtbl.reset Lib.Tool_autoresearch_registry.custom_generators

let with_clean_state f =
  clear_autoresearch_state ();
  Fun.protect ~finally:clear_autoresearch_state f

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  f ~sw ~clock:(Eio.Stdenv.clock env)

let test_measure_metric_parses_tagged_output () =
  with_temp_dir "masc_metric_oas" @@ fun workdir ->
  with_eio @@ fun ~sw:_ ~clock:_ ->
  let metric_fn =
    "python3 -c 'print(\"<metric name=\\\"score\\\">1.25</metric>\")'"
  in
  match Lib.Autoresearch.measure_metric ~workdir ~timeout_s:5.0 metric_fn with
  | Ok (score, elapsed_ms) ->
    check (float 0.0001) "score" 1.25 score;
    check bool "elapsed non-negative" true (elapsed_ms >= 0)
  | Error err ->
    failf "expected tagged metric to parse, got %s" err

let test_measure_metric_rejects_shell_metacharacters () =
  let cases =
    [
      "echo $(whoami)";
      "echo foo\\ bar";
      "echo test | cat";
      "echo (\n)";
    ]
  in
  List.iter (fun metric_fn ->
      match Lib.Autoresearch.validate_metric_fn metric_fn with
      | Ok _ -> failf "expected metric_fn to be rejected: %S" metric_fn
      | Error msg ->
        check bool "mentions dangerous chars" true
          (contains msg "dangerous shell metacharacters"
           || contains msg "single-line command"))
    cases

let test_cycle_reinjects_diff_guard_lesson () =
  with_temp_dir "masc_cycle_oas" @@ fun root ->
  with_me_root root @@ fun () ->
  with_eio @@ fun ~sw ~clock ->
  with_clean_state @@ fun () ->
  let repo = Filename.concat root "repo" in
  Unix.mkdir repo 0o755;
  init_git_repo repo;
  let state =
    Lib.Autoresearch.create_state
      ~goal:"Improve main file"
      ~metric_fn:"/usr/bin/printf 1.0"
      ~model_model:"glm:test"
      ~target_file:"main.txt"
      ~cycle_timeout_s:5.0
      ~max_cycles:3
      ~workdir:repo
      ()
  in
  Lib.Autoresearch.with_loops_rw (fun () ->
      Hashtbl.replace Lib.Autoresearch.active_loops state.loop_id state;
      Lib.Autoresearch.latest_loop_id := Some state.loop_id);
  let ctx : Lib.Tool_autoresearch_repo_synthesis.context =
    {
      base_path = root;
      agent_name = Some "test";
      start_operation = None;
      start_team_session = None;
      config = None;
      sw = Some sw;
      clock = Some clock;
    }
  in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal:_ ~baseline:_ ~history:_ ~insights:_ ~target_file:_ ~file_content:_ ->
       Ok ("tighten main", "changed\n"));
  write_file (Filename.concat repo "notes.txt") "drifted\n";
  let first =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  let open Yojson.Safe.Util in
  check string "first decision" "discard" (first |> member "decision" |> to_string);
  let first_reason = first |> member "reason" |> to_string in
  check bool "diff guard reason present" true
    (contains first_reason "diff guard rejected patch");
  check string "main restored" "original\n"
    (Fs_compat.load_file (Filename.concat repo "main.txt"));
  check string "external drift preserved" "drifted\n"
    (Fs_compat.load_file (Filename.concat repo "notes.txt"));
  write_file (Filename.concat repo "notes.txt") "notes\n";
  let captured_goal = ref None in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal ~baseline:_ ~history:_ ~insights:_ ~target_file:_ ~file_content ->
       captured_goal := Some goal;
       Ok ("reuse lesson", file_content));
  let second =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  check string "second decision" "discard" (second |> member "decision" |> to_string);
  let injected_goal =
    match !captured_goal with
    | Some goal -> goal
    | None -> fail "generator did not receive goal"
  in
  check bool "lesson context injected" true
    (contains injected_goal "Relevant prior failure lessons:"
     || contains injected_goal "Diff guard rejected patch");
  let final_cycle = Lib.Autoresearch.with_loops_ro (fun () ->
    match Hashtbl.find_opt Lib.Autoresearch.active_loops state.loop_id with
    | Some s -> s.current_cycle
    | None -> -1) in
  check int "cycle advanced twice" 2 final_cycle

let test_build_verify_downgrade_rewrites_history () =
  with_temp_dir "masc_cycle_build_verify" @@ fun root ->
  with_me_root root @@ fun () ->
  with_eio @@ fun ~sw ~clock ->
  with_clean_state @@ fun () ->
  let repo = Filename.concat root "repo" in
  Unix.mkdir repo 0o755;
  init_git_repo repo;
  run_in_dir repo "git checkout -q -b test-loop";
  let state =
    Lib.Autoresearch.create_state
      ~goal:"Improve main file"
      ~metric_fn:"/usr/bin/printf 1.0"
      ~model_model:"glm:test"
      ~target_file:"main.txt"
      ~cycle_timeout_s:5.0
      ~max_cycles:3
      ~build_verify_fn:"/usr/bin/false"
      ~workdir:repo
      ()
  in
  Lib.Autoresearch.with_loops_rw (fun () ->
      Hashtbl.replace Lib.Autoresearch.active_loops state.loop_id state;
      Lib.Autoresearch.latest_loop_id := Some state.loop_id);
  let ctx : Lib.Tool_autoresearch_repo_synthesis.context =
    {
      base_path = root;
      agent_name = Some "test";
      start_operation = None;
      start_team_session = None;
      config = None;
      sw = Some sw;
      clock = Some clock;
    }
  in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal:_ ~baseline:_ ~history:_ ~insights:_ ~target_file:_ ~file_content:_ ->
       Ok ("optimistic keep", "changed-once\n"));
  let first =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  let open Yojson.Safe.Util in
  let first_decision =
    match first |> member "decision" |> to_string_option with
    | Some decision -> decision
    | None ->
      failf "expected first cycle decision, got %s"
        (Yojson.Safe.to_string first)
  in
  check string "first cycle downgraded to discard"
    "discard" first_decision;
  let state_after_first =
    Lib.Autoresearch.with_loops_ro (fun () ->
      match Hashtbl.find_opt Lib.Autoresearch.active_loops state.loop_id with
      | Some s -> s
      | None -> fail "loop missing after first cycle")
  in
  let history_head =
    match state_after_first.history with
    | head :: _ -> head
    | [] -> fail "expected first cycle history"
  in
  check string "stored history head rewritten to discard"
    "discard"
    (Lib.Autoresearch.decision_to_string history_head.decision);
  let captured_history = ref None in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal:_ ~baseline:_ ~history ~insights:_ ~target_file:_ ~file_content:_ ->
       captured_history := Some history;
       Ok ("second pass", "changed-twice\n"));
  let second =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  let second_decision =
    match second |> member "decision" |> to_string_option with
    | Some decision -> decision
    | None ->
      failf "expected second cycle decision, got %s"
        (Yojson.Safe.to_string second)
  in
  check string "second cycle still runs" "discard"
    second_decision;
  let next_history_head =
    match !captured_history with
    | Some (head :: _) -> head
    | Some [] -> fail "generator history unexpectedly empty"
    | None -> fail "generator did not capture history"
  in
  check string "next cycle receives downgraded discard history"
    "discard"
    (Lib.Autoresearch.decision_to_string next_history_head.decision)

let () =
  run "autoresearch_oas_primitives"
    [
      ( "metric_contract",
        [
          test_case "tagged metric output parses" `Quick
            test_measure_metric_parses_tagged_output;
          test_case "dangerous shell metacharacters rejected" `Quick
            test_measure_metric_rejects_shell_metacharacters;
        ] );
      ( "feedback_loop",
        [
          test_case "diff guard lesson is reinjected" `Quick
            test_cycle_reinjects_diff_guard_lesson;
          test_case "build verify downgrade rewrites history" `Quick
            test_build_verify_downgrade_rewrites_history;
        ] );
    ]
