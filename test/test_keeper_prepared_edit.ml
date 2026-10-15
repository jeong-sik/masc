open Alcotest
open Masc

module FS = Keeper_tool_filesystem_runtime

let get = function Ok value -> value | Error detail -> fail detail
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun output -> output_string output bytes)
;;

let rec remove path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
;;

let fixture operation =
  let base = Filename.temp_file "masc-prepared-edit-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  let base = Unix.realpath base in
  Fun.protect ~finally:(fun () -> remove base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Masc_test_deps.init_eio_clock ~sw env;
  Masc_test_deps.ensure_rng_initialized ();
  let config = Workspace.default_config base in
  let meta = Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String "prepared-edit"; "trace_id", `String "prepared-edit-trace"]) |> get in
  let meta = {meta with sandbox_profile = Keeper_types_profile.Docker} in
  let root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p root;
  Masc_test_deps.with_publication_recovery_registry ~sw ~fs:env#fs ~registry_root:base
  @@ fun registry ->
  let recovery : Keeper_publication_recovery_availability.turn_context =
    {provider = Masc_test_deps.publication_recovery_provider registry; keeper_name = meta.name} in
  operation env sw config meta recovery root
;;

let args path before after =
  `Assoc ["path", `String path; "mode", `String "patch"
         ; "old_string", `String before; "new_string", `String after]
;;

let prepare sw config meta input =
  match FS.prepare_edit ~sw ~config ~meta ~args:input with
  | Ok (Some prepared) -> prepared
  | Ok None -> fail "existing regular Edit resource was not prepared"
  | Error error -> fail (FS.edit_preparation_error_to_execution error).raw_output
;;

let consume config meta recovery prepared input =
  FS.handle_file_write_with_outcome ~turn_sandbox_factory:None ~config ~meta
    ~publication_recovery:recovery ?prepared_edit:prepared ~args:input ()
;;

let completed result =
  match result.Keeper_tool_execution.disposition with
  | Tool_result.Completed () -> ()
  | Tool_result.Deferred () | Tool_result.Failed _ -> fail result.raw_output
;;

let failed result =
  match result.Keeper_tool_execution.disposition with
  | Tool_result.Failed _ -> ()
  | Tool_result.Completed () | Tool_result.Deferred () -> fail "changed prepared authority performed an Edit"
;;

let batch env config meta recovery inputs =
  let to_sdk result = match result.Keeper_tool_execution.disposition with
    | Tool_result.Completed () ->
      Ok {Agent_core.Types.content = result.raw_output; content_blocks = None; _meta = None}
    | Tool_result.Deferred () | Tool_result.Failed _ ->
      Error {Agent_core.Types.message = result.raw_output; recoverable = false
            ; error_class = Some Agent_core.Types.Unknown} in
  let descriptor = Agent_core.Tool.ordinary_descriptor_scoped ~prepare:(fun ~sw input ->
    match FS.prepare_edit ~sw ~config ~meta ~args:input with
    | Error error -> FS.edit_preparation_error_to_execution error |> to_sdk |> Result.map (fun _ -> None)
    | Ok None -> Ok None
    | Ok (Some prepared) ->
      (match FS.prepared_edit_scopes prepared with
       | [] -> fail "prepared Edit has no occupied resource"
       | scope :: additional_scopes ->
         Ok (Some (Agent_core.Tool.scoped_call ~scope ~additional_scopes
           (fun _ input -> consume config meta recovery (Some prepared) input |> to_sdk))))) in
  let schema = Agent_core.Types.tool_schema_of_input_schema ~name:"fixture_edit"
      ~description:"Exercise the actual existing-file Edit producer."
      ~input_schema:(`Assoc ["type", `String "object"]) () |> get in
  let tool = Agent_core.Tool.of_schema ~descriptor schema
      (fun _ input -> consume config meta recovery None input |> to_sdk) in
  let agent = Agent_core.Agent.create ~tools:[tool] ~net:env#net
      ~config:(Agent_core.Types.default_config ~model:"fixture") () in
  let options = Agent_core.Agent.options agent in
  let calls = List.mapi (fun index input -> Agent_core.Types.ToolUse
      {id = "edit-" ^ string_of_int index; name = "fixture_edit"; input}) inputs in
  match Agent_core.Agent_tools.execute_tools ~context:(Agent_core.Agent.context agent)
      ~tools:[tool] ~hooks:Agent_core.Hooks.empty ~event_bus:options.event_bus ~tracer:options.tracer
      ~agent_name:(Agent_core.Agent.state agent).config.name ~turn_count:2
      ~usage:(Agent_core.Agent.state agent).usage calls with
  | Ok report ->
    List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
      match row.outcome with
      | Agent_core.Types.Tool_succeeded -> ()
      | Tool_failed _ -> fail row.content) report.completed_results;
    report.completed_results
  | Error _ -> fail "Edit batch failed outside its tool results"
;;

let test_disjoint_actual_edits_overlap () =
  fixture @@ fun env _sw config meta recovery root ->
  let left = Filename.concat root "left/file" and right = Filename.concat root "right/file" in
  write left "left-before"; write right "right-before";
  let both, resolve_both = Eio.Promise.create () in
  let entered = ref 0 in
  let rows = FS.For_testing.with_before_write_authorization (fun () ->
      incr entered;
      if !entered = 2 then Eio.Promise.resolve resolve_both ();
      Eio.Promise.await both)
      (fun () -> batch env config meta recovery
        [args left "left-before" "left-after"; args right "right-before" "right-after"]) in
  check int "both actual authorization boundaries overlapped" 2 !entered;
  check string "left actual file" "left-after" (read left);
  check string "right actual file" "right-after" (read right);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    let schedule = Agent_core.Tool_contract.Invocation.schedule row.invocation in
    check int "actual disjoint wave contains both calls" 2 schedule.batch_size;
    check bool "effect stays Concurrent without claiming readonly" true
      (schedule.execution_mode = Agent_core.Tool_contract.Concurrent)) rows
