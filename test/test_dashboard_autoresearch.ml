module Lib = Masc_mcp
open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_autoresearch" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path)
      else Sys.remove path
  in
  rm dir
;;

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)
;;

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > haystack_len
    then false
    else if String.sub haystack index needle_len = needle
    then true
    else loop (index + 1)
  in
  loop 0
;;

let run_cmd_exn cmd =
  match Sys.command cmd with
  | 0 -> ()
  | code -> failwith (Printf.sprintf "command failed (%d): %s" code cmd)
;;

let init_git_repo path =
  Unix.mkdir path 0o755;
  run_cmd_exn (Printf.sprintf "git -C %s init -q" (Filename.quote path));
  run_cmd_exn
    (Printf.sprintf
       "git -C %s config user.email dashboard@test.local"
       (Filename.quote path));
  run_cmd_exn
    (Printf.sprintf "git -C %s config user.name dashboard-test" (Filename.quote path));
  write_file (Filename.concat path "README.md") "initial\n";
  run_cmd_exn (Printf.sprintf "git -C %s add README.md" (Filename.quote path));
  run_cmd_exn (Printf.sprintf "git -C %s commit -q -m init" (Filename.quote path))
;;

let with_temp_base f =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () -> f dir)
;;

let clear_active_loops () =
  Lib.Autoresearch.with_loops_rw (fun () ->
    Hashtbl.reset Lib.Autoresearch.active_loops;
    Lib.Autoresearch.latest_loop_id := None)
;;

let with_clean_loops f =
  clear_active_loops ();
  Fun.protect ~finally:clear_active_loops f
;;

let with_eio_test f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()
;;

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
    loop_id
    model
;;

let persisted_state_json
      ?(loop_id = "persisted-loop")
      ?updated_at
      ?(status = "running")
      ?(current_cycle = 0)
      ?(best_score = 0.75)
      ?(best_cycle = 0)
      ?(elapsed_s = 0.5)
      ?(workdir = "/tmp/autoresearch/worktree")
      ?(source_workdir = "/tmp/autoresearch")
      ?(error = "null")
      ?(warnings = "[]")
      ()
  =
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
  "workdir": "%s",
  "source_workdir": "%s",
  "elapsed_s": %.3f%s,
  "history_count": 0,
  "insights_count": 0,
  "program_note": null,
  "warnings": %s,
  "error": %s
}
|}
    loop_id
    status
    current_cycle
    best_score
    best_cycle
    workdir
    source_workdir
    elapsed_s
    updated_at_field
    warnings
    error
;;

let test_state_result_parser_valid () =
  let json =
    Yojson.Safe.from_string
      (persisted_state_json
         ~loop_id:"parser-loop"
         ~updated_at:42.0
         ~warnings:"[\"source_workdir_dirty\"]"
         ())
  in
  match Lib.Autoresearch.state_of_yojson_result json with
  | Ok summary ->
    check string "loop_id" "parser-loop" summary.loop_id;
    check string "status" "running" (Lib.Autoresearch.status_to_string summary.status);
    check (option (float 0.01)) "updated_at" (Some 42.0) summary.updated_at;
    check string "source_workdir" "/tmp/autoresearch" summary.source_workdir
  | Error message -> failwith message
;;

let test_state_result_parser_rejects_missing_required_field () =
  match
    Lib.Autoresearch.state_of_yojson_result (`Assoc [ "loop_id", `String "bad-loop" ])
  with
  | Ok _ -> failwith "expected parser to reject incomplete persisted state"
  | Error message ->
    check bool "mentions missing status" true (contains_substring message "status")
;;

let test_cycle_result_parser_rejects_bad_decision () =
  let json =
    `Assoc
      [ "cycle", `Int 1
      ; "hypothesis", `String "try something"
      ; "score_before", `Float 0.1
      ; "score_after", `Float 0.2
      ; "delta", `Float 0.1
      ; "decision", `String "invalid"
      ; "elapsed_ms", `Int 12
      ; "model_used", `String "glm"
      ; "timestamp", `Float 1.0
      ]
  in
  match Lib.Autoresearch.cycle_of_yojson_result json with
  | Ok _ -> failwith "expected parser to reject invalid decision"
  | Error message -> check bool "has decision error" true (String.length message > 0)
