module Lib = Masc_mcp

open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_autoresearch" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let with_temp_base f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () -> f dir)

let clear_active_loops () =
  Lib.Autoresearch.with_loops_rw (fun () ->
    Hashtbl.reset Lib.Autoresearch.active_loops;
    Lib.Autoresearch.latest_loop_id := None)

let with_clean_loops f =
  clear_active_loops ();
  Fun.protect
    ~finally:clear_active_loops
    f

let with_eio_test f =
  Eio_main.run @@ fun _env ->
  f ()

let legacy_state_json ?(loop_id = "legacy-loop") ?(model = "glm:legacy") () =
  Printf.sprintf
    {|
{
  "loop_id": "%s",
  "goal": "Improve code quality",
  "metric_fn": "echo 0.75",
  "llm_model": "%s",
  "target_file": "README.md",
  "status": "running",
  "current_cycle": 0,
  "baseline": 0.75,
  "best_score": 0.75,
  "best_cycle": 0,
  "queued_hypothesis": null,
  "total_keeps": 0,
  "total_discards": 0,
  "max_cycles": 1,
  "cycle_timeout_s": 30.0,
  "workdir": "/tmp/autoresearch/worktree",
  "source_workdir": "/tmp/autoresearch",
  "elapsed_s": 0.5,
  "history_count": 0,
  "insights_count": 0,
  "program_note": null,
  "warnings": [ "source_workdir_dirty" ],
  "error": null
}
|}
    loop_id model

let persisted_state_json ?(loop_id = "persisted-loop") ?updated_at
    ?(status = "running") ?(current_cycle = 0) ?(best_score = 0.75)
    ?(best_cycle = 0) ?(elapsed_s = 0.5) () =
  let updated_at_field =
    match updated_at with
    | Some ts -> Printf.sprintf ",\n  \"updated_at\": %.6f" ts
    | None -> ""
  in
  Printf.sprintf
    {|
{
  "loop_id": "%s",
  "goal": "Improve code quality",
  "metric_fn": "echo 0.75",
  "model_model": "glm",
  "target_file": "README.md",
  "status": "%s",
  "current_cycle": %d,
  "baseline": 0.75,
  "best_score": %.2f,
  "best_cycle": %d,
  "queued_hypothesis": null,
  "total_keeps": 0,
  "total_discards": 0,
  "max_cycles": 3,
  "cycle_timeout_s": 30.0,
  "workdir": "/tmp/autoresearch/worktree",
  "source_workdir": "/tmp/autoresearch",
  "elapsed_s": %.3f%s,
  "history_count": 0,
  "insights_count": 0,
  "program_note": null,
  "warnings": [],
  "error": null
}
|}
    loop_id status current_cycle best_score best_cycle elapsed_s updated_at_field

let test_loops_json_skips_invalid_persisted_state () =
  with_eio_test @@ fun () ->
  with_clean_loops @@ fun () ->
  with_temp_base @@ fun base_path ->
  let state_path =
    Filename.concat base_path ".masc/autoresearch/bad-loop/state.json"
  in
  (* Valid JSON but missing loop_id — the only required string field
     checked by load_state before attempting deserialization.
     state_of_yojson provides defaults for all optional fields, so
     the only way to trigger rejection is to omit loop_id. *)
  write_file state_path {|{"status":"running"}|};
  let json =
    Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
  in
  (* Missing loop_id causes load_state to reject the state.
     The dashboard gracefully skips invalid persisted state. *)
  check int "total skips invalid partial state" 0
    Yojson.Safe.Util.(json |> member "total" |> to_int);
  check int "no loop entries for invalid state" 0
    Yojson.Safe.Util.(json |> member "loops" |> to_list |> List.length)

let test_loops_json_skips_legacy_persisted_state () =
  with_eio_test @@ fun () ->
  with_clean_loops @@ fun () ->
  with_temp_base @@ fun base_path ->
  let loop_id = "legacy-loop" in
  let state_path =
    Filename.concat base_path (Printf.sprintf ".masc/autoresearch/%s/state.json" loop_id)
  in
  write_file state_path (legacy_state_json ~loop_id ());
  let json =
    Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
  in
  check int "legacy persisted loop is skipped" 0
    Yojson.Safe.Util.(json |> member "total" |> to_int);
  check int "no legacy loop entries" 0
    Yojson.Safe.Util.(json |> member "loops" |> to_list |> List.length)

