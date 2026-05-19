module Mcp_eio = Masc_mcp.Mcp_server_eio
module Tool_dispatch = Masc_mcp.Tool_dispatch
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

let create_admin_token base_path =
  match
    Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin"
      ~role:Masc_domain.Admin
  with
  | Ok (token, _cred) -> token
  | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let raw_token = create_admin_token base_path in
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_tool_help"
      ~arguments:(`Assoc [ ("tool_name", `String "masc_status") ])
  in
  Alcotest.(check bool) "tool help call succeeds" true result.Tool_result.success;
  let json = extract_json_from_text (Tool_result.message result) in
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
        (fun ~name ~args:_ ->
          if String.equal name "masc_tool_help" then
            Tool_dispatch.Reject
              {
                Tool_result.success = false;
                data = `String "blocked-by-pre-hook";
                legacy_message = "blocked-by-pre-hook";
                tool_name = name;
                duration_ms = 0.0;
                failure_class = None;
              }
          else Tool_dispatch.Pass);
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let raw_token = create_admin_token base_path in
      let _room_path = Masc_mcp.Coord.masc_dir state.room_config in
      let hook_result =
        Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
          ~name:"masc_tool_help"
          ~arguments:(`Assoc [ ("tool_name", `String "masc_status") ])
      in
      Alcotest.(check bool) "pre-hook blocks tagged dispatch" false
        hook_result.Tool_result.success;
      Alcotest.(check string) "blocked message returned" "blocked-by-pre-hook"
        (Tool_result.message hook_result))

let test_execute_tool_autoresearch_uses_resolved_session_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let workdir_path = Filename.concat base_path "not-a-git-repo" in
  Unix.mkdir workdir_path 0o755;
  Fun.protect
    ~finally:(fun () ->
      Tool_dispatch.clear_hooks ();
      cleanup_dir base_path)
    (fun () ->
      Tool_dispatch.clear_hooks ();
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let sid = "mcp-autoresearch-session-agent" in
      let init_result =
        Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
          ~name:"masc_init" ~arguments:(`Assoc [])
      in
      (* masc_init pruned from registry - dispatch fails. Initialise
         the room state directly so downstream masc_join succeeds. *)
      Alcotest.(check bool) "init returns failure (tool pruned)" false
        init_result.Tool_result.success;
      let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in
      let join_result =
        Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
          ~name:"masc_join"
          ~arguments:(`Assoc [ ("agent_name", `String "codex") ])
      in
      Alcotest.(check bool) "join success" true join_result.Tool_result.success;
      let start_result =
        Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
          ~name:"masc_autoresearch_start"
          ~arguments:
            (`Assoc
              [
                ("goal", `String "permission regression");
                ("metric_fn", `String "echo");
                ("target_file", `String "target.txt");
                ("workdir", `String workdir_path);
                ("model_model", `String "test:dummy");
                ("max_cycles", `Int 1);
              ])
      in
      Alcotest.(check bool) "start fails" false start_result.Tool_result.success;
      (* Without the legacy Tool_permissions pre-hook, the call reaches
         workdir validation which rejects non-git directories. *)
      Alcotest.(check bool) "fails at workdir validation" true
        (contains_substring (Tool_result.message start_result)
           "workdir is not inside a git repository"))

let () =
  Alcotest.run "Mcp_server_eio_tool_dispatch"
    [
      ( "tool_dispatch",
        [
          "execute masc_tool_help", `Quick, test_execute_tool_help_tool;
          ( "execute tag dispatch respects pre-hooks",
            `Quick,
            test_execute_tool_tag_dispatch_respects_pre_hooks );
          ( "execute autoresearch uses resolved session agent",
            `Quick,
            test_execute_tool_autoresearch_uses_resolved_session_agent );
        ] );
    ]
