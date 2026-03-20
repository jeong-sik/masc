open Tool_command_plane_support

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

let chain_backend () = Native

let chain_backend_to_string = function
  | Native -> "native"

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
  | "native" ->
      let has_chain_id = get_string_opt args "chain_id" <> None in
      let has_chain_goal = get_string_opt args "chain_goal" <> None in
      if has_chain_id || has_chain_goal then
        Error "chain_id/chain_goal require orchestration_kind=chain_dsl (got native)"
      else
        Ok None
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

