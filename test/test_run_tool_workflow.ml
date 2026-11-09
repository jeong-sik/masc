open Alcotest

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path

let with_workspace ?(memory = false) f =
  let path = Filename.temp_file "masc-run-tool-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Masc.Workspace.default_config path in
    let config =
      if memory then
        { config with Workspace_utils.backend = Workspace_utils.Memory (Backend.Memory.create ()) }
      else config
    in
    ignore (Masc.Workspace.init config ~agent_name:None);
    f config)

let call config name fields =
  let ctx : Masc.Tool_run.context = { config; agent_name = Some "planner" } in
  match Masc.Tool_run.dispatch ctx ~name ~args:(`Assoc fields) with
  | Some result -> result
  | None -> fail "run tool was not dispatched"

let require_success (result : Tool_result.result) =
  match result with
  | Tool_result.Completed output -> output.data
  | Tool_result.Deferred _ | Tool_result.Failed _ ->
    fail (Tool_result.message result)

let require_failure expected_class expected_effect (result : Tool_result.result) =
  match result with
  | Tool_result.Failed failure ->
    check bool "failure class" true (failure.class_ = expected_class);
    check bool "effect disposition" true (failure.effect_disposition = expected_effect)
  | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "expected failure"

let test_initialize_after_missing_plan () =
  with_workspace @@ fun config ->
  let task = "task-plan" in
  let args = [ "task_id", `String task; "plan", `String "# Plan\n- Read the source" ] in
  require_failure Tool_result.Workflow_rejection Tool_result.Proven_pre_effect
    (call config "masc_run_plan" args);
  let run_path = Masc.Run_eio.run_json_path config task in
  check bool "missing run is not created by plan update" false (Sys.file_exists run_path);
  let plan_path = Filename.concat (Filename.dirname run_path) "plan.md" in
  check bool "rejected plan is not written" false (Sys.file_exists plan_path);
  ignore (require_success (call config "masc_run_init"
    [ "task_id", `String task; "agent_name", `String "planner" ]));
  ignore (require_success (call config "masc_run_plan" args));
  let actual = require_success (call config "masc_run_get" [ "task_id", `String task ]) in
  let open Yojson.Safe.Util in
  check string "same task plan read back" "# Plan\n- Read the source"
    (actual |> member "plan" |> to_string);
  check string "same task owner retained" "planner"
    (actual |> member "run" |> member "agent_name" |> to_string)

let test_invalid_record_is_not_a_missing_precondition () =
  with_workspace @@ fun config ->
  let task = "task-invalid" in
  ignore (require_success (call config "masc_run_init" [ "task_id", `String task ]));
  let run_path = Masc.Run_eio.run_json_path config task in
  let plan_path = Filename.concat (Filename.dirname run_path) "plan.md" in
  let previous_plan = Fs_compat.load_file plan_path in
  Fs_compat.save_file run_path "{}";
  require_failure Tool_result.Runtime_failure Tool_result.Proven_pre_effect
    (call config "masc_run_plan" [ "task_id", `String task; "plan", `String "replacement" ]);
  check string "damaged record is preserved" "{}" (Fs_compat.load_file run_path);
  check string "plan mirror is preserved" previous_plan (Fs_compat.load_file plan_path)

let test_storage_failure_does_not_claim_pre_effect () =
  with_workspace @@ fun config ->
  let task = "task-storage" in
  ignore (require_success (call config "masc_run_init" [ "task_id", `String task ]));
  let run_path = Masc.Run_eio.run_json_path config task in
  let previous_record = Fs_compat.load_file run_path in
  let plan_path = Filename.concat (Filename.dirname run_path) "plan.md" in
  Unix.unlink plan_path;
  Unix.mkdir plan_path 0o700;
  require_failure Tool_result.Runtime_failure Tool_result.Effect_outcome_unknown
    (call config "masc_run_plan" [ "task_id", `String task; "plan", `String "replacement" ]);
  check string "failed write does not replace run metadata" previous_record
    (Fs_compat.load_file run_path)