;;

let test_execution_link_result_parser_rejects_missing_session_id () =
  let json =
    `Assoc
      [ "loop_id", `String "loop-1"
      ; "target_file", `String "README.md"
      ; "linked_at", `Float 1.0
      ]
  in
  match Lib.Autoresearch.execution_link_of_yojson_result json with
  | Ok _ -> failwith "expected parser to reject missing session_id"
  | Error message -> check bool "has session_id error" true (String.length message > 0)
;;

let test_loops_json_skips_invalid_persisted_state () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  let state_path = Filename.concat base_path ".masc/autoresearch/bad-loop/state.json" in
  (* Valid JSON but missing required fields used by state_of_yojson. *)
  write_file state_path {|{"loop_id":"bad-loop","status":"running"}|};
  let json = Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path () in
  (* Partial state.json (only loop_id+status) is rejected by strict
     schema validation in load_state. Dashboard skips invalid entries. *)
  check int "partial state rejected" 0 Yojson.Safe.Util.(json |> member "total" |> to_int);
  check
    int
    "no loop entries"
    0
    Yojson.Safe.Util.(json |> member "loops" |> to_list |> List.length)
;;

let test_loops_json_skips_legacy_persisted_state () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  let loop_id = "legacy-loop" in
  let state_path =
    Filename.concat base_path (Printf.sprintf ".masc/autoresearch/%s/state.json" loop_id)
  in
  write_file state_path (legacy_state_json ~loop_id ());
  let json = Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path () in
  check
    int
    "legacy persisted loop is skipped"
    0
    Yojson.Safe.Util.(json |> member "total" |> to_int);
  check
    int
    "no legacy loop entries"
    0
    Yojson.Safe.Util.(json |> member "loops" |> to_list |> List.length)
;;

