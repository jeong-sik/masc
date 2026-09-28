type error =
  | Home_error of Runtime_muse_home.error
  | Private_workspace_unavailable
  | Client_error of Runtime_muse_serve.error

let run ~secure_random ~net ~mgr ~clock ~cwd ~directory ~account_home ~quota_scope ~config
    ~max_prompt_bytes ~reasoning_effort ~tool ~prompt =
  let ( let* ) = Result.bind in
  let invalid_prompt detail = Error (Client_error (Runtime_muse_serve.Invalid_config detail)) in
  let* () = match max_prompt_bytes with
    | None -> Ok ()
    | Some capacity when capacity <= 0 ->
      invalid_prompt "Muse Code max-prompt-bytes must be positive"
    | Some capacity when String.length prompt > capacity ->
      invalid_prompt (Printf.sprintf
        "Muse Code probe input is %d bytes, exceeding declared max-prompt-bytes %d"
        (String.length prompt) capacity)
    | Some _ -> Ok () in
  match Runtime_muse_home.prepare ~account_home with
  | Error error -> Error (Home_error error)
  | Ok home ->
    Eio.Switch.run (fun sw ->
      let root = Filename.concat directory ("muse-readiness-" ^ Random_id.hex ~bytes:16) in
      let prepared = Eio.Cancel.protect (fun () ->
        let created = Eio_guard.run_in_systhread ~label:"muse readiness workspace" (fun () ->
          try Unix.mkdir root 0o700; true
          with Unix.Unix_error _ -> false) in
        if not created then Error Private_workspace_unavailable else (
          (* Register cleanup before cancellation can discard the mkdir result.
             The turn's own switch reaps its child before returning; listener
             releases run before this whole temporary tree is removed. *)
          Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
          Eio_guard.run_in_systhread ~label:"muse readiness native storage" (fun () ->
            try
              let workspace = Filename.concat root "workspace" in
              let storage_root = Filename.concat root "native" in
              Unix.mkdir workspace 0o700;
              Unix.mkdir storage_root 0o700;
              List.iter (fun part -> Unix.mkdir (Filename.concat storage_root part) 0o700)
                ["data"; "cache"; "state"; "run"; "tmp"];
              Ok (workspace, storage_root)
            with Unix.Unix_error _ -> Error Private_workspace_unavailable))) in
      let* workspace, storage_root = prepared in
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
      Runtime_muse_serve.run_turn
        ~on_stream_event:(function
          | Runtime_muse_serve.Subscription_usage_observed usage ->
            Option.iter (fun reset_ms -> Runtime_quota_window.note_exhausted
              ~scope:quota_scope ~resets_at:(float_of_int reset_ms /. 1000.))
              (Runtime_muse_msp.exhausted_subscription_reset_ms usage)
          | Runtime_muse_serve.Turn_started _ | Runtime_muse_serve.Text_delta _
          | Runtime_muse_serve.Text_completed _ | Runtime_muse_serve.Native_tool_started _
          | Runtime_muse_serve.Native_tool_finished _ | Runtime_muse_serve.Approval_decided _
          | Runtime_muse_serve.Turn_terminal_received _ | Runtime_muse_serve.Usage_reported _
          | Runtime_muse_serve.Turn_finished _ -> ())
        ~storage_root ?reasoning_effort ~mcp_servers ~mgr ~clock
        ~cwd:Eio.Path.(cwd / Filename.basename root / "workspace") config
        ~workspace_root:workspace ~prompt ~images:[]
      |> Result.map_error (fun error -> Client_error error))
