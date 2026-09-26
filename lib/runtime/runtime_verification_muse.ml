type error =
  | Home_error of Runtime_muse_home.error
  | Private_workspace_unavailable
  | Client_error of Runtime_muse_serve.error

let run ~secure_random ~net ~mgr ~clock ~cwd ~directory ~account_home ~config ~tool ~prompt =
  match Runtime_muse_home.prepare ~account_home with
  | Error error -> Error (Home_error error)
  | Ok home ->
    Eio.Switch.run (fun sw ->
      let workspace = Filename.concat directory ("muse-readiness-" ^ Random_id.hex ~bytes:16) in
      let created = Eio.Cancel.protect (fun () ->
        let created = Eio_guard.run_in_systhread ~label:"muse readiness workspace" (fun () ->
          try Unix.mkdir workspace 0o700; true
          with Unix.Unix_error _ -> false) in
        if created then
          (* Register cleanup before cancellation can discard the mkdir result.
             The turn's own switch reaps its child before returning; listener
             releases run before this workspace cleanup. *)
          Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree workspace);
        created) in
      if not created then Error Private_workspace_unavailable else (
        let bridge = Runtime_official_client_mcp_http.start ~sw ~net ~secure_random
          ~server_name:"masc"
          ~tool_specs:(fun () -> [`Assoc [
            "name", `String tool.Runtime_official_client_tool.name;
            "description", `String tool.description; "inputSchema", tool.input_schema]])
          ~call_tool:(fun ~name ~call_id ~arguments ->
            if not (String.equal name tool.name) then None else
            let result = tool.call ~call_id arguments in
            Some { Runtime_official_client_mcp_http.outcome =
              { Runtime_official_client_mcp.success = result.success;
                content = result.content; content_blocks = result.content_blocks };
              after_response_sent = (fun () -> ()) }) () in
        let { Runtime_official_client_mcp_http.url; headers } =
          Runtime_official_client_mcp_http.endpoint bridge in
        let mcp_servers = [{ Runtime_muse_serve.name = "masc";
          server = Runtime_muse_msp.Streamable_http { url; headers; required = true };
          tool_names = [tool.name] }] in
        let config = { config with Runtime_muse_serve.account_home = Some account_home;
          prepared_home = Some home; native = Runtime_native_tools.Native_read } in
        Runtime_muse_serve.run_turn ~mcp_servers ~mgr ~clock
          ~cwd:Eio.Path.(cwd / Filename.basename workspace) config
          ~workspace_root:workspace ~prompt ~images:[]
        |> Result.map_error (fun error -> Client_error error)))