let test_init_metadata_failure_is_not_success () =
  with_workspace @@ fun config ->
  let task = "task-init-metadata" in
  let run_path = Masc.Run_eio.run_json_path config task in
  Workspace_utils.mkdir_p run_path;
  require_failure Tool_result.Runtime_failure Tool_result.Effect_outcome_unknown
    (call config "masc_run_init" [ "task_id", `String task ]);
  check bool "unwritable metadata target is preserved" true (Sys.is_directory run_path);
  let plan_path = Filename.concat (Filename.dirname run_path) "plan.md" in
  check bool "partial initialization is not called pre-effect" true (Sys.file_exists plan_path)

let test_plan_metadata_failure_preserves_partial_effect () =
  with_workspace @@ fun config ->
  let task = "task-plan-metadata" in
  ignore (require_success (call config "masc_run_init" [ "task_id", `String task ]));
  let run_path = Masc.Run_eio.run_json_path config task in
  let previous_record = Fs_compat.load_file run_path in
  let directory = Filename.dirname run_path in
  let plan_path = Filename.concat directory "plan.md" in
  Unix.chmod directory 0o555;
  Fun.protect ~finally:(fun () -> Unix.chmod directory 0o700) (fun () ->
    (* Existing plan.md remains writable, but creating an atomic metadata
       replacement in its read-only parent must return a storage Error. *)
    (match Workspace_utils.write_json_commit_result config run_path (`Assoc []) with
     | Error _ -> ()
     | Ok _ -> fail "fault injection did not prevent the authoritative write");
    require_failure Tool_result.Runtime_failure Tool_result.Effect_outcome_unknown
      (call config "masc_run_plan" [ "task_id", `String task; "plan", `String "replacement" ]);
    check string "metadata retains the previous committed record" previous_record
      (Fs_compat.load_file run_path);
    check string "written plan is retained as a partial effect" "replacement"
      (Fs_compat.load_file plan_path))

let test_memory_commit_survives_metadata_mirror_failure () =
  with_workspace ~memory:true @@ fun config ->
  let task = "task-memory-mirror" in
  let run_path = Masc.Run_eio.run_json_path config task in
  Workspace_utils.mkdir_p run_path;
  ignore (require_success (call config "masc_run_init" [ "task_id", `String task ]));
  ignore (require_success (call config "masc_run_plan"
    [ "task_id", `String task; "plan", `String "committed plan" ]));
  let actual = require_success (call config "masc_run_get" [ "task_id", `String task ]) in
  let open Yojson.Safe.Util in
  check string "authoritative metadata survives mirror failure" "committed plan"
    (actual |> member "run" |> member "plan" |> to_string);
  check string "plan remains readable" "committed plan" (actual |> member "plan" |> to_string);
  check bool "metadata mirror remains unwritable" true (Sys.is_directory run_path)

(* masc_run_list: the rows the model reads and the limit it may pass. *)

let list_limit_declaration () =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name "masc_run_list")
      Masc.Tool_run.schemas
  with
  | None -> fail "masc_run_list is not published"
  | Some schema ->
    let open Yojson.Safe.Util in
    let limit = schema.input_schema |> member "properties" |> member "limit" in
    ( limit |> member "minimum" |> to_int
    , limit |> member "default" |> to_int
    , limit |> member "maximum" |> to_int )

let write_runs config count =
  for i = 1 to count do
    let task_id = Printf.sprintf "task-%03d" i in
    (* A higher number was updated later. *)
    let updated_at = Printf.sprintf "2026-01-01T00:%02d:%02dZ" (i / 60) (i mod 60) in
    match
      Masc.Run_eio.write_run config
        { Masc.Run_eio.task_id
        ; agent_name = None
        ; plan = "plan text of " ^ task_id
        ; created_at = "2026-01-01T00:00:00Z"
        ; updated_at
        }
    with
    | Ok () -> ()
    | Error e -> fail (Masc.Run_eio.error_to_string e)
  done

let rows_of data =
  let open Yojson.Safe.Util in
  data |> member "runs" |> to_list

let require_failed (result : Tool_result.result) =
  match result with
  | Tool_result.Failed _ -> ()
  | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "expected the call to be refused"

let test_run_list_answers_what_its_schema_declares () =
  with_workspace @@ fun config ->
  let minimum, default, maximum = list_limit_declaration () in
  write_runs config (maximum + 10);
  let open Yojson.Safe.Util in
  let by_default = require_success (call config "masc_run_list" []) in
  check int "count is every run" (maximum + 10) (by_default |> member "count" |> to_int);
  check int "no limit returns the declared default" default
    (by_default |> member "shown" |> to_int);
  check int "shown matches the rows" default (List.length (rows_of by_default));
  let newest = List.hd (rows_of by_default) in
  check string "newest update first" (Printf.sprintf "task-%03d" (maximum + 10))
    (newest |> member "task_id" |> to_string);
  check int "a row names the plan's size, not its text"
    (String.length (Printf.sprintf "plan text of task-%03d" (maximum + 10)))
    (newest |> member "plan_bytes" |> to_int);
  check bool "no plan text in a row" false (List.mem_assoc "plan" (to_assoc newest));
  let at_maximum = require_success (call config "masc_run_list" [ "limit", `Int maximum ]) in
  check int "the declared maximum is accepted" maximum (List.length (rows_of at_maximum));
  let at_minimum = require_success (call config "masc_run_list" [ "limit", `Int minimum ]) in
  check int "the declared minimum is accepted" minimum (List.length (rows_of at_minimum));
  require_failed (call config "masc_run_list" [ "limit", `Int (maximum + 1) ]);
  require_failed (call config "masc_run_list" [ "limit", `Int (minimum - 1) ])

let () = run "Run tool workflow" [ "plan", [
  test_case "missing init then successful plan readback" `Quick test_initialize_after_missing_plan;
  test_case "invalid stored record remains a runtime failure" `Quick test_invalid_record_is_not_a_missing_precondition;
  test_case "storage failure remains uncertain" `Quick test_storage_failure_does_not_claim_pre_effect;
  test_case "metadata init failure is not success" `Quick test_init_metadata_failure_is_not_success;
  test_case "metadata plan failure preserves partial effect" `Quick test_plan_metadata_failure_preserves_partial_effect;
  test_case "memory commit survives metadata mirror failure" `Quick test_memory_commit_survives_metadata_mirror_failure;
]; "list", [
  test_case "answers what its schema declares" `Quick test_run_list_answers_what_its_schema_declares;
] ]