let test_loops_json_tolerates_invalid_execution_link_for_active_loop () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
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
  let execution_link_path = Lib.Autoresearch.loop_link_file ~base_path state.loop_id in
  (* Missing required session_id should not crash the loops list. *)
  write_file
    execution_link_path
    (Printf.sprintf {|{"loop_id":"%s","linked_at":0}|} state.loop_id);
  let json = Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path () in
  check
    int
    "active loop still listed"
    1
    Yojson.Safe.Util.(json |> member "total" |> to_int);
  check
    bool
    "session id falls back to null"
    true
    Yojson.Safe.Util.(json |> member "loops" |> index 0 |> member "session_id" = `Null)
;;

let test_loops_json_orders_live_then_recent () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
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
  let active = { active with updated_at = 10.0 } in
  Lib.Autoresearch.with_loops_rw (fun () ->
    Hashtbl.replace Lib.Autoresearch.active_loops active.loop_id active);
  let newer_persisted_path =
    Filename.concat base_path ".masc/autoresearch/persisted-new/state.json"
  in
  write_file
    newer_persisted_path
    (persisted_state_json ~loop_id:"persisted-new" ~updated_at:300.0 ());
  let older_persisted_path =
    Filename.concat base_path ".masc/autoresearch/persisted-old/state.json"
  in
  write_file
    older_persisted_path
    (persisted_state_json ~loop_id:"persisted-old" ~updated_at:100.0 ());
  let json = Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path () in
  let loops = Yojson.Safe.Util.(json |> member "loops" |> to_list) in
  check int "three loops" 3 (List.length loops);
  check
    string
    "live loop first"
    active.loop_id
    Yojson.Safe.Util.(List.nth loops 0 |> member "loop_id" |> to_string);
  check
    bool
    "first loop is live"
    true
    Yojson.Safe.Util.(List.nth loops 0 |> member "live" |> to_bool);
  check
    string
    "newer persisted second"
    "persisted-new"
    Yojson.Safe.Util.(List.nth loops 1 |> member "loop_id" |> to_string);
  check
    bool
    "persisted loop marked not live"
    false
    Yojson.Safe.Util.(List.nth loops 1 |> member "live" |> to_bool)
;;

let test_loops_json_uses_state_file_mtime_for_updated_at () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  let loop_id = "mtime-loop" in
  let state_path =
    Filename.concat base_path (Printf.sprintf ".masc/autoresearch/%s/state.json" loop_id)
  in
  write_file state_path (persisted_state_json ~loop_id ());
  let expected_mtime = 1_717_171_717.0 in
  Unix.utimes state_path expected_mtime expected_mtime;
  let json = Lib.Dashboard_http_autoresearch.autoresearch_loops_json ~base_path () in
  let updated_at =
    Yojson.Safe.Util.(
      json |> member "loops" |> index 0 |> member "updated_at" |> to_float)
  in
  check
    bool
    "updated_at falls back to state file mtime"
    true
    (abs_float (updated_at -. expected_mtime) < 0.001)
;;

let test_retry_loop_json_restores_missing_worktree () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  let repo_root = Filename.concat base_path "repo" in
  init_git_repo repo_root;
  let loop_id = "retry-loop" in
  run_cmd_exn
    (Printf.sprintf
       "git -C %s branch %s"
       (Filename.quote repo_root)
       (Filename.quote (Lib.Autoresearch.managed_branch_name loop_id)));
  let workdir = Lib.Autoresearch.managed_worktree_dir ~base_path loop_id in
  let state =
    Lib.Autoresearch.create_state
      ~goal:"repair loop"
      ~metric_fn:"echo 1"
      ~model_model:"glm"
      ~target_file:"README.md"
      ~cycle_timeout_s:30.0
      ~max_cycles:1
      ~workdir:repo_root
      ()
  in
  let state =
    { state with
      loop_id
    ; source_workdir = repo_root
    ; status = Lib.Autoresearch.Error
    ; error_message = Some "managed worktree missing"
    ; workdir
    ; warnings = [ "source_workdir_dirty" ]
    }
  in
  Lib.Autoresearch.save_state ~base_path state;
  match Lib.Dashboard_http_autoresearch.retry_loop_json ~base_path ~loop_id with
  | Error message -> failwith message
  | Ok json ->
    check bool "retry ok" true Yojson.Safe.Util.(json |> member "ok" |> to_bool);
    check
      string
      "retry action"
      "retry"
      Yojson.Safe.Util.(json |> member "action" |> to_string);
    check
      string
      "loop status"
      "running"
      Yojson.Safe.Util.(json |> member "loop" |> member "status" |> to_string);
    check
      bool
      "loop marked live"
      true
      Yojson.Safe.Util.(json |> member "loop" |> member "live" |> to_bool);
    check bool "worktree recreated" true (Sys.file_exists workdir);
    check
      bool
      "active loop restored"
      true
      (Lib.Autoresearch.with_loops_ro (fun () ->
         Hashtbl.mem Lib.Autoresearch.active_loops loop_id))
;;

let test_delete_loop_json_removes_bundle_and_branch () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  let repo_root = Filename.concat base_path "repo" in
  init_git_repo repo_root;
  let loop_id = "delete-loop" in
  run_cmd_exn
    (Printf.sprintf
       "git -C %s branch %s"
       (Filename.quote repo_root)
       (Filename.quote (Lib.Autoresearch.managed_branch_name loop_id)));
  let workdir = Lib.Autoresearch.managed_worktree_dir ~base_path loop_id in
  let state =
    Lib.Autoresearch.create_state
      ~goal:"delete loop"
      ~metric_fn:"echo 1"
      ~model_model:"glm"
      ~target_file:"README.md"
      ~cycle_timeout_s:30.0
      ~max_cycles:1
      ~workdir:repo_root
      ()
  in
  let state =
    { state with
      loop_id
    ; source_workdir = repo_root
    ; status = Lib.Autoresearch.Error
    ; error_message = Some "managed worktree missing"
    ; workdir
    }
  in
  Lib.Autoresearch.save_state ~base_path state;
  let link : Lib.Autoresearch.execution_link =
    { loop_id
    ; session_id = "session-delete"
    ; operation_id = None
    ; task_id = None
    ; target_file = "README.md"
    ; program_note = None
    ; created_by = None
    ; linked_at = Unix.gettimeofday ()
    }
  in
  Lib.Autoresearch.save_execution_link ~base_path link;
  match
    Lib.Dashboard_http_autoresearch.delete_loop_json
      ~base_path
      ~loop_id
      ~requester_agent:None
  with
  | Error message -> failwith message
  | Ok json ->
    check bool "delete ok" true Yojson.Safe.Util.(json |> member "ok" |> to_bool);
    check
      string
      "delete action"
      "delete"
      Yojson.Safe.Util.(json |> member "action" |> to_string);
    check
      bool
      "bundle removed"
      false
      (Sys.file_exists (Lib.Autoresearch.results_dir ~base_path loop_id));
    check
      bool
      "session link removed"
      false
      (Sys.file_exists (Lib.Autoresearch.session_link_file ~base_path "session-delete"))
;;

let test_retry_loop_json_rejects_unsafe_loop_id () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  match
    Lib.Dashboard_http_autoresearch.retry_loop_json ~base_path ~loop_id:"../escape"
  with
  | Ok _ -> failwith "expected invalid loop_id to fail"
  | Error message -> check string "invalid retry loop_id" "invalid loop_id" message
;;

let test_delete_loop_json_rejects_unsafe_loop_id () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  match
    Lib.Dashboard_http_autoresearch.delete_loop_json
      ~base_path
      ~loop_id:"../escape"
      ~requester_agent:None
  with
  | Ok _ -> failwith "expected invalid loop_id to fail"
  | Error message -> check string "invalid delete loop_id" "invalid loop_id" message
;;

let test_linked_status_json_includes_task_id () =
  with_eio_test
  @@ fun () ->
  with_clean_loops
  @@ fun () ->
  with_temp_base
  @@ fun base_path ->
  let loop_id = "task-linked-loop" in
  let state =
    Lib.Autoresearch.create_state
      ~goal:"task linked"
      ~metric_fn:"echo 1"
      ~model_model:"glm"
      ~target_file:"README.md"
      ~cycle_timeout_s:30.0
      ~max_cycles:1
      ~workdir:base_path
      ()
  in
  let state = { state with loop_id; source_workdir = base_path } in
  Lib.Autoresearch.save_state ~base_path state;
  let link : Lib.Autoresearch.execution_link =
    { loop_id
    ; session_id = "session-task"
    ; operation_id = Some "op-task"
    ; task_id = Some "task-777"
    ; target_file = "README.md"
    ; program_note = None
    ; created_by = Some "codex"
    ; linked_at = Unix.gettimeofday ()
    }
  in
  let json = Lib.Autoresearch.linked_status_json ~base_path link in
  check
    (option string)
    "linked status includes task_id"
    (Some "task-777")
    Yojson.Safe.Util.(json |> member "task_id" |> to_string_option)
;;

let () =
  run
    "dashboard_autoresearch"
    [ ( "parser_results"
      , [ test_case "state result parser valid" `Quick test_state_result_parser_valid
        ; test_case
            "state result parser rejects missing field"
            `Quick
            test_state_result_parser_rejects_missing_required_field
        ; test_case
            "cycle result parser rejects bad decision"
            `Quick
            test_cycle_result_parser_rejects_bad_decision
        ; test_case
            "swarm link result parser rejects missing session_id"
            `Quick
            test_execution_link_result_parser_rejects_missing_session_id
        ] )
    ; ( "loops_json"
      , [ test_case
            "skips invalid persisted state"
            `Quick
            test_loops_json_skips_invalid_persisted_state
        ; test_case
            "skips legacy persisted state"
            `Quick
            test_loops_json_skips_legacy_persisted_state
        ; test_case
            "tolerates invalid swarm link for active loop"
            `Quick
            test_loops_json_tolerates_invalid_execution_link_for_active_loop
        ; test_case
            "orders live then recent"
            `Quick
            test_loops_json_orders_live_then_recent
        ; test_case
            "uses state file mtime for updated_at"
            `Quick
            test_loops_json_uses_state_file_mtime_for_updated_at
        ; test_case
            "retry restores missing worktree"
            `Quick
            test_retry_loop_json_restores_missing_worktree
        ; test_case
            "delete removes bundle and branch"
            `Quick
            test_delete_loop_json_removes_bundle_and_branch
        ; test_case
            "linked status includes task id"
            `Quick
            test_linked_status_json_includes_task_id
        ; test_case
            "retry rejects unsafe loop id"
            `Quick
            test_retry_loop_json_rejects_unsafe_loop_id
        ; test_case
            "delete rejects unsafe loop id"
            `Quick
            test_delete_loop_json_rejects_unsafe_loop_id
        ] )
    ]
;;
