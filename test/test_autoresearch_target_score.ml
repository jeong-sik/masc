module Lib = Masc_mcp

open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

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

let with_base_path root f =
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" root;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv "MASC_BASE_PATH" value
      | None -> Unix.putenv "MASC_BASE_PATH" "")
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
  run_in_dir repo "git add main.txt";
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

let test_target_score_reaches_completion_higher_is_better () =
  with_temp_dir "masc_autoresearch_target_high" @@ fun root ->
  with_base_path root @@ fun () ->
  with_eio @@ fun ~sw ~clock ->
  with_clean_state @@ fun () ->
  let repo = Filename.concat root "repo" in
  Unix.mkdir repo 0o755;
  init_git_repo repo;
  run_in_dir repo "git checkout -q -b target-high";
  write_file (Filename.concat repo "metric.py")
    "import pathlib, sys\ntext = pathlib.Path(sys.argv[1]).read_text()\nprint(1.0 if 'GOAL_REACHED' in text else 0.0)\n";
  let state =
    Lib.Autoresearch.create_state
      ~goal:"Reach target marker"
      ~metric_fn:"python3 metric.py main.txt"
      ~model_model:"glm:test"
      ~target_file:"main.txt"
      ~target_score:1.0
      ~cycle_timeout_s:5.0
      ~max_cycles:3
      ~workdir:repo
      ()
  in
  let state = { state with baseline = 0.0; best_score = 0.0 } in
  Lib.Autoresearch.with_loops_rw (fun () ->
      Hashtbl.replace Lib.Autoresearch.active_loops state.loop_id state;
      Lib.Autoresearch.latest_loop_id := Some state.loop_id);
  let ctx : Lib.Tool_autoresearch_context.t =
    {
      base_path = root;
      agent_name = Some "test";
      start_operation = None;
      config = None;
      sw = Some sw;
      clock = Some clock;
    }
  in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal:_ ~baseline:_ ~lower_is_better:_ ~history:_ ~insights:_
         ~target_file:_ ~file_content:_ ->
       Ok ("flip marker", "GOAL_REACHED\n"));
  let result =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  let open Yojson.Safe.Util in
  check string "cycle status completed" "completed"
    (result |> member "status" |> to_string);
  check bool "target reached in result" true
    (result |> member "target_reached" |> to_bool);
  let final_state =
    Lib.Autoresearch.with_loops_ro (fun () ->
      match Hashtbl.find_opt Lib.Autoresearch.active_loops state.loop_id with
      | Some s -> s
      | None -> fail "loop missing after target completion")
  in
  check string "loop marked completed" "completed"
    (Lib.Autoresearch.status_to_string final_state.status);
  check bool "target reached in state" true
    (Lib.Autoresearch.target_reached final_state)

let test_target_score_reaches_completion_lower_is_better () =
  with_temp_dir "masc_autoresearch_target_low" @@ fun root ->
  with_base_path root @@ fun () ->
  with_eio @@ fun ~sw ~clock ->
  with_clean_state @@ fun () ->
  let repo = Filename.concat root "repo" in
  Unix.mkdir repo 0o755;
  init_git_repo repo;
  run_in_dir repo "git checkout -q -b target-low";
  write_file (Filename.concat repo "metric.py")
    "import pathlib, sys\ntext = pathlib.Path(sys.argv[1]).read_text()\nprint(0.5 if 'LOWER_WINS' in text else 2.0)\n";
  let state =
    Lib.Autoresearch.create_state
      ~goal:"Lower metric target"
      ~metric_fn:"python3 metric.py main.txt"
      ~model_model:"glm:test"
      ~target_file:"main.txt"
      ~target_score:1.0
      ~cycle_timeout_s:5.0
      ~max_cycles:3
      ~lower_is_better:true
      ~workdir:repo
      ()
  in
  let state = { state with baseline = 2.0; best_score = 2.0 } in
  Lib.Autoresearch.with_loops_rw (fun () ->
      Hashtbl.replace Lib.Autoresearch.active_loops state.loop_id state;
      Lib.Autoresearch.latest_loop_id := Some state.loop_id);
  let ctx : Lib.Tool_autoresearch_context.t =
    {
      base_path = root;
      agent_name = Some "test";
      start_operation = None;
      config = None;
      sw = Some sw;
      clock = Some clock;
    }
  in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal:_ ~baseline:_ ~lower_is_better:_ ~history:_ ~insights:_
         ~target_file:_ ~file_content:_ ->
       Ok ("lower wins", "LOWER_WINS\n"));
  let result =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  let open Yojson.Safe.Util in
  check string "cycle status completed" "completed"
    (result |> member "status" |> to_string);
  check bool "target reached in result" true
    (result |> member "target_reached" |> to_bool);
  let final_state =
    Lib.Autoresearch.with_loops_ro (fun () ->
      match Hashtbl.find_opt Lib.Autoresearch.active_loops state.loop_id with
      | Some s -> s
      | None -> fail "loop missing after lower target completion")
  in
  check string "loop marked completed" "completed"
    (Lib.Autoresearch.status_to_string final_state.status);
  check bool "target reached in state" true
    (Lib.Autoresearch.target_reached final_state)

