open Types
open Tool_args

module U = Yojson.Safe.Util

type ('clock, 'net) context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t option;
  clock : 'clock Eio.Time.clock option;
  net : 'net option;
  mcp_state : Mcp_server.server_state option;
  mcp_session_id : string option;
  auth_token : string option;
}

type result = bool * string

let get_json_opt args key =
  match U.member key args with
  | `Null -> None
  | value -> Some value

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let json_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message -> (false, json_error message)

let handle_unit_define (ctx : (_, _) context) args : result =
  try
    match Command_plane_v2.upsert_unit ctx.config ~actor:ctx.agent_name args with
    | Ok unit ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.unit_to_json unit);
              ("topology", Command_plane_v2.topology_json ctx.config);
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_unit_list (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_units_json ctx.config))

type chain_launch =
  | Chain_run of {
      chain_id : string;
      input_json : Yojson.Safe.t option;
      checkpoint_enabled : bool;
    }
  | Chain_orchestrate of {
      goal : string;
    }

let chain_viewer_path operation_id =
  Printf.sprintf "/dashboard#chains/operation/%s" operation_id

type chain_backend =
  | Native
  | Compat_llm_mcp

let chain_backend () =
  match Sys.getenv_opt "MASC_CHAIN_BACKEND" with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "compat_llm_mcp" | "compat" | "llm-mcp" -> Compat_llm_mcp
      | _ -> Native)
  | None -> Native

let chain_backend_to_string = function
  | Native -> "native"
  | Compat_llm_mcp -> "compat_llm_mcp"

let is_valid_run_id_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let validate_run_id run_id =
  let trimmed = String.trim run_id in
  if trimmed = "" then
    Error "invalid chain run_id: empty"
  else if String.length trimmed > 128 then
    Error "invalid chain run_id: too long"
  else if String.for_all is_valid_run_id_char trimmed then
    Ok trimmed
  else
    Error "invalid chain run_id: only [A-Za-z0-9_-] are allowed"

let compat_chain_error_message = function
  | Llm_client_eio.ConnectionError message -> "llm-mcp connection error: " ^ message
  | Llm_client_eio.ParseError message -> "llm-mcp parse error: " ^ message
  | Llm_client_eio.ServerError (status, message) ->
      Printf.sprintf "llm-mcp server error (%d): %s" status message
  | Llm_client_eio.Timeout -> "llm-mcp timeout"

let native_runtime (ctx : (_, _) context) ~agent_name =
  match ctx.sw, ctx.clock, ctx.mcp_state with
  | Some sw, Some clock, Some mcp_state ->
      Some
        {
          Chain_native_eio.config = ctx.config;
          agent_name;
          sw;
          clock;
          mcp_state;
          mcp_session_id = ctx.mcp_session_id;
          auth_token = ctx.auth_token;
        }
  | _ -> None

let preview_text ~max_chars text =
  if String.length text <= max_chars then text
  else String.sub text 0 max_chars ^ "..."

let fallback_history_event_json ~event ~chain_id ?timestamp ?duration_ms ?message () =
  `Assoc
    [
      ("event", `String event);
      ("chain_id", Option.fold ~none:`Null ~some:(fun value -> `String value) chain_id);
      ( "timestamp",
        Option.fold ~none:(`String (Types.now_iso ())) ~some:(fun value -> `String value)
          timestamp );
      ("duration_ms", Option.fold ~none:`Null ~some:(fun value -> `Int value) duration_ms);
      ("message", Option.fold ~none:`Null ~some:(fun value -> `String value) message);
      ("tokens", `Null);
    ]

let mermaid_from_run_json = function
  | Some run_json -> (
      match U.member "mermaid" run_json with
      | `String value -> Some value
      | _ -> None)
  | None -> None

let parse_chain_launch args =
  let orchestration_kind =
    match get_string_opt args "orchestration_kind" with
    | Some value -> String.lowercase_ascii value
    | None -> "native"
  in
  match orchestration_kind with
  | "native" -> Ok None
  | "chain_dsl" ->
      let chain_id = get_string_opt args "chain_id" in
      let chain_goal = get_string_opt args "chain_goal" in
      (match chain_id, chain_goal with
      | Some _, Some _ -> Error "chain_goal and chain_id are mutually exclusive"
      | None, None -> Error "chain_dsl requires chain_id or chain_goal"
      | Some value, None ->
          Ok
            (Some
               (Chain_run
                  {
                    chain_id = value;
                    input_json = get_json_opt args "chain_input";
                    checkpoint_enabled =
                      get_bool args "chain_checkpoint_enabled" true;
                  }))
      | None, Some goal -> Ok (Some (Chain_orchestrate { goal })))
  | other ->
      Error
        (Printf.sprintf
           "unsupported orchestration_kind: %s (expected native or chain_dsl)"
           other)

let initial_mermaid_for_launch (ctx : (_, _) context) backend = function
  | Some (Chain_run spec) when backend = Native ->
      Chain_native_eio.registered_chain_mermaid ~config:ctx.config
        ~chain_id:spec.chain_id
  | _ -> None

let preview_run_json_of_chain (chain : Chain_types.chain) =
  let nodes =
    Chain_run_store.collect_all_nodes chain
    |> List.map (fun (node : Chain_types.node) ->
           `Assoc
             [
               ("id", `String node.id);
               ("type", `String (Chain_types.node_type_name node.node_type));
               ("status", `String "designed");
               ("duration_ms", `Null);
               ("error", `Null);
             ])
  in
  `Assoc
    [
      ("run_id", `Null);
      ("chain_id", `String chain.id);
      ("duration_ms", `Null);
      ("success", `Null);
      ("mermaid", `String (Chain_mermaid_parser.chain_to_mermaid chain));
      ("nodes", `List nodes);
    ]

let preview_run_json_of_source ~config ?chain_id ?mermaid () =
  match Chain_native_eio.chain_of_source ~config ?chain_id ?mermaid () with
  | Ok chain -> Some (preview_run_json_of_chain chain)
  | Error _ -> None

let initial_preview_run_for_launch (ctx : (_, _) context) backend = function
  | Some (Chain_run spec) when backend = Native ->
      preview_run_json_of_source ~config:ctx.config ~chain_id:spec.chain_id ()
  | _ -> None

let build_operation_chain_json backend ?initial_mermaid ?initial_preview_run = function
  | None -> None
  | Some (Chain_run spec) ->
      Some
        (`Assoc
          [
            ("kind", `String "chain.run");
            ("backend", `String backend);
            ("chain_id", `String spec.chain_id);
            ("goal", `Null);
            ("run_id", `Null);
            ("status", `String "running");
            ("history_event", `Null);
            ( "mermaid",
              match initial_mermaid with
              | Some value -> `String value
              | None -> `Null );
            ("preview_run", Option.value ~default:`Null initial_preview_run);
            ("viewer_path", `Null);
            ("last_sync_at", `String (Types.now_iso ()));
          ])
  | Some (Chain_orchestrate spec) ->
      Some
        (`Assoc
          [
            ("kind", `String "chain.orchestrate");
            ("backend", `String backend);
            ("chain_id", `Null);
            ("goal", `String spec.goal);
            ("run_id", `Null);
            ("status", `String "running");
            ("history_event", `Null);
            ("mermaid", `Null);
            ("preview_run", Option.value ~default:`Null initial_preview_run);
            ("viewer_path", `Null);
            ("last_sync_at", `String (Types.now_iso ()));
          ])

let merge_args_with_chain args chain_json =
  match args with
  | `Assoc fields ->
      `Assoc
        (fields
         @
         match chain_json with
         | Some value -> [ ("chain", value) ]
         | None -> [])
  | _ ->
      `Assoc
        (match chain_json with Some value -> [ ("chain", value) ] | None -> [])

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
                  | Error message -> fail_chain message))
          | Compat_llm_mcp, Chain_run spec -> (
              match ctx.clock, ctx.net with
              | Some clock, Some net -> (
                  match
                    Llm_client_eio.call_chain_run ~net ~clock
                      ~chain_id:spec.chain_id ?input_json:spec.input_json
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
                  | Error err -> fail_chain (compat_chain_error_message err))
              | _ -> fail_chain "compat llm-mcp runtime unavailable")
          | Compat_llm_mcp, Chain_orchestrate spec -> (
              match ctx.clock, ctx.net with
              | Some clock, Some net -> (
                  match
                    Llm_client_eio.call_chain_orchestrate ~net ~clock ~goal:spec.goal ()
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
                  | Error err -> fail_chain (compat_chain_error_message err))
              | _ -> fail_chain "compat llm-mcp runtime unavailable"))
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
          | Some _, Compat_llm_mcp
            when ctx.sw = None || ctx.clock = None || ctx.net = None ->
              Some "compat chain-backed operations require llm-mcp runtime context"
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

let history_timestamp_iso json =
  match U.member "timestamp" json with
  | `String value -> Some value
  | `Float value -> Some (Command_plane_v2.iso_of_unix value)
  | `Int value -> Some (Command_plane_v2.iso_of_unix (float_of_int value))
  | `Intlit value -> (try Some (Command_plane_v2.iso_of_unix (float_of_string value)) with Failure _ -> None)
  | _ -> None

let history_tokens json =
  match U.member "tokens" json with
  | `Int value -> Some value
  | `Intlit value -> (try Some (int_of_string value) with Failure _ -> None)
  | `Assoc fields -> (
      match List.assoc_opt "total_tokens" fields with
      | Some (`Int value) -> Some value
      | Some (`Intlit value) -> (try Some (int_of_string value) with Failure _ -> None)
      | _ ->
          let prompt =
            match List.assoc_opt "prompt_tokens" fields with
            | Some (`Int value) -> value
            | Some (`Intlit value) -> (try int_of_string value with Failure _ -> 0)
            | _ -> 0
          in
          let completion =
            match List.assoc_opt "completion_tokens" fields with
            | Some (`Int value) -> value
            | Some (`Intlit value) -> (try int_of_string value with Failure _ -> 0)
            | _ -> 0
          in
          if prompt + completion > 0 then Some (prompt + completion) else None)
  | _ -> None

let history_event_json json =
  `Assoc
    [
      ( "event",
        match U.member "event" json with
        | `String value -> `String value
        | _ -> `String "unknown" );
      ( "chain_id",
        match U.member "chain_id" json with
        | `String value -> `String value
        | _ -> `Null );
      ( "timestamp",
        match history_timestamp_iso json with Some value -> `String value | None -> `Null );
      ( "duration_ms",
        match U.member "duration_ms" json with
        | `Int value -> `Int value
        | `Intlit value -> (try `Int (int_of_string value) with Failure _ -> `Null)
        | _ -> `Null );
      ("message", match U.member "message" json with `String value -> `String value | _ -> `Null);
      ("tokens", match history_tokens json with Some value -> `Int value | None -> `Null);
    ]

let run_store_history_json run_json =
  let chain_id =
    match U.member "chain_id" run_json with
    | `String value -> `String value
    | _ -> `Null
  in
  let duration_ms =
    match U.member "duration_ms" run_json with
    | `Int value -> `Int value
    | `Intlit value -> (try `Int (int_of_string value) with Failure _ -> `Null)
    | _ -> `Null
  in
  let started_at =
    match U.member "started_at" run_json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | `Intlit value -> (try Some (float_of_string value) with Failure _ -> None)
    | _ -> None
  in
  let completed_at =
    match started_at, duration_ms with
    | Some started, `Int duration ->
        Some (Command_plane_v2.iso_of_unix (started +. (float_of_int duration /. 1000.0)))
    | Some started, _ -> Some (Command_plane_v2.iso_of_unix started)
    | None, _ -> None
  in
  let event_name =
    match U.member "success" run_json with
    | `Bool true -> "chain_complete"
    | `Bool false -> "chain_failed"
    | _ -> "chain_complete"
  in
  `Assoc
    [
      ("event", `String event_name);
      ("chain_id", chain_id);
      ( "timestamp",
        match completed_at with Some value -> `String value | None -> `Null );
      ("duration_ms", duration_ms);
      ("message", `Null);
      ("tokens", `Null);
    ]

let legacy_history_event_for_operation
    (operation : Command_plane_v2.operation_record)
    (chain : Command_plane_v2.chain_record) =
  let event =
    if String.equal chain.status "failed" || operation.status = Command_plane_v2.Failed then
      "chain_failed"
    else "chain_complete"
  in
  fallback_history_event_json ~event ~chain_id:chain.chain_id
    ?timestamp:(Some operation.updated_at) ()

let backfill_chain_overlays config =
  let actor = "system/chain-backfill" in
  Command_plane_v2.read_operations config
  |> List.iter (fun (operation : Command_plane_v2.operation_record) ->
         match operation.chain with
         | None -> ()
         | Some chain ->
             let run_json_opt =
               match chain.run_id with
               | Some run_id -> Chain_native_eio.run_json ~run_id
               | None -> None
             in
             let next_history_event =
               match chain.history_event with
               | Some _ as existing -> existing
               | None -> (
                   match run_json_opt with
                   | Some run_json -> Some (run_store_history_json run_json)
                   | None
                     when String.equal chain.status "completed"
                          || String.equal chain.status "failed" ->
                       Some (legacy_history_event_for_operation operation chain)
                   | None -> None)
             in
             let next_mermaid =
               match chain.mermaid with
               | Some _ as existing -> existing
               | None -> (
                   match mermaid_from_run_json run_json_opt with
                   | Some _ as value -> value
                   | None -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Chain_native_eio.registered_chain_mermaid ~config ~chain_id
                       | None -> None))
             in
             let next_preview_run =
               match chain.preview_run with
               | Some _ as existing -> existing
               | None -> (
                   match run_json_opt with
                   | Some run_json -> Some run_json
                   | None -> (
                       match chain.chain_id, next_mermaid with
                       | Some chain_id, _ ->
                           preview_run_json_of_source ~config ~chain_id ()
                       | None, Some mermaid ->
                           preview_run_json_of_source ~config ~mermaid ()
                       | None, None -> None))
             in
             let next_checkpoint_ref =
               match operation.checkpoint_ref, chain.run_id with
               | Some _ as current, _ -> current
               | None, Some run_id -> Some run_id
               | None, None -> None
             in
             if next_history_event <> chain.history_event
                || next_mermaid <> chain.mermaid
                || next_preview_run <> chain.preview_run
                || next_checkpoint_ref <> operation.checkpoint_ref
             then
               ignore
                 (Command_plane_v2.update_operation config ~actor
                    ~operation_id:operation.operation_id
                    ~event_type:"chain_backfilled"
                    ~detail:
                      (`Assoc
                        [
                          ("history_event", `Bool (next_history_event <> chain.history_event));
                          ("mermaid", `Bool (next_mermaid <> chain.mermaid));
                          ("preview_run", `Bool (next_preview_run <> chain.preview_run));
                          ("checkpoint_ref", `Bool (next_checkpoint_ref <> operation.checkpoint_ref));
                        ])
                    (fun current ->
                      let updated_chain =
                        match current.chain with
                        | Some current_chain ->
                            {
                              current_chain with
                              history_event = next_history_event;
                              mermaid = next_mermaid;
                              preview_run = next_preview_run;
                            }
                        | None ->
                            {
                              chain with
                              history_event = next_history_event;
                              mermaid = next_mermaid;
                              preview_run = next_preview_run;
                            }
                      in
                      { current with chain = Some updated_chain; checkpoint_ref = next_checkpoint_ref })))

let chain_summary_json (ctx : (_, _) context) =
  let backend = chain_backend () in
  let backend_name = chain_backend_to_string backend in
  let build_summary ~connection ~status_rows ~recent_history =
    let running_index : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun row ->
        match U.member "chain_id" row with
        | `String chain_id -> Hashtbl.replace running_index chain_id row
        | _ -> ())
      status_rows;
    let mermaid_index : (string, string) Hashtbl.t = Hashtbl.create 16 in
    let latest_history : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 16 in
    List.iter
      (fun row ->
        match U.member "chain_id" row with
        | `String chain_id ->
            if not (Hashtbl.mem latest_history chain_id) then
              Hashtbl.replace latest_history chain_id row;
            (match U.member "event" row, U.member "mermaid_dsl" row with
            | `String "chain_start", `String mermaid
              when not (Hashtbl.mem mermaid_index chain_id) ->
                Hashtbl.replace mermaid_index chain_id mermaid
            | _ -> ())
        | _ -> ())
      recent_history;
    let linked_operations =
      Command_plane_v2.read_operations ctx.config
      |> List.filter (fun (operation : Command_plane_v2.operation_record) ->
             Option.is_some operation.chain)
    in
    let overlays =
      linked_operations
      |> List.map (fun (operation : Command_plane_v2.operation_record) ->
             let persisted_history_json =
               match operation.chain with
               | Some chain -> Option.value ~default:`Null chain.history_event
               | None -> `Null
             in
             let persisted_mermaid_json =
               match operation.chain with
               | Some chain ->
                   Option.fold ~none:`Null ~some:(fun value -> `String value) chain.mermaid
               | None -> `Null
             in
             let persisted_preview_json =
               match operation.chain with
               | Some chain -> Option.value ~default:`Null chain.preview_run
               | None -> `Null
             in
             let run_json_opt =
               match operation.chain with
               | Some chain -> (
                   match chain.run_id with
                   | Some run_id -> Chain_native_eio.run_json ~run_id
                   | None -> None)
               | None -> None
             in
             let runtime_json =
               match operation.chain with
               | Some chain
                 when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                   match chain.chain_id with
                   | Some chain_id ->
                       Hashtbl.find_opt running_index chain_id
                       |> Option.value ~default:`Null
                   | None -> `Null)
               | _ -> `Null
             in
             let history_json =
               match run_json_opt with
               | Some run_json -> run_store_history_json run_json
               | None when persisted_history_json <> `Null -> persisted_history_json
               | None -> (
                   match operation.chain with
                   | Some chain
                     when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Hashtbl.find_opt latest_history chain_id
                           |> Option.map history_event_json |> Option.value ~default:`Null
                       | None -> `Null)
                   | _ -> `Null)
             in
             let mermaid_from_run =
               match run_json_opt with
               | Some run_json -> (
                   match U.member "mermaid" run_json with
                   | `String value -> Some value
                   | _ -> None)
               | None -> None
             in
             let mermaid_json =
               match mermaid_from_run with
               | Some value -> `String value
               | None when persisted_mermaid_json <> `Null -> persisted_mermaid_json
               | None -> (
                   match operation.chain with
                   | Some chain
                     when String.equal chain.status "running" || String.equal chain.status "pending" -> (
                       match chain.chain_id with
                       | Some chain_id ->
                           Hashtbl.find_opt mermaid_index chain_id
                           |> Option.map (fun value -> `String value)
                           |> Option.value ~default:`Null
                       | None -> `Null)
                   | _ -> `Null)
             in
             let preview_json =
               match run_json_opt with
               | Some run_json -> run_json
               | None when persisted_preview_json <> `Null -> persisted_preview_json
               | None -> `Null
             in
             `Assoc
               [
                 ("operation", Command_plane_v2.operation_to_json operation);
                 ("runtime", runtime_json);
                 ("history", history_json);
                 ("mermaid", mermaid_json);
                 ("preview_run", preview_json);
               ])
    in
    let recent_failures =
      recent_history
      |> List.filter (fun row ->
             match U.member "event" row with
             | `String "chain_error" -> true
             | _ -> false)
      |> List.length
    in
    let last_history_event_at =
      match recent_history with
      | head :: _ -> history_timestamp_iso head
      | [] -> None
    in
    Ok
      (`Assoc
        [
          ("schema_version", `Int 1);
          ("version", `String "chain-plane-v1");
          ("backend", `String backend_name);
          ("generated_at", `String (Types.now_iso ()));
          ("connection", connection);
          ( "summary",
            `Assoc
              [
                ("linked_operations", `Int (List.length linked_operations));
                ("active_chains", `Int (List.length status_rows));
                ( "running_operations",
                  `Int
                    (List.length
                       (List.filter
                          (fun (operation : Command_plane_v2.operation_record) ->
                            match operation.chain with
                            | Some chain -> String.equal chain.status "running"
                            | None -> false)
                          linked_operations)) );
                ("recent_failures", `Int recent_failures);
                ( "last_history_event_at",
                  match last_history_event_at with
                  | Some value -> `String value
                  | None -> `Null );
              ] );
          ("operations", `List overlays);
          ("recent_history", `List (List.map history_event_json recent_history));
        ])
  in
  match backend with
  | Native ->
      let connection =
        `Assoc
          [
            ("status", `String "connected");
            ("base_url", `String "native://masc");
            ("message", `String "Chain summary is served from the native MASC chain plane.");
            ("backend", `String backend_name);
          ]
      in
      build_summary ~connection ~status_rows:(Chain_native_eio.running_chains_json ())
        ~recent_history:(Chain_native_eio.read_history_events ~limit:100)
  | Compat_llm_mcp -> (
      match ctx.clock, ctx.net with
      | None, _ | _, None ->
          Error "compat chain summary requires server Eio runtime context"
      | Some clock, Some net ->
          let endpoint = Llm_client_eio.resolve_endpoint () in
          let base_url =
            Printf.sprintf "http://%s:%d%s" endpoint.host endpoint.port
              endpoint.base_path
          in
          let status_result = Llm_client_eio.fetch_chain_status_json ~net ~clock () in
          let history_result = Llm_client_eio.fetch_chain_history_json ~net ~clock () in
          let connection =
            match status_result, history_result with
            | Ok _, Ok _ ->
                `Assoc
                  [
                    ("status", `String "connected");
                    ("base_url", `String base_url);
                    ("message", `Null);
                    ("backend", `String backend_name);
                  ]
            | Error err, Ok _ | Ok _, Error err ->
                `Assoc
                  [
                    ("status", `String "degraded");
                    ("base_url", `String base_url);
                    ("message", `String (compat_chain_error_message err));
                    ("backend", `String backend_name);
                  ]
            | Error err, Error _ ->
                `Assoc
                  [
                    ("status", `String "disconnected");
                    ("base_url", `String base_url);
                    ("message", `String (compat_chain_error_message err));
                    ("backend", `String backend_name);
                  ]
          in
          let status_rows =
            match status_result with
            | Ok (`List rows) -> rows
            | _ -> []
          in
          let recent_history =
            match history_result with
            | Ok (`List rows) -> rows
            | _ -> []
          in
          build_summary ~connection ~status_rows ~recent_history)

let chain_run_get_json (ctx : (_, _) context) ~run_id =
  match validate_run_id run_id with
  | Error _ as err -> err
  | Ok run_id -> (
      match chain_backend () with
      | Native -> (
          match Chain_native_eio.run_json ~run_id with
          | Some json ->
              Ok
                (`Assoc
                  [
                    ("schema_version", `Int 1);
                    ("version", `String "chain-run-v1");
                    ("backend", `String "native");
                    ("run", json);
                  ])
          | None -> Error (Printf.sprintf "chain run not found: %s" run_id))
      | Compat_llm_mcp -> (
          match ctx.clock, ctx.net with
          | None, _ | _, None ->
              Error "compat chain run lookup requires server Eio runtime context"
          | Some clock, Some net -> (
              match Llm_client_eio.fetch_chain_run_json ~net ~clock ~run_id () with
              | Ok json -> Ok json
              | Error err -> Error (compat_chain_error_message err))))

let handle_chain_snapshot (ctx : (_, _) context) : result =
  json_result (chain_summary_json ctx)

let handle_chain_run_get (ctx : (_, _) context) args : result =
  match get_string_opt args "run_id" with
  | Some run_id -> json_result (chain_run_get_json ctx ~run_id)
  | None -> (false, json_error "run_id is required")

let handle_operation_status (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.operation_status_json ctx.config ?operation_id ()) )

let handle_operation_checkpoint (ctx : (_, _) context) args : result =
  try
    match Command_plane_v2.checkpoint_operation ctx.config ~actor:ctx.agent_name args with
    | Ok operation ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.operation_to_json operation);
              ("traces", Command_plane_v2.list_traces_json ctx.config ~operation_id:operation.operation_id ());
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_observe_topology (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.topology_json ctx.config))

