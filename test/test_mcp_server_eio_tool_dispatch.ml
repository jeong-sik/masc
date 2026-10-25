module Mcp_eio = Masc.Mcp_server_eio
module Mcp_server = Masc.Mcp_server
module Tool_dispatch = Tool_dispatch
module Tool_catalog = Tool_catalog
module Tool_result = Tool_result

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let dir = Filename.temp_file "test_mcp_eio_tool_dispatch_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  try rm dir with _ -> ()

let create_admin_token ?(agent_name = "stable-admin") base_path =
  match
    Auth.create_token base_path ~agent_name ~role:Masc_domain.Admin
  with
  | Ok (token, _cred) -> token
  | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)

let extract_json_from_text text =
  try
    let idx = String.index text '{' in
    Yojson.Safe.from_string (String.sub text idx (String.length text - idx))
  with Not_found ->
    Alcotest.failf "expected JSON payload in text: %s" text

let test_execute_tool_help_tool () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let raw_token = create_admin_token base_path in
  let result =
    Mcp_eio.execute_tool_eio
      ~sw
      ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~auth_token:raw_token
      state
      ~name:"masc_tool_help"
      ~arguments:(`Assoc [ ("tool_name", `String "masc_status") ])
  in
  Alcotest.(check bool) "tool help call succeeds" true (Tool_result.is_success result);
  let json = extract_json_from_text ((Tool_result.message result)) in
  Alcotest.(check string) "help tool echoes name" "masc_status"
    Yojson.Safe.Util.(json |> member "name" |> to_string);
  cleanup_dir base_path

let test_execute_tool_tag_dispatch_respects_pre_hooks () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Tool_dispatch.clear_hooks ();
      cleanup_dir base_path)
    (fun () ->
      Tool_dispatch.clear_hooks ();
      Tool_dispatch.register_pre_hook
        (fun ~schema:_ ~name ~args:_ ->
          if String.equal name "masc_tool_help" then
            Tool_dispatch.Reject
              (Tool_result.Failed
                 { Tool_result.effect_disposition = Tool_result.Effect_outcome_unknown
       ; class_ = Tool_result.Runtime_failure
                 ; message = "blocked-by-pre-hook"
                 ; data_source = Tool_result.Message_as_data
                 ; metadata = None
                 ; tool_name = name
                 ; duration_ms = 0.0
                 })
          else Tool_dispatch.Pass);
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let raw_token = create_admin_token base_path in
      let _workspace_path = Masc.Workspace.masc_dir (Mcp_server.workspace_config state) in
      let hook_result =
        Mcp_eio.execute_tool_eio
          ~sw
          ~clock
          ~workspace_scope:(Mcp_server.workspace_scope state)
          ~auth_token:raw_token
          state
          ~name:"masc_tool_help"
          ~arguments:(`Assoc [ ("tool_name", `String "masc_status") ])
      in
      Alcotest.(check bool) "pre-hook blocks tagged dispatch" false
        (Tool_result.is_success hook_result);
      Alcotest.(check string) "blocked message returned" "blocked-by-pre-hook"
        ((Tool_result.message hook_result)))

let test_tool_call_heartbeats () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let tool_name = "masc_tool_help" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let config = Mcp_server.workspace_config state in
      let agent_name = "heartbeat-test-agent" in
      ignore (Masc.Workspace.init config ~agent_name:(Some agent_name));
      let raw_token = create_admin_token ~agent_name base_path in
      let agent_file =
        Filename.concat
          (Masc.Workspace.agents_dir config)
          (Masc.Workspace.safe_filename agent_name ^ ".json")
      in
      let stale_last_seen = "2000-01-01T00:00:00Z" in
      let set_stale_last_seen () =
        let agent =
          Masc.Workspace.get_agents_raw config
          |> List.find (fun (agent : Masc_domain.agent) ->
            String.equal agent.name agent_name)
        in
        Masc.Workspace.write_json
          config
          agent_file
          (Masc_domain.agent_to_yojson { agent with last_seen = stale_last_seen })
      in
      set_stale_last_seen ();
      ignore
        (Mcp_eio.execute_tool_eio
           ~sw
           ~clock
           ~workspace_scope:(Mcp_server.workspace_scope state)
           ~auth_token:raw_token
           state
           ~name:tool_name
           ~arguments:(`Assoc [ "tool_name", `String "masc_status" ]));
      let last_seen =
        Masc.Workspace.get_agents_raw config
        |> List.find (fun (agent : Masc_domain.agent) ->
          String.equal agent.name agent_name)
        |> fun (agent : Masc_domain.agent) -> agent.last_seen
      in
      Alcotest.(check bool) "tool call heartbeats" true
        (not (String.equal last_seen stale_last_seen)))

(* Direct callers do not pass the protocol-level tools/call gate. A profile
   refusal must still precede every actual dispatch hook, even with valid admin
   credentials and caller-controlled internal-runtime flags. *)
let test_direct_executor_enforces_profile_before_hooks () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let entered = ref 0 in
  Fun.protect ~finally:(fun () -> Tool_dispatch.clear_hooks (); cleanup_dir base_path)
    (fun () ->
      Tool_dispatch.clear_hooks ();
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let raw_token = create_admin_token base_path in
      let name = "masc_tool_help" in
      let call profile internal_keeper_runtime name =
        Masc.Mcp_server_eio_execute.execute_tool_eio ~sw ~clock:env#clock
          ~workspace_scope:(Mcp_server.workspace_scope state)
          ~profile ~auth_token:raw_token ~internal_keeper_runtime state ~name
          ~arguments:(`Assoc ["tool_name", `String "masc_status"]) in
      Tool_dispatch.register_pre_hook (fun ~schema:_ ~name:_ ~args:_ ->
        incr entered; Tool_dispatch.Pass);
      List.iter (fun (profile, name) ->
        Alcotest.(check bool) "fixture tool excluded by actual restricted profile" false
          (Masc.Mcp_server_eio_tool_profile.tool_allowed_in_profile state profile name);
        List.iter (fun internal ->
          let result = call profile internal name in
          (match result with
           | Tool_result.Failed failure ->
             Alcotest.(check bool) "profile refusal is typed policy rejection" true
               (failure.class_ = Tool_result.Policy_rejection);
             Alcotest.(check bool) "no effect was attempted" true
               (failure.effect_disposition = Tool_result.Proven_pre_effect)
           | Tool_result.Completed _ | Tool_result.Deferred _ ->
             Alcotest.fail "direct executor bypassed profile");
          Alcotest.(check int) "refused call never enters actual dispatch hook" 0 !entered)
          [false; true])
        [Masc.Mcp_server_eio_tool_profile.Operator_remote, name;
         Seat, name; Full, "masc_unregistered_profile_fixture"];
      let allowed = call Masc.Mcp_server_eio_tool_profile.Full false name in
      Alcotest.(check bool) "allowed Full call still executes actual tool" true
        (Tool_result.is_success allowed);
      Alcotest.(check int) "only admitted call reaches actual dispatch hook" 1 !entered)

let () =
  Alcotest.run "Mcp_server_eio_tool_dispatch"
    [
      ( "tool_dispatch",
        [
          "execute masc_tool_help", `Quick, test_execute_tool_help_tool;
          ( "direct executor enforces profile before hooks", `Quick,
            test_direct_executor_enforces_profile_before_hooks );
          ( "execute tag dispatch respects pre-hooks",
            `Quick,
            test_execute_tool_tag_dispatch_respects_pre_hooks );
          ( "tool call heartbeats",
            `Quick,
            test_tool_call_heartbeats );
        ] );
    ]