let test_loops_json_tolerates_invalid_swarm_link_for_active_loop () =
  with_eio_test @@ fun () ->
  with_clean_loops @@ fun () ->
  with_temp_base @@ fun base_path ->
  let state =
    Lib.Autoresearch.create_state
      ~goal:"autoresearch smoke"
      ~metric_fn:"echo 1"
      ~model_model:"glm:test"
      ~target_file:"README.md"
      ~cycle_timeout_s:10.0
      ~max_cycles:3
      ~workdir:base_path
      ()
  in
  Lib.Autoresearch.with_loops_rw (fun () ->
    Hashtbl.replace Lib.Autoresearch.active_loops state.loop_id state);
  let swarm_path =
    Lib.Autoresearch.loop_link_file ~base_path state.loop_id
  in
  (* Missing required session_id should not crash the loops list. *)
  write_file swarm_path
    (Printf.sprintf {|{"loop_id":"%s","linked_at":0}|} state.loop_id);
  let json =
    Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
  in
  check int "active loop still listed" 1
    Yojson.Safe.Util.(json |> member "total" |> to_int);
  check bool "session id falls back to null" true
    Yojson.Safe.Util.(json |> member "loops" |> index 0 |> member "session_id" = `Null)

let test_loops_json_orders_live_then_recent () =
  with_eio_test @@ fun () ->
  with_clean_loops @@ fun () ->
  with_temp_base @@ fun base_path ->
  let active =
    Lib.Autoresearch.create_state
      ~goal:"active loop"
      ~metric_fn:"echo 1"
      ~model_model:"glm:test"
      ~target_file:"README.md"
      ~cycle_timeout_s:10.0
      ~max_cycles:3
      ~workdir:base_path
      ()
  in
  active.updated_at <- 10.0;
  Lib.Autoresearch.with_loops_rw (fun () ->
    Hashtbl.replace Lib.Autoresearch.active_loops active.loop_id active);
  let newer_persisted_path =
    Filename.concat base_path ".masc/autoresearch/persisted-new/state.json"
  in
  write_file newer_persisted_path
    (persisted_state_json ~loop_id:"persisted-new" ~updated_at:300.0 ());
  let older_persisted_path =
    Filename.concat base_path ".masc/autoresearch/persisted-old/state.json"
  in
  write_file older_persisted_path
    (persisted_state_json ~loop_id:"persisted-old" ~updated_at:100.0 ());
  let json =
    Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
  in
  let loops = Yojson.Safe.Util.(json |> member "loops" |> to_list) in
  check int "three loops" 3 (List.length loops);
  check string "live loop first" active.loop_id
    Yojson.Safe.Util.(List.nth loops 0 |> member "loop_id" |> to_string);
  check bool "first loop is live" true
    Yojson.Safe.Util.(List.nth loops 0 |> member "live" |> to_bool);
  check string "newer persisted second" "persisted-new"
    Yojson.Safe.Util.(List.nth loops 1 |> member "loop_id" |> to_string);
  check bool "persisted loop marked not live" false
    Yojson.Safe.Util.(List.nth loops 1 |> member "live" |> to_bool)

let test_loops_json_uses_state_file_mtime_for_updated_at () =
  with_eio_test @@ fun () ->
  with_clean_loops @@ fun () ->
  with_temp_base @@ fun base_path ->
  let loop_id = "mtime-loop" in
  let state_path =
    Filename.concat base_path (Printf.sprintf ".masc/autoresearch/%s/state.json" loop_id)
  in
  write_file state_path (persisted_state_json ~loop_id ());
  let expected_mtime = 1_717_171_717.0 in
  Unix.utimes state_path expected_mtime expected_mtime;
  let json =
    Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
  in
  let updated_at =
    Yojson.Safe.Util.(json |> member "loops" |> index 0 |> member "updated_at" |> to_float)
  in
  check bool "updated_at falls back to state file mtime" true
    (abs_float (updated_at -. expected_mtime) < 0.001)

let () =
  run "dashboard_autoresearch"
    [
      ( "loops_json",
        [
          test_case "skips invalid persisted state" `Quick
            test_loops_json_skips_invalid_persisted_state;
          test_case "skips legacy persisted state" `Quick
            test_loops_json_skips_legacy_persisted_state;
          test_case "tolerates invalid swarm link for active loop" `Quick
            test_loops_json_tolerates_invalid_swarm_link_for_active_loop;
          test_case "orders live then recent" `Quick
            test_loops_json_orders_live_then_recent;
          test_case "uses state file mtime for updated_at" `Quick
            test_loops_json_uses_state_file_mtime_for_updated_at;
        ] );
    ]
