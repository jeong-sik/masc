(** Regression coverage for #10358 task lifecycle telemetry attrition. *)

open Masc

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.putenv name "");
      f ())

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None f)

let with_default_runtime_id_hook f =
  let previous = Atomic.get Workspace_hooks.get_default_runtime_id_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.get_default_runtime_id_fn previous)
    (fun () ->
      Atomic.set Workspace_hooks.get_default_runtime_id_fn
        (fun () -> "test-evaluator-runtime");
      f ())

let make_ctx base_path =
  let config = Workspace.default_config base_path in
  let agent_name = "telemetry-agent" in
  ignore (Workspace.init config ~agent_name:(Some agent_name));
  { Task.Tool.config; agent_name; sw = None }

(* [evidence_refs]: completions require evidence since #23738 (Gate 0 /
   Task_completion_gate); this test covers the telemetry lifecycle, not the
   evidence gate, so the done transition carries a real ref. *)
let run_transition ctx ~task_id ~action ?(notes = "") ?(evidence_refs = []) () =
  let base_args =
    [
      ("task_id", `String task_id);
      ("action", `String action);
      ("notes", `String notes);
    ]
  in
  let args =
    match evidence_refs with
    | [] -> `Assoc base_args
    | refs ->
      `Assoc
        (base_args
         @ [
             ( "handoff_context",
               `Assoc
                 [
                   ("summary", `String notes);
                   ("evidence_refs", `List (List.map (fun r -> `String r) refs));
                 ] );
           ])
  in
  match Task.Tool.dispatch ctx ~name:"masc_transition" ~args with
  | Some result ->
      if not (Tool_result.is_success result) then Alcotest.fail ((Tool_result.message result))
  | None -> Alcotest.fail "masc_transition dispatch returned None"

let event_exists predicate config =
  Telemetry_eio.read_all_events config
  |> List.exists (fun (record : Telemetry_eio.event_record) ->
    predicate record.event)

let test_masc_transition_claim_done_emits_task_lifecycle () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous_default_runtime =
    Atomic.get Workspace_hooks.get_default_runtime_id_fn
  in
  let previous_observe_task_transition =
    Atomic.get Workspace_hooks.observe_task_transition_fn
  in
  Atomic.set Workspace_hooks.get_default_runtime_id_fn
    (fun () -> "test-evaluator-runtime");
  Atomic.set Workspace_hooks.observe_task_transition_fn
    (fun config ~agent_name ~task_id ~transition ~details:_ ->
      match transition with
      | Masc_domain.Claim | Masc_domain.Start ->
        Telemetry_eio.track_task_started config ~task_id ~agent_id:agent_name
      | Masc_domain.Done_action | Masc_domain.Approve_verification ->
        Telemetry_eio.track_task_completed config ~task_id ~duration_ms:0 ~success:true
      | Masc_domain.Cancel ->
        Telemetry_eio.track_task_completed config ~task_id ~duration_ms:0 ~success:false
      | Masc_domain.Release
      | Masc_domain.Submit_for_verification
      | Masc_domain.Reject_verification -> ());
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.get_default_runtime_id_fn previous_default_runtime;
      Atomic.set Workspace_hooks.observe_task_transition_fn
        previous_observe_task_transition)
    (fun () ->
  with_isolated_runtime_env (fun () ->
    let base_path =
      Filename.concat
        (Filename.get_temp_dir_name ())
        (Printf.sprintf
           "masc-telemetry-transition-10358-%d"
           (int_of_float (Unix.gettimeofday () *. 1000.0)))
    in
    Unix.mkdir base_path 0o755;
    let ctx = make_ctx base_path in
    let result =
      Task.Tool.handle_add_task ~tool_name:"test_tool" ~start_time:0.0 ctx (`Assoc [ ("title", `String "Telemetry task") ])
    in
    if not (Tool_result.is_success result) then Alcotest.fail (Tool_result.message result);
    run_transition ctx ~task_id:"task-001" ~action:"claim" ();
    run_transition ctx ~task_id:"task-001" ~action:"start" ();
    run_transition ctx ~task_id:"task-001" ~action:"done"
      ~notes:"Telemetry lifecycle regression proof completed."
      ~evidence_refs:[ "test/test_telemetry_task_transition_10358.ml" ] ();
    let started =
      event_exists
        (function
          | Telemetry_eio.Task_started { task_id = "task-001"; agent_id } ->
            String.equal agent_id ctx.agent_name
          | _ -> false)
        ctx.config
    in
    let completed =
      event_exists
        (function
          | Telemetry_eio.Task_completed { task_id = "task-001"; success = true; _ } ->
            true
          | _ -> false)
        ctx.config
    in
    Alcotest.(check bool) "claim emits Task_started" true started;
    Alcotest.(check bool) "done emits Task_completed" true completed))

let () =
  Alcotest.run "Telemetry_task_transition_10358"
    [
      ( "telemetry",
        [
          Alcotest.test_case
            "masc_transition claim->start->done emits task lifecycle telemetry"
            `Quick
            test_masc_transition_claim_done_emits_task_lifecycle;
        ] );
    ]
