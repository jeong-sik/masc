(** One-shot synthetic MCP full-cycle probe.

    This is deliberately not a Keeper. It exercises protocol admission,
    session identity, typed tool dispatch, workspace persistence, and task
    completion once inside an isolated workspace. It never starts a provider
    call, heartbeat, autonomous loop, or autoboot entry. *)

open Alcotest

module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server

let () = Mirage_crypto_rng_unix.use_default ()

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
            [ ("name", `String "masc-full-cycle-probe")
            ; ("version", `String "1")
            ] )
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

let test_one_shot_protocol_to_durable_outcome () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = Filename.temp_dir "masc_full_cycle_probe_" "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let session_id = "full-cycle-probe-session" in
      let call request =
        Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:session_id state request
      in

      call initialize_request |> check_protocol_success "initialize";

      call
        (tool_request ~id:2 ~name:"masc_start"
           (`Assoc
             [ ("path", `String base_path)
             ; ("task_title", `String "Synthetic full-cycle proof")
             ; ("_agent_name", `String "full-cycle-probe")
             ]))
      |> check_tool_success "masc_start";

      let config = Mcp_server.workspace_config state in
      let claimed_task = task_exn config in
      (match claimed_task.Masc_domain.task_status with
       | Masc_domain.Claimed { assignee; _ } ->
         check string "task owner" "full-cycle-probe" assignee
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
          "🧭 You: agent=full-cycle-probe | bound=yes | owned=%s | current=%s"
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
             [ ("agent_name", `String "full-cycle-probe")
             ; ("task_id", `String claimed_task.id)
             ; ("action", `String "done")
             ; ("notes", `String "Synthetic full-cycle proof completed")
             ]))
      |> check_tool_success "masc_transition done";

      let completed_task = task_exn config in
      (match completed_task.Masc_domain.task_status with
       | Masc_domain.Done { assignee; notes; _ } ->
         check string "completion owner" "full-cycle-probe" assignee;
         check (option string) "durable completion note"
           (Some "Synthetic full-cycle proof completed") notes
       | status ->
         failf "task did not reach done: %s"
           (Masc_domain.task_status_to_string status));
      check (option string) "current task cleared" None
        (Masc.Task.Planning_eio.get_current_task config))

let () =
  run "MCP one-shot full-cycle probe"
    [ ( "protocol to durable outcome"
      , [ test_case "initialize, start, observe, complete" `Quick
            test_one_shot_protocol_to_durable_outcome
        ] )
    ]
