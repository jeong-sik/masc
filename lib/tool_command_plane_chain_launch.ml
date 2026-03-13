open Tool_command_plane_support
open Tool_command_plane_chain_common

let launch_chain_background (ctx : (_, _) context) (operation : Command_plane_v2.operation_record)
    (launch : chain_launch) =
  match ctx.sw with
  | Some sw ->
      let backend = chain_backend () in
      let backend_name = chain_backend_to_string backend in
      let actor = ctx.agent_name ^ "/chain" in
      let operation_id = operation.operation_id in
      let viewer_path = chain_viewer_path operation_id in
      let initial_mermaid =
        match operation.chain with
        | Some chain -> chain.mermaid
        | None -> initial_mermaid_for_launch ctx backend (Some launch)
      in
      let initial_preview_run =
        match operation.chain with
        | Some chain -> chain.preview_run
        | None -> initial_preview_run_for_launch ctx backend (Some launch)
      in
      let designed_chain_id = ref None in
      let designed_mermaid = ref initial_mermaid in
      let designed_preview_run = ref initial_preview_run in
      let set_running_detail =
        `Assoc
          [
            ( "kind",
              `String
                (match launch with
                | Chain_run _ -> "chain.run"
                | Chain_orchestrate _ -> "chain.orchestrate") );
            ("backend", `String backend_name);
            ( "mermaid",
              match initial_mermaid with
              | Some value -> `String value
              | None -> `Null );
            ("viewer_path", `String viewer_path);
          ]
      in
      ignore
        (Command_plane_v2.update_operation ctx.config ~actor ~operation_id
           ~event_type:"chain_started" ~detail:set_running_detail (fun current ->
             let next_chain : Command_plane_v2.chain_record =
               match current.chain with
               | Some chain ->
                   {
                     chain with
                     backend = backend_name;
                     status = "running";
                     history_event = chain.history_event;
                     mermaid =
                       (match chain.mermaid with
                       | Some _ as existing -> existing
                       | None -> initial_mermaid);
                     preview_run =
                       (match chain.preview_run with
                       | Some _ as existing -> existing
                       | None -> initial_preview_run);
                     viewer_path = Some viewer_path;
                     last_sync_at = Some (Types.now_iso ());
                   }
               | None ->
                   {
                     kind =
                       (match launch with
                       | Chain_run _ -> "chain.run"
                       | Chain_orchestrate _ -> "chain.orchestrate");
                     backend = backend_name;
                     chain_id =
                       (match launch with Chain_run spec -> Some spec.chain_id | Chain_orchestrate _ -> None);
                     goal =
                       (match launch with Chain_orchestrate spec -> Some spec.goal | Chain_run _ -> None);
                     run_id = None;
                     status = "running";
                     history_event = None;
                     mermaid = initial_mermaid;
                     preview_run = initial_preview_run;
                     viewer_path = Some viewer_path;
                     last_sync_at = Some (Types.now_iso ());
                   }
             in
             let checkpoint_ref =
               match current.checkpoint_ref, next_chain.run_id with
               | Some value, _ -> Some value
               | None, Some value -> Some value
               | None, None -> None
             in
             { current with chain = Some next_chain; checkpoint_ref }));
      Eio.Fiber.fork ~sw (fun () ->
          let history_event_of_run_json = function
            | Some run_json ->
                let chain_id =
                  match U.member "chain_id" run_json with
                  | `String value -> Some value
                  | _ -> None
                in
                let duration_ms =
                  match U.member "duration_ms" run_json with
                  | `Int value -> Some value
                  | `Intlit value -> (try Some (int_of_string value) with Failure _ -> None)
                  | _ -> None
                in
                let started_at =
                  match U.member "started_at" run_json with
                  | `Float value -> Some value
                  | `Int value -> Some (float_of_int value)
                  | `Intlit value -> (try Some (float_of_string value) with Failure _ -> None)
                  | _ -> None
                in
                let timestamp =
                  match started_at, duration_ms with
                  | Some started, Some duration ->
                      Command_plane_v2.iso_of_unix
                        (started +. (float_of_int duration /. 1000.0))
                  | Some started, None -> Command_plane_v2.iso_of_unix started
                  | None, _ -> Types.now_iso ()
                in
                let event =
                  match U.member "success" run_json with
                  | `Bool false -> "chain_failed"
                  | _ -> "chain_complete"
                in
                let base =
                  fallback_history_event_json ~event ~chain_id ()
                in
                (match base with
                | `Assoc fields ->
                    `Assoc
                      (List.map
                         (fun (key, value) ->
                           if String.equal key "timestamp" then ("timestamp", `String timestamp)
                           else if String.equal key "duration_ms" then
                             ( "duration_ms",
                               Option.fold ~none:`Null ~some:(fun value -> `Int value) duration_ms )
                           else (key, value))
                         fields)
                | other -> other)
            | None ->
                fallback_history_event_json ~event:"chain_complete" ~chain_id:None ()
          in
          let finish_success ~(chain : Command_plane_v2.chain_record) ~detail ~status =
            ignore
              (Command_plane_v2.update_operation ctx.config ~actor ~operation_id
                 ~event_type:status ~detail (fun current ->
                   let next_chain : Command_plane_v2.chain_record =
                     {
                       chain with
                       backend = backend_name;
                       status = if String.equal status "chain_completed" then "completed" else "failed";
                       history_event = chain.history_event;
                       mermaid = chain.mermaid;
                       preview_run = chain.preview_run;
                       viewer_path = Some viewer_path;
                       last_sync_at = Some (Types.now_iso ());
                     }
                   in
                   let next_status =
                     if String.equal status "chain_completed" then
                       Command_plane_v2.Completed
                     else Command_plane_v2.Failed
                   in
                   let checkpoint_ref =
                     match current.checkpoint_ref, next_chain.run_id with
                     | Some value, _ -> Some value
                     | None, Some value -> Some value
                     | None, None -> None
                   in
                   { current with chain = Some next_chain; checkpoint_ref; status = next_status }))
          in
          let fail_chain message =
            let detail = `Assoc [ ("message", `String message) ] in
            let chain_id =
              match operation.chain with
              | Some chain -> (
                  match chain.chain_id with
                  | Some _ as value -> value
                  | None -> !designed_chain_id)
              | None -> (
                  match !designed_chain_id with
                  | Some _ as value -> value
                  | None -> (
                      match launch with
                      | Chain_run spec -> Some spec.chain_id
                      | Chain_orchestrate _ -> None))
            in
            let mermaid =
              match !designed_mermaid with
              | Some _ as value -> value
              | None -> (
                  match operation.chain with
                  | Some chain -> chain.mermaid
                  | None -> None)
            in
            let preview_run =
              match !designed_preview_run with
              | Some _ as value -> value
              | None -> (
                  match operation.chain with
                  | Some chain -> chain.preview_run
                  | None -> None)
            in
            match operation.chain with
            | Some chain ->
                finish_success
                  ~chain:
                    {
                      chain with
                      chain_id;
                      history_event =
                        Some
                          (fallback_history_event_json ~event:"chain_failed" ~chain_id
                             ?message:(Some message) ());
                      mermaid;
                      preview_run;
                    }
                  ~detail ~status:"chain_failed"
            | None ->
                let chain : Command_plane_v2.chain_record =
                  {
                    kind =
                      (match launch with
                      | Chain_run _ -> "chain.run"
                      | Chain_orchestrate _ -> "chain.orchestrate");
                    backend = backend_name;
                    chain_id;
                    goal =
                      (match launch with Chain_orchestrate spec -> Some spec.goal | Chain_run _ -> None);
                    run_id = None;
                    status = "failed";
                    history_event =
                      Some
                        (fallback_history_event_json ~event:"chain_failed" ~chain_id
                           ?message:(Some message) ());
                    mermaid;
                    preview_run;
                    viewer_path = Some viewer_path;
                    last_sync_at = Some (Types.now_iso ());
                  }
                in
                finish_success ~chain ~detail ~status:"chain_failed"
          in
          let finish_run_response ~kind ~chain_id ~goal ~run_id ~detail =
            let run_json_opt =
              match backend, run_id with
              | Native, Some value -> Chain_native_eio.run_json ~run_id:value
              | _ -> None
            in
            let resolved_chain_id =
              match chain_id with
              | Some _ -> chain_id
              | None -> !designed_chain_id
            in
            let resolved_mermaid =
              match mermaid_from_run_json run_json_opt with
              | Some _ as value -> value
              | None -> !designed_mermaid
            in
            let resolved_preview_run =
              match run_json_opt with
              | Some run_json -> Some run_json
              | None -> !designed_preview_run
            in
            let chain : Command_plane_v2.chain_record =
              {
                kind;
                backend = backend_name;
                chain_id = resolved_chain_id;
                goal;
                run_id;
                status = "completed";
                history_event =
                  Some
                    (match run_json_opt with
                    | Some _ -> history_event_of_run_json run_json_opt
                    | None ->
                        fallback_history_event_json ~event:"chain_complete"
                          ~chain_id:resolved_chain_id
                          ());
                mermaid = resolved_mermaid;
                preview_run = resolved_preview_run;
                viewer_path = Some viewer_path;
                last_sync_at = Some (Types.now_iso ());
              }
            in
            finish_success ~chain ~detail ~status:"chain_completed"
          in
          match backend, launch with
          | Native, Chain_run spec -> (
              match native_runtime ctx ~agent_name:ctx.agent_name with
              | None -> fail_chain "native chain runtime unavailable"
              | Some runtime -> (
                  match
                    Chain_native_eio.run_chain runtime ~chain_id:spec.chain_id
                      ?input_json:spec.input_json
                      ~checkpoint_enabled:spec.checkpoint_enabled ()
                  with
                  | Ok response ->
                      let detail =
                        `Assoc
                          [
                            ("backend", `String backend_name);
                            ("chain_id", `String spec.chain_id);
                            ( "run_id",
                              match response.run_id with
                              | Some value -> `String value
                              | None -> `Null );
                            ( "duration_ms",
                              match response.duration_ms with
                              | Some value -> `Int value
                              | None -> `Null );
                            ( "trace_count",
                              match response.trace_count with
                              | Some value -> `Int value
                              | None -> `Null );
                            ( "output_preview",
                              `String (preview_text ~max_chars:240 response.output) );
                          ]
                      in
                      finish_run_response ~kind:"chain.run"
                        ~chain_id:
                          (match response.chain_id with
                          | Some value -> Some value
                          | None -> Some spec.chain_id)
                        ~goal:None ~run_id:response.run_id ~detail
                  | Error message -> fail_chain message))
          | Native, Chain_orchestrate spec -> (
              match native_runtime ctx ~agent_name:ctx.agent_name with
              | None -> fail_chain "native chain runtime unavailable"
              | Some runtime -> (
                  let on_chain_designed (chain : Chain_types.chain) =
                    let mermaid = Chain_mermaid_parser.chain_to_mermaid chain in
                    let preview_run = preview_run_json_of_chain chain in
                    designed_chain_id := Some chain.id;
                    designed_mermaid := Some mermaid;
                    designed_preview_run := Some preview_run;
                    let detail =
                      `Assoc
                        [
                          ("backend", `String backend_name);
                          ("goal", `String spec.goal);
                          ("chain_id", `String chain.id);
                          ("mermaid", `String mermaid);
                          ("viewer_path", `String viewer_path);
                        ]
                    in
                    ignore
                      (Command_plane_v2.update_operation ctx.config ~actor ~operation_id
                         ~event_type:"chain_designed" ~detail (fun current ->
                           let next_chain =
                             match current.chain with
                             | Some current_chain ->
                                 {
                                   current_chain with
                                   kind = "chain.orchestrate";
                                   backend = backend_name;
                                   chain_id = Some chain.id;
                                   goal = Some spec.goal;
                                   status = "running";
                                   mermaid = Some mermaid;
                                   preview_run = Some preview_run;
                                   viewer_path = Some viewer_path;
                                   last_sync_at = Some (Types.now_iso ());
                                 }
                             | None ->
                                 {
                                   kind = "chain.orchestrate";
                                   backend = backend_name;
                                   chain_id = Some chain.id;
                                   goal = Some spec.goal;
                                   run_id = None;
                                   status = "running";
                                   history_event = None;
                                   mermaid = Some mermaid;
                                   preview_run = Some preview_run;
                                   viewer_path = Some viewer_path;
                                   last_sync_at = Some (Types.now_iso ());
                                 }
                           in
                           { current with chain = Some next_chain }))
                  in
                  match
                    Chain_native_eio.orchestrate_goal runtime ~on_chain_designed
                      ~goal:spec.goal
                  with
                  | Ok response ->
                      let detail =
                        `Assoc
                          [
                            ("backend", `String backend_name);
                            ("goal", `String spec.goal);
                            ( "chain_id",
                              match response.chain_id with
                              | Some value -> `String value
                              | None -> `Null );
                            ( "run_id",
                              match response.run_id with
                              | Some value -> `String value
                              | None -> `Null );
                            ( "success",
                              match response.success with
                              | Some value -> `Bool value
                              | None -> `Null );
                            ( "total_replans",
                              match response.total_replans with
                              | Some value -> `Int value
                              | None -> `Null );
                            ( "summary_preview",
                              `String (preview_text ~max_chars:240 response.summary) );
                          ]
                  in
                      finish_run_response ~kind:"chain.orchestrate"
                        ~chain_id:response.chain_id ~goal:(Some spec.goal)
                        ~run_id:response.run_id ~detail
                  | Error message -> fail_chain message)))
  | _ -> ()

