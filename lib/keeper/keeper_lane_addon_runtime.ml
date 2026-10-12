let reserved_names () =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas
  @ (Keeper_tool_descriptor.all_descriptors ()
     |> List.concat_map Keeper_tool_descriptor.registered_names)
  |> List.sort_uniq String.compare

let snapshot ~config ~keeper_name =
  let snapshot = Lane_addon_runtime.tool_export_snapshot ~config
    ~access:(Lane_addon_sources.Keeper keeper_name) ~reserved:(reserved_names ()) in
  List.iter (fun conflict -> Log.Keeper.warn
    "Keeper Add-on export quarantined keeper=%s: %s" keeper_name
    (Lane_addon_tool_export.conflict_to_string conflict)) snapshot.conflicts;
  snapshot

let content_block (content : Mcp_protocol.Mcp_types.tool_content) =
  match content with
  | TextContent { text; _ } -> Llm_provider.Types.Text text
  | ImageContent { data; mime_type; _ } ->
      Llm_provider.Types.Image { data; media_type = mime_type; source_type = Base64 }
  | AudioContent { data; mime_type; _ } ->
      Llm_provider.Types.Audio { data; media_type = mime_type; source_type = Base64 }
  | ResourceContent _ | ResourceLinkContent _ ->
      Llm_provider.Types.Text
        (Yojson.Safe.to_string (Mcp_protocol.Mcp_types.tool_content_to_yojson content))

let call ~config ~keeper_name ~(export : Lane_addon_tool_export.t) ~arguments =
  let start_time = Tool_timing.start () in
  let tool_name = export.tool.name in
  let result = match Machine_addon_host.call ~principal:(Lane_addon_call_context.Keeper keeper_name) ~config
      ~access:(Lane_addon_sources.Keeper keeper_name) ~reserved:(reserved_names ())
      ~export ~arguments with
    | Error (Lane_addon_runtime.Host_refusal refusal) ->
        let class_, message = match refusal with
          | Lane_addon_call_context.Rejected message | Activity_disabled message -> Tool_result.Workflow_rejection, message
          | Unavailable message | Activity_unobserved message -> Tool_result.Runtime_failure, message in
        Tool_result.make_err ~tool_name ~start_time ~class_
          ~effect_disposition:Tool_result.Proven_pre_effect message
    | Error (Lane_addon_runtime.Unavailable message) ->
        Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
          ~effect_disposition:Tool_result.Proven_pre_effect message
    | Error (Lane_addon_runtime.Outcome_unknown message) ->
        Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure message
    | Ok result ->
        let data = Mcp_protocol.Mcp_types.tool_result_to_yojson result in
        match result.is_error with
        | Some true ->
            let class_, effect_disposition = Lane_addon_tool_result.failure result in
            Tool_result.make_err ~tool_name ~start_time ~class_ ~effect_disposition
              ?metadata:result._meta ~data (Agent_core.Mcp.text_of_tool_result result)
        | None | Some false -> Tool_result.make_ok ~tool_name ~start_time ~data
            ?metadata:result._meta ~content_blocks:(List.map content_block result.content) () in
  Keeper_tool_execution.of_tool_result result
