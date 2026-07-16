(** Regression coverage for #10358 task lifecycle telemetry attrition. *)

open Masc

(* The [done] transition runs the configured-LLM completion review (#24332),
   which renders the [verification.anti_rationalization] registry prompt. This
   executable exercises the real tool-dispatch path, so it pins prompt
   resolution to the repo's own prompt files — the same idiom
   test_tool_task_coverage uses so the prompt resolves whether run under dune
   (DUNE_SOURCEROOT) or as a bare executable. *)
let has_prompt_root path =
  Sys.file_exists
    (Filename.concat path "config/prompts/verification.anti_rationalization.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path then path
      else
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent
    in
    ascend (Sys.getcwd ())

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_root ()) "config/prompts")

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

(* [evidence_refs] are transported to the LLM completion reviewer. This test
   covers the telemetry lifecycle, so it supplies representative reviewer
   context without asserting a local evidence-classification rule. *)
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
  let previous_reviewer =
    Atomic.get Task.Anti_rationalization.run_llm_reviewer_fn
  in
  (* The completion verdict comes from the configured LLM reviewer; stub it to a
     structured APPROVE so the [done] transition reaches its terminal state and
     emits the lifecycle telemetry under test. *)
  Atomic.set Task.Anti_rationalization.run_llm_reviewer_fn
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (Some Task.Anti_rationalization.Approve));
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
        previous_observe_task_transition;
      Atomic.set Task.Anti_rationalization.run_llm_reviewer_fn previous_reviewer)
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
