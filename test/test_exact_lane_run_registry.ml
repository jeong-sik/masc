open Alcotest
module R = Masc.Exact_lane_run_registry

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let mark_completed_exn t ~run_id ~outcome ~elapsed_s ~output =
  match R.mark_completed t ~run_id ~outcome ~elapsed_s ~output with
  | Ok () -> ()
  | Error error ->
    failf
      "exact-lane completion failed: %s"
      (R.completion_error_to_string error)
;;

let test_round_trip_preserves_exact_evidence () =
  let path = Filename.temp_file "exact-lane-runs-" ".jsonl" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-1"
    ~lane:R.Librarian
    ~subject_id:"trace-1"
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input (`Assoc [ "message_count", `Int 4 ]));
  mark_completed_exn
    registry
    ~run_id:"run-1"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:(`Assoc [ "fact_count", `Int 3 ]);
  let replayed = R.replay path in
  let original = R.get registry ~run_id:"run-1" |> Option.get |> R.run_to_yojson in
  let restored = R.get replayed ~run_id:"run-1" |> Option.get |> R.run_to_yojson in
  check string "round trip" (Yojson.Safe.to_string original) (Yojson.Safe.to_string restored);
  remove_if_exists path
;;

let test_running_shape_has_no_invented_completion () =
  let registry = R.create () in
  R.register_running
    registry
    ~run_id:"run-live"
    ~lane:R.Board_attention
    ~subject_id:"candidate-1"
    ~actor:"keeper-a"
    ~started_at:20.0
    ~input:(R.Exact_input `Null);
  let run = R.get registry ~run_id:"run-live" |> Option.get in
  check string "status" "running" (R.status_label run.status);
  match R.run_to_yojson run with
  | `Assoc fields ->
    check bool "no elapsed" false (List.mem_assoc "elapsed_s" fields);
    check bool "no output" false (List.mem_assoc "output" fields)
  | _ -> fail "run serializer must emit an object"
;;

let test_current_storage_generation () =
  check string "current store file" "exact-lane-runs-v3.jsonl" R.storage_filename
;;

let test_exact_history_is_not_pruned_across_lanes () =
  let path = Filename.temp_file "exact-lane-runs-all-" ".jsonl" in
  remove_if_exists path;
  let registry = R.create ~path () in
  List.init 80 Fun.id
  |> List.iter (fun index ->
    let run_id = Printf.sprintf "run-%02d" index in
    let lane =
      match index mod 4 with
      | 0 -> R.Librarian
      | 1 -> R.Hitl_auto_judge
      | 2 -> R.Board_attention
      | _ -> R.Compaction
    in
    R.register_running
      registry
      ~run_id
      ~lane
      ~subject_id:run_id
      ~actor:"keeper-a"
      ~started_at:(float_of_int index)
      ~input:(R.Exact_input (`Assoc [ "index", `Int index ]));
    mark_completed_exn
      registry
      ~run_id
      ~outcome:R.Succeeded
      ~elapsed_s:0.1
      ~output:(`Assoc [ "index", `Int index ]));
  let replayed = R.replay path in
  check int "all exact runs survive replay" 80 (List.length (R.list_runs replayed));
  let permissions = (Unix.stat path).Unix.st_perm land 0o777 in
  check int "durable registry is private" 0o600 permissions;
  remove_if_exists path
;;