let test_omitted_target_score_preserves_running_status () =
  with_temp_dir "masc_autoresearch_target_none" @@ fun root ->
  with_base_path root @@ fun () ->
  with_eio @@ fun ~sw ~clock ->
  with_clean_state @@ fun () ->
  let repo = Filename.concat root "repo" in
  Unix.mkdir repo 0o755;
  init_git_repo repo;
  run_in_dir repo "git checkout -q -b target-none";
  write_file (Filename.concat repo "metric.py")
    "import pathlib, sys\ntext = pathlib.Path(sys.argv[1]).read_text()\nprint(1.0 if 'GOAL_REACHED' in text else 0.0)\n";
  let state =
    Lib.Autoresearch.create_state
      ~goal:"Improve but stay running"
      ~metric_fn:"python3 metric.py main.txt"
      ~model_model:"glm:test"
      ~target_file:"main.txt"
      ~cycle_timeout_s:5.0
      ~max_cycles:3
      ~workdir:repo
      ()
  in
  let state = { state with baseline = 0.0; best_score = 0.0 } in
  Lib.Autoresearch.with_loops_rw (fun () ->
      Hashtbl.replace Lib.Autoresearch.active_loops state.loop_id state;
      Lib.Autoresearch.latest_loop_id := Some state.loop_id);
  let ctx : Lib.Tool_autoresearch_context.t =
    {
      base_path = root;
      agent_name = Some "test";
      start_operation = None;
      config = None;
      sw = Some sw;
      clock = Some clock;
    }
  in
  Lib.Tool_autoresearch_registry.set_generator state.loop_id
    (fun ~goal:_ ~baseline:_ ~lower_is_better:_ ~history:_ ~insights:_
         ~target_file:_ ~file_content:_ ->
       Ok ("flip marker", "GOAL_REACHED\n"));
  let result =
    Lib.Tool_autoresearch_cycle.handle_cycle ctx
      (`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  let open Yojson.Safe.Util in
  check string "cycle status remains running" "running"
    (result |> member "status" |> to_string);
  check bool "target not reported reached" false
    (result |> member "target_reached" |> to_bool);
  let final_state =
    Lib.Autoresearch.with_loops_ro (fun () ->
      match Hashtbl.find_opt Lib.Autoresearch.active_loops state.loop_id with
      | Some s -> s
      | None -> fail "loop missing after running cycle")
  in
  check string "loop remains running" "running"
    (Lib.Autoresearch.status_to_string final_state.status)

let () =
  run "autoresearch_target_score"
    [
      ( "target_score",
        [
          test_case "target score completes higher-is-better loop" `Quick
            test_target_score_reaches_completion_higher_is_better;
          test_case "target score completes lower-is-better loop" `Quick
            test_target_score_reaches_completion_lower_is_better;
          test_case "omitted target score preserves running status" `Quick
            test_omitted_target_score_preserves_running_status;
        ] );
    ]