;;

let test_successive_patches_use_current_source () =
  fixture @@ fun env _sw config meta recovery root ->
  let path = Filename.concat root "same/file" in
  write path "first";
  let rows = batch env config meta recovery [args path "first" "second"; args path "second" "third"] in
  check string "later patch reads the earlier atomic replacement" "third" (read path);
  match rows with
  | [first; second] ->
    let schedule row = Agent_core.Tool_contract.Invocation.schedule
        row.Agent_core.Agent_tools.invocation in
    check bool "conflicting occurrence follows the prior wave" true
      ((schedule first).batch_index < (schedule second).batch_index)
  | [] | [_] | _ :: _ :: _ :: _ -> fail "successive Edit results changed"
;;

let test_directory_alias_keeps_patch_order () =
  fixture @@ fun env _sw config meta recovery root ->
  let directory = Filename.concat root "real" in
  let path = Filename.concat directory "file" in
  write path "first";
  let alias = Filename.concat root "alias" in
  Unix.symlink "real" alias;
  let rows = batch env config meta recovery
      [args path "first" "second"; args (Filename.concat alias "file") "second" "third"] in
  check string "alias patch consumes the original predecessor bytes" "third" (read path);
  List.iter (fun (row : Agent_core.Agent_tools.tool_execution_result) ->
    check int "physical aliases do not share a concurrent wave" 1
      (Agent_core.Tool_contract.Invocation.schedule row.invocation).batch_size) rows
;;

let test_parent_swap_and_input_or_owner_change_do_not_write () =
  fixture @@ fun _env sw config meta recovery root ->
  let directory = Filename.concat root "original" in
  let path = Filename.concat directory "file" in
  write path "original";
  let input = args path "original" "changed" in
  let prepared = prepare sw config meta input in
  check string "preparation never edits the source" "original" (read path);
  consume config meta recovery (Some prepared) (args path "original" "another") |> failed;
  let other = {meta with current_task_id = Some (Keeper_id.Task_id.of_string "another-task" |> get)} in
  consume config other recovery (Some prepared) input |> failed;
  let retained = directory ^ "-retained" in
  Unix.rename directory retained;
  write path "replacement";
  consume config meta recovery (Some prepared) input |> failed;
  check string "replacement parent remains untouched" "replacement" (read path);
  check string "retained original remains untouched" "original" (read (Filename.concat retained "file"))
;;

let test_prepared_edit_retains_manual_gate () =
  fixture @@ fun _env sw config meta recovery _root ->
  Keeper_approval_queue.For_testing.reset_runtime_state ();
  Eio.Switch.on_release sw Keeper_approval_queue.For_testing.reset_runtime_state;
  (match Keeper_approval_queue.install_persistence ~base_path:config.Workspace.base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue_result.install_error_to_string error));
  Keeper_gate_mode.set config ~actor:"fixture" Keeper_gate_mode.Manual |> get |> ignore;
  let path = Filename.concat config.base_path "project-file" in
  write path "before";
  let input = args path "before" "after" in
  let prepared = prepare sw config meta input in
  let result = consume config meta recovery (Some prepared) input in
  (match result.disposition with
   | Tool_result.Deferred () -> ()
   | Tool_result.Completed () | Tool_result.Failed _ -> fail result.raw_output);
  check string "resource preparation grants no Gate permission" "before" (read path)
;;

let test_cancelled_prepared_edit_releases_for_a_later_call () =
  fixture @@ fun _env sw config meta recovery root ->
  let path = Filename.concat root "cancelled/file" in
  write path "before";
  let input = args path "before" "after" in
  let entered, resolve_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  (match Eio.Switch.run (fun child ->
    let prepared = prepare child config meta input in
    Eio.Fiber.fork ~sw:child (fun () ->
      FS.For_testing.with_before_write_authorization (fun () ->
        Eio.Promise.resolve resolve_entered (); Eio.Promise.await never)
        (fun () -> consume config meta recovery (Some prepared) input |> completed));
    Eio.Promise.await entered;
    Eio.Switch.fail child Exit) with
   | () -> fail "caller cancellation did not propagate"
   | exception Exit -> ());
  check string "cancelled authorization performed no effect" "before" (read path);
  let prepared = prepare sw config meta input in
  consume config meta recovery (Some prepared) input |> completed;
  check string "later original call is not held by cancelled resources" "after" (read path)
;;

let () = run "prepared actual Edit resources"
  ["actual filesystem and SDK", [
    test_case "disjoint actual Edits overlap" `Quick test_disjoint_actual_edits_overlap;
    test_case "conflicting patches read current predecessor bytes" `Quick test_successive_patches_use_current_source;
    test_case "directory aliases retain planned order" `Quick test_directory_alias_keeps_patch_order;
    test_case "changed owner input or parent cannot write" `Quick test_parent_swap_and_input_or_owner_change_do_not_write;
    test_case "preparation retains manual Gate" `Quick test_prepared_edit_retains_manual_gate;
    test_case "caller cancellation releases prepared Edit" `Quick test_cancelled_prepared_edit_releases_for_a_later_call]]
