module Lib = Masc_mcp

open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let path = Filename.temp_file "masc_autoresearch_loop" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let run_cmd command =
  match Sys.command command with
  | 0 -> ()
  | code -> failf "command failed (%d): %s" code command

let clear_autoresearch_runtime () =
  Lib.Autoresearch.with_loops_rw (fun () ->
    Hashtbl.reset Lib.Autoresearch.active_loops;
    Lib.Autoresearch.latest_loop_id := None);
  Hashtbl.reset Lib.Tool_autoresearch.pending_hypotheses;
  Hashtbl.reset Lib.Tool_autoresearch.custom_generators

let test_start_runs_to_completion_via_manual_cycle () =
  Eio_main.run @@ fun _env ->
  clear_autoresearch_runtime ();
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      clear_autoresearch_runtime ();
      cleanup_dir base_path)
    (fun () ->
      let repo_path = Filename.concat base_path "repo" in
      Unix.mkdir repo_path 0o755;
      let target_path = Filename.concat repo_path "target.txt" in
      let metric_path = Filename.concat repo_path "metric.sh" in
      write_file target_path "baseline text\n";
      write_file metric_path
        "#!/bin/sh\nif grep -q MAGIC_20260324 target.txt; then\n  echo 1.0\nelse\n  echo 0.0\nfi\n";
      Unix.chmod metric_path 0o755;
      run_cmd (Printf.sprintf "git -C %s init >/dev/null 2>&1" (Filename.quote repo_path));
      run_cmd
        (Printf.sprintf "git -C %s config user.name %s"
           (Filename.quote repo_path) (Filename.quote "Autoresearch Test"));
      run_cmd
        (Printf.sprintf "git -C %s config user.email %s"
           (Filename.quote repo_path) (Filename.quote "autoresearch-test@example.com"));
      run_cmd (Printf.sprintf "git -C %s add target.txt metric.sh" (Filename.quote repo_path));
      run_cmd
        (Printf.sprintf "git -C %s commit -m %s >/dev/null 2>&1"
           (Filename.quote repo_path) (Filename.quote "init autoresearch test repo"));
      run_cmd (Printf.sprintf "git -C %s branch -M main" (Filename.quote repo_path));

      let ctx : Lib.Tool_autoresearch.context =
        {
          base_path;
          agent_name = Some "autoresearch-admin";
          start_operation = None;
          start_team_session = None;
          config = None;
          sw = None;
          clock = None;
        }
      in
      let args =
        `Assoc
          [
            ("goal", `String "Insert the required token");
            ("metric_fn", `String "./metric.sh");
            ("target_file", `String "target.txt");
            ("workdir", `String repo_path);
            ("max_cycles", `Int 1);
            ("cycle_timeout_s", `Float 10.0);
          ]
      in
      let ok, payload =
        match Lib.Tool_autoresearch.dispatch ctx ~name:"masc_autoresearch_start" ~args with
        | Some result -> result
        | None -> fail "dispatch returned None"
      in
      check bool "start succeeds" true ok;
      let json = Yojson.Safe.from_string payload in
      let loop_id = Yojson.Safe.Util.(json |> member "loop_id" |> to_string) in
      check string "start status" "running"
        Yojson.Safe.Util.(json |> member "status" |> to_string);

      Lib.Tool_autoresearch.set_generator loop_id
        (fun ~goal:_ ~baseline:_ ~history:_ ~insights:_ ~target_file:_ ~file_content:_ ->
          Ok ("insert token", "MAGIC_20260324\n"));

      let cycle_args =
        `Assoc [ ("loop_id", `String loop_id) ]
      in
      let cycle_ok, cycle_payload =
        match Lib.Tool_autoresearch.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:cycle_args with
        | Some result -> result
        | None -> fail "cycle dispatch returned None"
      in
      if not cycle_ok then failf "cycle failed: %s" cycle_payload;
      check bool "cycle succeeds" true cycle_ok;
      let cycle_json = Yojson.Safe.from_string cycle_payload in
      check string "cycle decision" "keep"
        Yojson.Safe.Util.(cycle_json |> member "decision" |> to_string);
      check int "cycles remaining after first cycle" 0
        Yojson.Safe.Util.(cycle_json |> member "cycles_remaining" |> to_int);

      let completion_ok, completion_payload =
        match Lib.Tool_autoresearch.dispatch ctx ~name:"masc_autoresearch_cycle" ~args:cycle_args with
        | Some result -> result
        | None -> fail "completion dispatch returned None"
      in
      if not completion_ok then failf "completion failed: %s" completion_payload;
      check bool "completion succeeds" true completion_ok;
      let completion_json = Yojson.Safe.from_string completion_payload in
      check string "completion status" "completed"
        Yojson.Safe.Util.(completion_json |> member "status" |> to_string);

      let final_state =
        match
          Lib.Autoresearch.with_loops_ro (fun () ->
            Hashtbl.find_opt Lib.Autoresearch.active_loops loop_id)
        with
        | Some state -> state
        | None -> fail "loop missing after completion"
      in
      check bool "final status completed" true
        (final_state.status = Lib.Autoresearch.Completed);
      check int "completed cycle count" 1 final_state.current_cycle;
      check int "keep count" 1 final_state.total_keeps;
      check int "discard count" 0 final_state.total_discards;
      check (float 0.0001) "best score" 1.0 final_state.best_score;
      check (float 0.0001) "baseline updated" 1.0 final_state.baseline;
      check bool "source file unchanged" true
        (String.equal (read_file target_path) "baseline text\n");
      check bool "managed worktree file changed" true
        (String.equal
           (read_file (Filename.concat final_state.workdir "target.txt"))
           "MAGIC_20260324\n");
      check bool "results persisted" true
        (Sys.file_exists (Lib.Autoresearch.results_file ~base_path loop_id)))

let () =
  run "autoresearch_loop"
    [
      ( "autonomous",
        [
          test_case "start runs to completion via manual cycle" `Quick
            test_start_runs_to_completion_via_manual_cycle;
        ] );
    ]
