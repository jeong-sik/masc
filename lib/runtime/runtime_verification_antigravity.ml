type error = Private_home_unavailable | Client_error of Runtime_antigravity.error

let run ~secure_random ~net ~mgr ~clock ~cwd ~directory ~oauth_source ~config ~tool ~prompt =
  Eio.Switch.run (fun sw ->
    let runtime_root = Filename.concat directory ("antigravity-readiness-" ^ Random_id.hex ~bytes:16) in
    let created =
      try Unix.mkdir runtime_root 0o700; true
      with Unix.Unix_error _ -> false in
    if not created then Error Private_home_unavailable else (
      (* Registered first: subprocess/listener releases run before HOME cleanup. *)
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree runtime_root);
      match Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf:"readiness" ~oauth_source with
      | Error _ -> Error Private_home_unavailable
      | Ok home ->
        let bridge = Runtime_official_client_mcp_http.start ~sw ~net ~secure_random
          ~server_name:"masc"
          ~tool_specs:(fun () -> [`Assoc [
            "name", `String tool.Runtime_official_client_tool.name;
            "description", `String tool.description; "inputSchema", tool.input_schema]])
          ~call_tool:(fun ~name ~call_id ~arguments ->
            if not (String.equal name tool.name) then None else
            let result = tool.call ~call_id arguments in
            Some { Runtime_official_client_mcp_http.outcome =
              { Runtime_official_client_mcp.success = result.success; content = result.content; content_blocks = result.content_blocks };
              after_response_sent = (fun () -> ()) }) () in
        match Runtime_antigravity_home.publish_mcp_config home
          (Runtime_official_client_mcp_http.mcp_config_json bridge) with
        | Error _ -> Error Private_home_unavailable
        | Ok () ->
          Runtime_antigravity.run_turn ~home_dir:(Runtime_antigravity_home.home_dir home)
            ~mgr ~clock ~cwd config ~prompt
          |> Result.map_error (fun error -> Client_error error)))