let handle_observe_alerts (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_alerts_json ctx.config))

let handle_observe_operations (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_operations_json ctx.config))

let handle_observe_capacity (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_capacity_json ctx.config))

let handle_observe_traces (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 25
  in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_traces_json ctx.config ?operation_id ~limit ()))

let handle_unit_update (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.unit_update_json ctx.config ~actor:ctx.agent_name args)

let handle_unit_reparent (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.unit_reparent_json ctx.config ~actor:ctx.agent_name args)

let handle_unit_reassign (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.unit_reassign_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_pause (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.pause_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_resume (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.resume_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_stop (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.stop_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_finalize (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.finalize_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_plan (ctx : (_, _) context) args : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.dispatch_plan_json ctx.config args))

let handle_dispatch_route (ctx : (_, _) context) args : result =
  handle_dispatch_plan ctx args

let handle_dispatch_assign (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.dispatch_assign_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_rebalance (ctx : (_, _) context) args : result =
  json_result
    (Command_plane_v2.dispatch_rebalance_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_escalate (ctx : (_, _) context) args : result =
  json_result
    (Command_plane_v2.dispatch_escalate_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_recall (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.dispatch_recall_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_tick (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.dispatch_tick_json ctx.config ~actor:ctx.agent_name args)

let handle_detachment_list (ctx : (_, _) context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  let detachment_id = get_string_opt args "detachment_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_detachments_json ctx.config ?operation_id
         ?detachment_id) )

let handle_detachment_status (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.detachment_status_json ctx.config args)

let handle_policy_status (ctx : (_, _) context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.policy_status_json ctx.config))

let handle_policy_approve (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.policy_approve_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_deny (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.policy_deny_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_update (ctx : (_, _) context) args : result =
  json_result (Command_plane_v2.policy_update_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_freeze_unit (ctx : (_, _) context) args : result =
  json_result
    (Command_plane_v2.policy_freeze_unit_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_kill_switch (ctx : (_, _) context) args : result =
  json_result
    (Command_plane_v2.policy_kill_switch_json ctx.config ~actor:ctx.agent_name args)

let dispatch (ctx : (_, _) context) ~name ~args : result option =
  match name with
  | "masc_unit_define" -> Some (handle_unit_define ctx args)
  | "masc_unit_update" -> Some (handle_unit_update ctx args)
  | "masc_unit_list" -> Some (handle_unit_list ctx)
  | "masc_unit_reparent" -> Some (handle_unit_reparent ctx args)
  | "masc_unit_reassign" -> Some (handle_unit_reassign ctx args)
  | "masc_operation_start" -> Some (handle_operation_start ctx args)
  | "masc_operation_status" -> Some (handle_operation_status ctx args)
  | "masc_operation_checkpoint" -> Some (handle_operation_checkpoint ctx args)
  | "masc_operation_pause" -> Some (handle_operation_pause ctx args)
  | "masc_operation_resume" -> Some (handle_operation_resume ctx args)
  | "masc_operation_stop" -> Some (handle_operation_stop ctx args)
  | "masc_operation_finalize" -> Some (handle_operation_finalize ctx args)
  | "masc_chain_snapshot" -> Some (handle_chain_snapshot ctx)
  | "masc_chain_run_get" -> Some (handle_chain_run_get ctx args)
  | "masc_dispatch_plan" -> Some (handle_dispatch_plan ctx args)
  | "masc_dispatch_route" -> Some (handle_dispatch_route ctx args)
  | "masc_dispatch_assign" -> Some (handle_dispatch_assign ctx args)
  | "masc_dispatch_rebalance" -> Some (handle_dispatch_rebalance ctx args)
  | "masc_dispatch_escalate" -> Some (handle_dispatch_escalate ctx args)
  | "masc_dispatch_recall" -> Some (handle_dispatch_recall ctx args)
  | "masc_dispatch_tick" -> Some (handle_dispatch_tick ctx args)
  | "masc_detachment_list" -> Some (handle_detachment_list ctx args)
  | "masc_detachment_status" -> Some (handle_detachment_status ctx args)
  | "masc_policy_status" -> Some (handle_policy_status ctx)
  | "masc_policy_approve" -> Some (handle_policy_approve ctx args)
  | "masc_policy_deny" -> Some (handle_policy_deny ctx args)
  | "masc_policy_update" -> Some (handle_policy_update ctx args)
  | "masc_policy_freeze_unit" -> Some (handle_policy_freeze_unit ctx args)
  | "masc_policy_kill_switch" -> Some (handle_policy_kill_switch ctx args)
  | "masc_observe_topology" -> Some (handle_observe_topology ctx)
  | "masc_observe_alerts" -> Some (handle_observe_alerts ctx)
  | "masc_observe_operations" -> Some (handle_observe_operations ctx)
  | "masc_observe_capacity" -> Some (handle_observe_capacity ctx)
  | "masc_observe_traces" -> Some (handle_observe_traces ctx args)
  | _ -> None

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun key -> `String key) required));
    ]

let string_prop description =
  `Assoc [ ("type", `String "string"); ("description", `String description) ]

let integer_prop ?default description =
  `Assoc
    ([
       ("type", `String "integer");
       ("description", `String description);
     ]
    @
    match default with
    | Some value -> [ ("default", `Int value) ]
    | None -> [])

let boolean_prop ?default description =
  `Assoc
    ([
       ("type", `String "boolean");
       ("description", `String description);
     ]
    @
    match default with
    | Some value -> [ ("default", `Bool value) ]
    | None -> [])

let string_array_prop description =
  `Assoc
    [
      ("type", `String "array");
      ("description", `String description);
      ("items", `Assoc [ ("type", `String "string") ]);
    ]

let schemas : tool_schema list =
  [
    {
      name = "masc_unit_define";
      description =
        "CPv2 benchmark step 1. Create or update a managed company/platoon/squad/agent unit before starting operations.";
      input_schema =
        object_schema ~required:[ "kind"; "label" ]
          [
            ("unit_id", string_prop "Stable unit identifier. Omit to derive from kind + label.");
            ("label", string_prop "Human-readable unit label.");
            ("kind", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "company"; `String "platoon"; `String "squad"; `String "agent" ]) ]);
            ("parent_unit_id", string_prop "Parent unit id. Required for non-company units.");
            ("leader_id", string_prop "Leader agent id for this unit.");
            ("roster", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("capability_profile", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("policy", `Assoc [ ("type", `String "object") ]);
            ("budget", `Assoc [ ("type", `String "object") ]);
          ];
    };
    {
      name = "masc_unit_list";
      description =
        "Read managed and effective Command Plane V2 units, including auto-generated topology for unassigned agents.";
      input_schema = object_schema [];
    };
    {
      name = "masc_unit_update";
      description =
        "Alias for masc_unit_define. Create or update a managed unit with explicit policy and budget envelope.";
      input_schema =
        object_schema ~required:[ "unit_id"; "kind"; "label" ]
          [
            ("unit_id", string_prop "Stable unit identifier.");
            ("label", string_prop "Human-readable unit label.");
            ("kind", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "company"; `String "platoon"; `String "squad"; `String "agent" ]) ]);
            ("parent_unit_id", string_prop "Parent unit id.");
            ("leader_id", string_prop "Leader agent id.");
            ("roster", string_array_prop "Explicit roster for this unit.");
            ("capability_profile", string_array_prop "Capability labels.");
            ("policy", `Assoc [ ("type", `String "object") ]);
            ("budget", `Assoc [ ("type", `String "object") ]);
          ];
    };
    {
      name = "masc_unit_reparent";
      description =
        "Move a unit under a new parent unit while preserving its policy and budget envelopes.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("parent_unit_id", string_prop "New parent unit id. Omit only for company roots.");
          ];
    };
    {
      name = "masc_unit_reassign";
      description =
        "Update a unit's leader or explicit roster. Use this to rotate squad leaders or replace a detachment roster.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("leader_id", string_prop "New leader agent id.");
            ("roster", string_array_prop "Replacement roster.");
          ];
    };
    {
      name = "masc_operation_start";
      description =
        "CPv2 benchmark step 2. Start a managed operation on a ready unit after leadership, live-roster, and capacity checks pass. Set orchestration_kind=chain_dsl to attach llm-mcp Chain DSL execution.";
      input_schema =
        object_schema ~required:[ "assigned_unit_id"; "objective" ]
          [
            ("assigned_unit_id", string_prop "Target unit id.");
            ("objective", string_prop "Operation objective.");
            ("autonomy_level", string_prop "Autonomy level such as L3_Guided or L4_Autonomous.");
            ("policy_class", string_prop "Policy class name.");
            ("budget_class", string_prop "Budget class name.");
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "generic"; `String "research_pipeline" ]); ("description", `String "Workload profile used by CPv2 search fabric. Default: generic.") ]);
            ("stage", string_prop "Optional stage label such as normalize, verify, curate, rank, or audit.");
            ("depends_on_operation_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]); ("description", `String "Optional upstream operation ids that must complete or checkpoint before this operation can issue.") ]);
            ("search_strategy", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "legacy"; `String "best_first_v1" ]); ("description", `String "Optional CPv2 routing strategy. legacy preserves current behavior; best_first_v1 enables dependency-aware search routing.") ]);
            ("detachment_session_id", string_prop "Optional backing team-session id.");
            ("checkpoint_ref", string_prop "Optional initial checkpoint reference.");
            ("active_goal_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("note", string_prop "Optional operator note.");
            ("status", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "planned"; `String "active"; `String "paused" ]) ]);
            ("orchestration_kind", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "native"; `String "chain_dsl" ]); ("description", `String "native (default) or chain_dsl") ]);
            ("chain_id", string_prop "Preset llm-mcp chain id. Mutually exclusive with chain_goal.");
            ("chain_goal", string_prop "Goal string for llm-mcp chain.orchestrate. Mutually exclusive with chain_id.");
            ("chain_input", `Assoc [ ("type", `String "object"); ("description", `String "Optional JSON input forwarded to chain.run input.") ]);
            ("chain_checkpoint_enabled", boolean_prop ~default:true "Enable llm-mcp checkpoint capture for chain.run.");
          ];
    };
    {
      name = "masc_operation_status";
      description =
        "Read Command Plane V2 operations. Use this after operation_start or later during CPv2 benchmark triage.";
      input_schema =
        object_schema
          [ ("operation_id", string_prop "Operation id to filter."); ];
    };
    {
      name = "masc_operation_checkpoint";
      description =
        "Attach or update a checkpoint reference for a managed Command Plane V2 operation and append a trace event.";
      input_schema =
        object_schema ~required:[ "operation_id"; "checkpoint_ref" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("checkpoint_ref", string_prop "Checkpoint reference or durable resume pointer.");
            ("note", string_prop "Optional checkpoint note.");
          ];
    };
    {
      name = "masc_operation_pause";
      description = "Pause a managed operation and sync its managed detachment status.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional pause note.");
          ];
    };
    {
      name = "masc_operation_resume";
      description = "Resume a paused managed operation.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional resume note.");
          ];
    };
    {
      name = "masc_operation_stop";
      description = "Cancel a managed operation and mark its detachment stopped.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional stop reason.");
          ];
    };
    {
      name = "masc_operation_finalize";
      description = "Finalize a managed operation as completed.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional completion note.");
          ];
    };
    {
      name = "masc_chain_snapshot";
      description =
        "Summarize llm-mcp chain runtime and history, linked back to CPv2 managed operations.";
      input_schema = object_schema [];
    };
    {
      name = "masc_chain_run_get";
      description =
        "Fetch llm-mcp run-store details for a completed chain run by run_id.";
      input_schema =
        object_schema ~required:[ "run_id" ]
          [
            ("run_id", string_prop "llm-mcp run id from a chain-backed operation.");
          ];
    };
    {
      name = "masc_dispatch_plan";
      description =
        "Recommend the best target units for an operation. best_first_v1 plans include score breakdown, routing reason, and dependency blockers.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation id to route.");
            ("assigned_unit_id", string_prop "Optional current unit id when planning a new operation.");
          ];
    };
    {
      name = "masc_dispatch_route";
      description =
        "Alias for masc_dispatch_plan. Return recommended route candidates for large-scale hierarchy dispatch.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation id to route.");
            ("assigned_unit_id", string_prop "Optional current unit id.");
          ];
    };
    {
      name = "masc_dispatch_assign";
      description =
        "Assign or move an operation to a new unit. Cross-platoon or strict-policy moves become pending approvals.";
      input_schema =
        object_schema ~required:[ "operation_id"; "target_unit_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("target_unit_id", string_prop "Target unit id.");
            ("note", string_prop "Optional assignment note.");
          ];
    };
    {
      name = "masc_dispatch_rebalance";
      description =
        "Rebalance an operation to another unit using the same approval semantics as dispatch_assign.";
      input_schema =
        object_schema ~required:[ "operation_id"; "target_unit_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("target_unit_id", string_prop "Target unit id.");
            ("note", string_prop "Optional rebalance note.");
          ];
    };
    {
      name = "masc_dispatch_escalate";
      description =
        "Escalate an operation toward a parent unit or explicit target unit. Cross-platoon moves require approval.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("target_unit_id", string_prop "Optional explicit target unit id.");
            ("note", string_prop "Optional escalation note.");
          ];
    };
    {
      name = "masc_dispatch_recall";
      description =
        "Recall an operation by pausing it without deleting its checkpoint or trace lineage.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional recall note.");
          ];
    };
    {
      name = "masc_dispatch_tick";
      description =
        "CPv2 benchmark step 3. Run one deterministic reconcile tick to materialize or repair detachments, failover, approvals, alerts, and traces.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation filter.");
            ("detachment_id", string_prop "Optional detachment filter.");
          ];
    };
    {
      name = "masc_detachment_list";
      description =
        "CPv2 benchmark observe step. List managed and projected detachments after dispatch/tick to confirm runtime materialization.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation or trace filter.");
            ("detachment_id", string_prop "Optional detachment id filter.");
          ];
    };
    {
      name = "masc_detachment_status";
      description =
        "CPv2 benchmark observe step. Inspect one detachment with runtime, heartbeat, failover, and approval context.";
      input_schema =
        object_schema ~required:[ "detachment_id" ]
          [
            ("detachment_id", string_prop "Managed detachment id.");
          ];
    };
    {
      name = "masc_policy_status";
      description =
        "CPv2 benchmark approval step. Read policy decisions, approval queue, capacity overlays, and topology state before strict actions.";
      input_schema = object_schema [];
    };
    {
      name = "masc_policy_approve";
      description =
        "Approve a pending managed policy decision and apply its queued action.";
      input_schema =
        object_schema ~required:[ "decision_id" ]
          [
            ("decision_id", string_prop "Managed decision id.");
            ("reason", string_prop "Optional approval note.");
          ];
    };
    {
      name = "masc_policy_deny";
      description =
        "Deny a pending managed policy decision.";
      input_schema =
        object_schema ~required:[ "decision_id" ]
          [
            ("decision_id", string_prop "Managed decision id.");
            ("reason", string_prop "Optional denial note.");
          ];
    };
    {
      name = "masc_policy_update";
      description =
        "Replace a unit's explicit policy and budget envelope.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("policy", `Assoc [ ("type", `String "object") ]);
            ("budget", `Assoc [ ("type", `String "object") ]);
          ];
    };
    {
      name = "masc_policy_freeze_unit";
      description =
        "Toggle a unit's frozen state. Frozen units reject new dispatch assignments.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("enabled", boolean_prop ~default:true "Set true to freeze, false to unfreeze.");
          ];
    };
    {
      name = "masc_policy_kill_switch";
      description =
        "Toggle a unit kill-switch. Kill-switched units reject all new assignments.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("enabled", boolean_prop ~default:true "Set true to enable, false to clear.");
          ];
    };
    {
      name = "masc_observe_topology";
      description =
        "CPv2 benchmark observe step. Read company/platoon/squad/agent topology with live roster health and active operation counts.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_operations";
      description =
        "Read operations and detachments together for operator triage.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_alerts";
      description =
        "CPv2 benchmark observe step. Read derived alerts such as leader loss, over-capacity units, quiet detachments, and orphaned operations.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_capacity";
      description =
        "CPv2 benchmark observe step. Read per-unit capacity envelopes, live roster counts, and operation utilization.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_traces";
      description =
        "CPv2 benchmark observe step. Read recent trace events for a single operation or the whole command plane.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Operation id.");
            ("limit", integer_prop ~default:25 "Maximum events to return.");
          ];
    };
  ]