let handle_operation_start (ctx : (_, _) context) args : result =
  try
    match parse_chain_launch args with
    | Error message -> (false, json_error message)
    | Ok launch ->
        let backend = chain_backend () in
        let backend_name = chain_backend_to_string backend in
        let runtime_error =
          match launch, backend with
          | Some _, Native
            when ctx.sw = None || ctx.clock = None || ctx.mcp_state = None ->
              Some "native chain-backed operations require local server runtime context"
          | _ -> None
        in
    match runtime_error with
    | Some message -> (false, json_error message)
    | None ->
        let initial_mermaid =
          initial_mermaid_for_launch ctx backend launch
        in
        let initial_preview_run =
          initial_preview_run_for_launch ctx backend launch
        in
        let operation_args =
          merge_args_with_chain args
            (build_operation_chain_json backend_name ?initial_mermaid
               ?initial_preview_run launch)
        in
        match
          Command_plane_v2.start_operation ctx.config ~actor:ctx.agent_name
                operation_args
            with
            | Ok operation ->
                (match launch with
                | Some current_launch ->
                    launch_chain_background ctx operation current_launch
                | None -> ());
                ( true,
                  json_ok
                    [
                      ("result", Command_plane_v2.operation_to_json operation);
                      ("operations", Command_plane_v2.operation_status_json ctx.config ());
                    ] )
            | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)
