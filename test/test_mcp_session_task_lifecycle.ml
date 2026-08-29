(** Isolated MCP session-bound Task lifecycle smoke.

    This exercises protocol admission, session identity, typed tool dispatch,
    workspace persistence, and Task verification submission once inside an
    isolated workspace. It is not evidence for the product-level Keeper Full
    Lifecycle contract. *)

open Alcotest

module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server

let () = Mirage_crypto_rng_unix.use_default ()

(* The verification hooks in [Workspace_hooks] default to a fail-closed
   [Error "... hook is not installed"], so a Task submission reaches durable
   storage only in a process that installed the real implementations.
   Production installs them through [Workspace_metric_hooks.install] in
   [Mcp_server.create_state_eio]'s [on_backend_ready] callback; the harness
   below builds its config through the non-Eio [For_testing.create_state],
   which never fires that callback. Installing the same function here is what
   makes [submit_for_verification] exercise the production persistence
   boundary instead of the unwired default. *)
let () = Masc.Workspace_metric_hooks.install ()

let request ~id ~method_ params =
  Yojson.Safe.to_string
    (`Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", `Int id)
      ; ("method", `String method_)
      ; ("params", params)
      ])

let initialize_request =
  request ~id:1 ~method_:"initialize"
    (`Assoc
      [ ("protocolVersion", `String "2025-11-25")
      ; ("capabilities", `Assoc [])
      ; ( "clientInfo"
        , `Assoc
            [ ("name", `String "masc-session-task-smoke")
            ; ("version", `String "1")
            ] )
      ])

let initialized_notification =
  Yojson.Safe.to_string
    (`Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("method", `String "notifications/initialized")
      ; ("params", `Assoc [])
      ])

let tool_request ~id ~name arguments =
  request ~id ~method_:"tools/call"
    (`Assoc
      [ ("name", `String name)
      ; ("arguments", arguments)
      ])