let test_failed_durable_registration_is_not_published_in_memory () =
  let directory = Filename.temp_dir "exact-lane-runs-dir-" "" in
  let registry = R.create ~path:directory () in
  let failed =
    try
      R.register_running
        registry
        ~run_id:"not-published"
        ~lane:R.Librarian
        ~subject_id:"trace"
        ~actor:"keeper-a"
        ~started_at:1.0
        ~input:(R.Exact_input `Null);
      false
    with
    | Sys_error _ | Unix.Unix_error _ -> true
  in
  check bool "directory cannot be used as durable JSONL" true failed;
  check int "failed registration absent" 0 (List.length (R.list_runs registry));
  Unix.rmdir directory
;;

let test_failed_durable_completion_is_explicitly_visible () =
  let path = Filename.temp_file "exact-lane-completion-failure-" ".jsonl" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"completion-not-published"
    ~lane:R.Librarian
    ~subject_id:"trace"
    ~actor:"keeper-a"
    ~started_at:1.0
    ~input:(R.Exact_input `Null);
  Sys.remove path;
  Unix.mkdir path 0o700;
  let completion =
    R.mark_completed
      registry
      ~run_id:"completion-not-published"
      ~outcome:(R.Failed { code = "model_error"; detail = "typed failure detail" })
      ~elapsed_s:0.1
      ~output:(`String "must-not-publish")
  in
  (match completion with
   | Error (R.Persistence_failed failure) ->
     check bool "failure retains durable detail" true
       (String.trim failure.detail <> "")
   | Error R.Unknown_run -> fail "registered run became unknown"
   | Ok () -> fail "directory unexpectedly received durable completion");
  let run = R.get registry ~run_id:"completion-not-published" |> Option.get in
  check bool "failed completion is not reported as running" true
    (not (String.equal "running" (R.status_label run.status)));
  (match run.status with
   | R.Completion_persistence_failed
       { intended_outcome = R.Failed { code; detail }
       ; output = `String output
       ; failure
       ; _
       } ->
     check string "intended output remains observable" "must-not-publish" output;
     check string "intended failure code remains observable" "model_error" code;
     check string "intended failure detail remains observable" "typed failure detail" detail;
     check bool "persistence failure remains explicit" true
       (String.trim failure.detail <> "")
   | _ -> fail "expected explicit completion persistence failure");
  (match R.run_to_yojson run with
   | `Assoc fields ->
     check bool "serialized persistence error" true
       (List.mem_assoc "persistence_error" fields);
     check bool "serialized persistence state" true
       (List.mem_assoc "persistence_state" fields);
     check (option string) "serialized intended failure code" (Some "model_error")
       (match List.assoc_opt "intended_code" fields with
        | Some (`String value) -> Some value
        | _ -> None);
     check (option string) "serialized intended failure detail" (Some "typed failure detail")
       (match List.assoc_opt "intended_detail" fields with
        | Some (`String value) -> Some value
        | _ -> None)
   | _ -> fail "run serializer must emit an object");
  Unix.rmdir path
;;

let test_observation_reads_do_not_wait_for_durable_writer () =
  let path = Filename.temp_file "exact-lane-read-projection-" ".jsonl" in
  let registry = R.create ~path () in
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
    Unix.close ready_read;
    (try
       let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
       Unix.lockf fd Unix.F_LOCK 0;
       ignore (Unix.write_substring ready_write "x" 0 1 : int);
       Unix.sleepf 0.5;
       Unix.close fd;
       Unix._exit 0
     with
     | _ -> Unix._exit 2)
  | child ->
    Unix.close ready_write;
    let ready = Bytes.create 1 in
    ignore (Unix.read ready_read ready 0 1 : int);
    Unix.close ready_read;
    let rec waitpid_reap pid =
      try Unix.waitpid [] pid with
      | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_reap pid
    in
    Fun.protect
      ~finally:(fun () ->
        (match waitpid_reap child with
         | _, Unix.WEXITED 0 -> ()
         | _, status ->
           failf
             "durable-lock child failed: %s"
             (match status with
              | Unix.WEXITED code -> Printf.sprintf "exit %d" code
              | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
              | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal));
        remove_if_exists path;
        remove_if_exists (Fs_compat.private_jsonl_lock_path path))
      (fun () ->
         Eio_main.run @@ fun env ->
         let clock = Eio.Stdenv.clock env in
         Eio.Switch.run @@ fun sw ->
         let started, set_started = Eio.Promise.create () in
         Eio.Fiber.fork ~sw (fun () ->
           Eio.Promise.resolve set_started ();
           R.register_running
             registry
             ~run_id:"writer-blocked-on-durable-lock"
             ~lane:R.Compaction
             ~subject_id:"trace"
             ~actor:"keeper-a"
             ~started_at:1.0
             ~input:(R.Exact_input `Null));
         Eio.Promise.await started;
         Eio.Time.sleep clock 0.05;
         let read_started_at = Eio.Time.now clock in
         let visible = R.list_runs registry in
         let read_elapsed_s = Eio.Time.now clock -. read_started_at in
         check int "pre-commit projection remains unchanged" 0 (List.length visible);
         check bool "Atomic projection read does not wait for durable writer" true
           (read_elapsed_s < 0.2))
;;

let () =
  run
    "exact_lane_run_registry"
    [ ( "registry"
      , [ test_case "durable exact evidence" `Quick test_round_trip_preserves_exact_evidence
        ; test_case "running shape" `Quick test_running_shape_has_no_invented_completion
        ; test_case "current storage generation" `Quick test_current_storage_generation
        ; test_case "exact history is not cross-lane pruned" `Quick
            test_exact_history_is_not_pruned_across_lanes
        ; test_case "failed durable registration is not published" `Quick
            test_failed_durable_registration_is_not_published_in_memory
        ; test_case "failed durable completion is explicitly visible" `Quick
            test_failed_durable_completion_is_explicitly_visible
        ; test_case "observation reads do not wait for durable writer" `Quick
            test_observation_reads_do_not_wait_for_durable_writer
        ] )
    ]
