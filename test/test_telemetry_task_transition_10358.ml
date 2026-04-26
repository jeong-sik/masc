(** Regression coverage for #10358 task lifecycle telemetry attrition. *)

open Masc_mcp

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally:restore (fun () ->
    (match value_opt with
     | Some value -> Unix.putenv name value
     | None -> Unix.putenv name "");
    f ())
;;

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      with_env "MASC_STORAGE_TYPE" None (fun () ->
        with_env "MASC_POSTGRES_URL" None (fun () ->
          with_env "DATABASE_URL" None (fun () ->
            with_env "SUPABASE_DB_URL" None (fun () -> with_env "SB_PG_URL" None f))))))
;;

let make_ctx base_path =
  let config = Coord.default_config base_path in
  let agent_name = "telemetry-agent" in
  ignore (Coord.init config ~agent_name:(Some agent_name));
  { Tool_task.config; agent_name; sw = None }
;;

let make_peer_ctx config agent_name =
  ignore (Coord.join config ~agent_name ~capabilities:[] ());
  { Tool_task.config; agent_name; sw = None }
;;

let run_transition ctx ~task_id ~action ?(notes = "") () =
  let args =
    `Assoc
      [ "task_id", `String task_id; "action", `String action; "notes", `String notes ]
  in
  match Tool_task.dispatch ctx ~name:"masc_transition" ~args with
  | Some (true, _) -> ()
  | Some (false, msg) -> Alcotest.fail msg
  | None -> Alcotest.fail "masc_transition dispatch returned None"
;;

let event_exists predicate config =
  Telemetry_eio.read_all_events config
  |> List.exists (fun (record : Telemetry_eio.event_record) -> predicate record.event)
;;

let test_masc_transition_claim_done_emits_task_lifecycle () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
    let ok, result =
      Tool_task.handle_add_task ctx (`Assoc [ "title", `String "Telemetry task" ])
    in
    if not ok then Alcotest.fail result;
    run_transition ctx ~task_id:"task-001" ~action:"claim" ();
    run_transition
      ctx
      ~task_id:"task-001"
      ~action:"done"
      ~notes:"Telemetry lifecycle regression proof completed."
      ();
    let verifier_ctx = make_peer_ctx ctx.config "telemetry-verifier" in
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
    if not completed
    then
      run_transition
        verifier_ctx
        ~task_id:"task-001"
        ~action:"approve"
        ~notes:"Verification approved for telemetry lifecycle proof."
        ();
    let completed =
      event_exists
        (function
          | Telemetry_eio.Task_completed { task_id = "task-001"; success = true; _ } ->
            true
          | _ -> false)
        ctx.config
    in
    Alcotest.(check bool) "claim emits Task_started" true started;
    Alcotest.(check bool) "done/approve emits Task_completed" true completed)
;;

let () =
  Alcotest.run
    "Telemetry_task_transition_10358"
    [ ( "telemetry"
      , [ Alcotest.test_case
            "masc_transition claim->done emits task lifecycle telemetry"
            `Quick
            test_masc_transition_claim_done_emits_task_lifecycle
        ] )
    ]
;;