let result_fields_exn label = function
  | `Assoc response_fields ->
    (match List.assoc_opt "result" response_fields with
     | Some (`Assoc result_fields) -> result_fields
     | Some _ -> failf "%s returned a non-object result" label
     | None ->
       failf "%s returned no result: %s" label
         (Yojson.Safe.to_string (`Assoc response_fields)))
  | response ->
    failf "%s returned a non-object response: %s" label
      (Yojson.Safe.to_string response)

let check_protocol_success label response =
  ignore (result_fields_exn label response)

let check_tool_success label response =
  let fields = result_fields_exn label response in
  match List.assoc_opt "isError" fields with
  | Some (`Bool false) -> ()
  | Some (`Bool true) ->
    failf "%s returned a typed tool error: %s" label
      (Yojson.Safe.to_string response)
  | _ -> failf "%s omitted result.isError: %s" label
           (Yojson.Safe.to_string response)

let check_tool_failure label ~failure_class response =
  let fields = result_fields_exn label response in
  (match List.assoc_opt "isError" fields with
   | Some (`Bool true) -> ()
   | _ ->
     failf "%s did not return an MCP tool error: %s" label
       (Yojson.Safe.to_string response));
  let actual_failure_class =
    match List.assoc_opt "_meta" fields with
    | Some (`Assoc meta_fields) -> (
      match List.assoc_opt Masc.Mcp_server.tool_call_meta_key meta_fields with
      | Some (`Assoc call_fields) -> (
        match List.assoc_opt "failure_class" call_fields with
        | Some (`String value) -> value
        | _ -> failf "%s omitted the call meta's failure_class" label)
      | _ -> failf "%s omitted the call meta entry" label)
    | _ -> failf "%s omitted result._meta" label
  in
  check string (label ^ " failure class") failure_class actual_failure_class

let structured_content_exn label response =
  let fields = result_fields_exn label response in
  match List.assoc_opt "structuredContent" fields with
  | Some structured_content -> structured_content
  | None ->
    failf "%s omitted result.structuredContent: %s" label
      (Yojson.Safe.to_string response)

let status_snapshot_exn response =
  let open Yojson.Safe.Util in
  structured_content_exn "masc_status" response |> member "snapshot" |> to_string

let task_exn config =
  match Masc.Workspace.get_tasks_raw config with
  | [ task ] -> task
  | tasks -> failf "expected one synthetic task, got %d" (List.length tasks)

let test_session_task_lifecycle () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = Filename.temp_dir "mcp_session_task_smoke_" "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let session_id = "session-task-smoke" in
      let call request =
        Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id state request
      in

      call initialize_request |> check_protocol_success "initialize";
      (match call initialized_notification with
       | `Null -> ()
       | response ->
         failf
           "notifications/initialized was not accepted as a notification: %s"
           (Yojson.Safe.to_string response));

      call
        (tool_request ~id:2 ~name:"masc_start"
           (`Assoc
             [ ("path", `String base_path)
             ; ("task_title", `String "Synthetic MCP Task lifecycle")
             ; ("_agent_name", `String "session-task-smoke")
             ]))
      |> check_tool_success "masc_start";

      let config = Mcp_server.workspace_config state in
      let claimed_task = task_exn config in
      (match claimed_task.Masc_domain.task_status with
       | Masc_domain.Claimed { assignee; _ } ->
         check string "task owner" "session-task-smoke" assignee
       | status ->
         failf "masc_start did not claim the task: %s"
           (Masc_domain.task_status_to_string status));
      check (option string) "current task persisted"
        (Some claimed_task.id)
        (Masc.Task.Planning_eio.get_current_task config);

      let status_response =
        call (tool_request ~id:3 ~name:"masc_status" (`Assoc []))
      in
      check_tool_success "masc_status" status_response;
      let expected_identity_line =
        Printf.sprintf
          "🧭 You: agent=session-task-smoke | bound=yes | owned=%s | current=%s"
          claimed_task.id
          claimed_task.id
      in
      check bool "status projects session-bound identity and claimed task" true
        (status_snapshot_exn status_response
         |> String.split_on_char '\n'
         |> List.exists (String.equal expected_identity_line));

      call
        (tool_request ~id:4 ~name:"masc_transition"
           (`Assoc
             [ ("task_id", `String claimed_task.id)
             ; ("action", `String "submit_for_verification")
             ; ( "notes"
               , `String
                   "completion_notes: Synthetic MCP Task lifecycle completed. \
                    reviewable_evidence_ref: note:session lifecycle smoke passed."
               )
             ]))
      |> check_tool_success "masc_transition submit_for_verification";

      let submitted_task = task_exn config in
      (match submitted_task.Masc_domain.task_status with
       | Masc_domain.AwaitingVerification { assignee; verification_id; _ } ->
         check string "submission owner" "session-task-smoke" assignee;
         check bool "verification id persisted" true
           (String.trim verification_id <> "");
         check bool "verification request persisted" true
           (Sys.file_exists
              (Workspace_verification_store.request_path base_path verification_id))
       | status ->
         failf "task did not reach awaiting_verification: %s"
           (Masc_domain.task_status_to_string status));
      check (option string) "current task cleared" None
        (Masc.Task.Planning_eio.get_current_task config))

let test_task_creation_failure_remains_typed_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = Filename.temp_dir "mcp_session_task_failure_" "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let call request =
        Mcp_eio.handle_request
          ~clock
          ~sw
          ~mcp_session_id:"session-task-failure"
          state
          request
      in
      call initialize_request |> check_protocol_success "initialize";
      (match call initialized_notification with
       | `Null -> ()
       | response ->
         failf
           "notifications/initialized was not accepted as a notification: %s"
           (Yojson.Safe.to_string response));
      call
        (tool_request ~id:2 ~name:"masc_start"
           (`Assoc
             [ ("path", `String base_path)
             ; ("_agent_name", `String "session-task-failure")
             ]))
      |> check_tool_success "masc_start bootstrap";
      let config = Mcp_server.workspace_config state in
      let backlog_path = Masc.Workspace.backlog_path config in
      Fs_compat.save_file backlog_path "{invalid-primary";
      Fs_compat.save_file (backlog_path ^ ".last-good") "{invalid-recovery";
      let response =
        call
          (tool_request ~id:3 ~name:"masc_start"
             (`Assoc
               [ ("path", `String base_path)
               ; ("task_title", `String "must not become partial success")
               ; ("_agent_name", `String "session-task-failure")
               ]))
      in
      check_tool_failure
        "masc_start task creation"
        ~failure_class:"runtime_failure"
        response;
      let structured = structured_content_exn "masc_start task creation" response in
      check string "session bind is a proven post-effect" "proven_post_effect"
        Yojson.Safe.Util.(structured |> member "effect_disposition" |> to_string);
      check string "bound session identity is preserved" "session-task-failure"
        Yojson.Safe.Util.(structured |> member "agent_name" |> to_string))

let () =
  run "MCP session-bound Task lifecycle smoke"
    [ ( "protocol to durable outcome"
      , [ test_case "handshake, start, observe, complete" `Quick
            test_session_task_lifecycle
        ; test_case "task creation failure stays an error" `Quick
            test_task_creation_failure_remains_typed_error
        ] )
    ]
